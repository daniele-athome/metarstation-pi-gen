#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["bumble"]
# ///
"""
Emulator of an Ecowitt WS90 (Shelly BLU, SBWS-90CM) broadcasting BTHome v2
advertisements, built on Bumble virtual controllers.

A Bumble LocalLink acts as a simulated radio. Two virtual controllers share it:
  - "target": exposed over an HCI transport to the host stack under test
      * tcp-client:127.0.0.1:9000  -> QEMU raspi0 PL011 chardev (guest runs btattach -P h4)
      * vhci                       -> the local Linux BlueZ (new hciX appears on the host)
  - "ws90":   driven in-process, advertises BTHome payloads

Usage:
  ws90_emulator.py --transport vhci
  ws90_emulator.py --transport tcp-client:127.0.0.1:9000
  ws90_emulator.py --selftest            # no transport: in-process scanner + bthome-ble decode
"""

from __future__ import annotations

import argparse
import asyncio
import itertools
import math
import random
import struct
import time

from bumble.controller import Controller
from bumble.core import AdvertisingData
from bumble.device import AdvertisingType, Device
from bumble.hci import Address
from bumble.link import LocalLink

BTHOME_UUID16 = 0xFCD2
# Real device period between packets (see Shelly docs); override with --period
DEFAULT_PERIOD_S = 8.8


# ---------------------------------------------------------------------------
# BTHome v2 encoding
# ---------------------------------------------------------------------------

def _u8(v: float) -> bytes:
    return struct.pack("<B", int(round(v)))


def _u16(v: float) -> bytes:
    return struct.pack("<H", int(round(v)))


def _s16(v: float) -> bytes:
    return struct.pack("<h", int(round(v)))


def _u24(v: float) -> bytes:
    return struct.pack("<I", int(round(v)))[:3]


def bthome_service_data(objects: list[tuple[int, bytes]], trigger: bool = False,
                        packet_id: int | None = None) -> bytes:
    """Build BTHome v2 service data (without the UUID). Objects must be in ascending id order."""
    # Device info byte: bits 5-7 = version 2, bit 2 = trigger based, bit 0 = encryption (off)
    info = 0x40 | (0x04 if trigger else 0x00)
    out = bytearray([info])
    if packet_id is not None:
        out += bytes([0x00, packet_id & 0xFF])
    for obj_id, payload in objects:
        out += bytes([obj_id]) + payload
    return bytes(out)


def packet_type_1(s: dict) -> list[tuple[int, bytes]]:
    return [
        (0x05, _u24(s["illuminance_lx"] / 0.01)),
        (0x20, _u8(1 if s["raining"] else 0)),
        (0x44, _u16(s["wind_speed_ms"] / 0.01)),
        (0x44, _u16(s["gust_speed_ms"] / 0.01)),
        (0x46, _u8(s["uv_index"] / 0.1)),
        (0x5E, _u16(s["wind_dir_deg"] / 0.01)),
    ]


def packet_type_2(s: dict) -> list[tuple[int, bytes]]:
    return [
        (0x01, _u8(s["battery_pct"])),
        (0x04, _u24(s["pressure_hpa"] / 0.01)),
        (0x08, _s16(s["dew_point_c"] / 0.01)),
        (0x0C, _u16(s["cap_voltage_v"] / 0.001)),
        (0x2E, _u8(s["humidity_pct"])),
        (0x45, _s16(s["temperature_c"] / 0.1)),
        (0x5F, _u16(s["precipitation_mm"] / 0.1)),
    ]


def packet_type_3() -> list[tuple[int, bytes]]:
    return [(0x3A, _u8(0x01))]  # single press


def advertising_data(service_data: bytes) -> bytes:
    # Legacy (31-byte) non-connectable advertising: the Pi Zero W radio is BT 4.1,
    # so no extended/coded-PHY advertising here.
    ad = bytes(AdvertisingData([
        (AdvertisingData.FLAGS, bytes([0x06])),
        (AdvertisingData.SERVICE_DATA_16_BIT_UUID,
         struct.pack("<H", BTHOME_UUID16) + service_data),
    ]))
    assert len(ad) <= 31, f"advertising data too long: {len(ad)} bytes"
    return ad


# ---------------------------------------------------------------------------
# Synthetic weather model (smooth, plausible values)
# ---------------------------------------------------------------------------

class Weather:
    def __init__(self, seed: int | None = None) -> None:
        self.rng = random.Random(seed)
        self.t0 = time.monotonic()
        self.rain_mm = 0.0

    def sample(self) -> dict:
        t = time.monotonic() - self.t0
        wind = max(0.0, 4 + 3 * math.sin(t / 120) + self.rng.gauss(0, 0.8))
        raining = math.sin(t / 900) > 0.7
        if raining:
            self.rain_mm += 0.1
        temp = 18 + 6 * math.sin(t / 3600)
        hum = 60 + 20 * math.sin(t / 1800 + 1)
        return {
            "illuminance_lx": max(0.0, 40000 + 30000 * math.sin(t / 600)),
            "raining": raining,
            "wind_speed_ms": wind,
            "gust_speed_ms": wind + abs(self.rng.gauss(1.5, 0.7)),
            "uv_index": max(0.0, 3 + 2 * math.sin(t / 600)),
            "wind_dir_deg": (230 + 25 * math.sin(t / 300) + self.rng.gauss(0, 5)) % 360,
            "battery_pct": 98,
            "pressure_hpa": 1013.2 + 2 * math.sin(t / 7200),
            "dew_point_c": temp - (100 - hum) / 5,
            "cap_voltage_v": 3.21,
            "humidity_pct": hum,
            "temperature_c": temp,
            "precipitation_mm": self.rain_mm,
        }


# ---------------------------------------------------------------------------
# Advertiser loop
# ---------------------------------------------------------------------------

async def advertise_forever(ws90: Device, period: float, burst: float,
                            with_packet_id: bool, button_every: int) -> None:
    weather = Weather()
    counter = itertools.count()
    for n in counter:
        state = weather.sample()
        if button_every and n and n % button_every == 0:
            objects, trigger, label = packet_type_3(), True, "type3/button"
        elif n % 2 == 0:
            objects, trigger, label = packet_type_1(state), False, "type1"
        else:
            objects, trigger, label = packet_type_2(state), False, "type2"

        sd = bthome_service_data(objects, trigger, n if with_packet_id else None)
        await ws90.start_advertising(
            advertising_type=AdvertisingType.UNDIRECTED,
            own_address_type=0,  # public address, like a real sensor MAC
            advertising_data=advertising_data(sd),
            advertising_interval_min=100,
            advertising_interval_max=100,
        )
        print(f"[ws90] #{n} {label} sd={sd.hex()}", flush=True)
        await asyncio.sleep(burst)
        await ws90.stop_advertising()
        await asyncio.sleep(max(0.0, period - burst))


async def run(transport_spec: str | None, address: str, period: float, burst: float,
              with_packet_id: bool, button_every: int, selftest: bool) -> None:
    link = LocalLink()

    ws90_ctrl = Controller("ws90", link=link, public_address=address)
    ws90 = Device.with_hci("SBWS-90CM", Address(address), ws90_ctrl, ws90_ctrl)
    await ws90.power_on()

    if selftest:
        await run_selftest(link, ws90, address, with_packet_id)
        return

    from bumble.transport import open_transport

    async with await open_transport(transport_spec) as hci_transport:
        # Virtual controller seen by the stack under test (guest or host BlueZ)
        Controller("target", host_source=hci_transport.source,
                   host_sink=hci_transport.sink, link=link,
                   public_address="B8:27:EB:00:00:01")
        print(f"[target] virtual controller attached to {transport_spec}", flush=True)
        await advertise_forever(ws90, period, burst, with_packet_id, button_every)


async def run_selftest(link: LocalLink, ws90: Device, address: str,
                       with_packet_id: bool) -> None:
    """Scan from a second virtual controller and decode with bthome-ble."""
    from bthome_ble import BTHomeBluetoothDeviceData
    from habluetooth import BluetoothServiceInfoBleak

    scanner_ctrl = Controller("scanner", link=link, public_address="B8:27:EB:00:00:02")
    scanner = Device.with_hci("scanner", Address("B8:27:EB:00:00:02"),
                              scanner_ctrl, scanner_ctrl)
    await scanner.power_on()
    parser = BTHomeBluetoothDeviceData()
    received = asyncio.Event()
    seen: set[str] = set()

    def on_adv(adv) -> None:
        if str(adv.address).split("/")[0] != address:
            return
        sd = {
            f"0000{uuid.to_hex_str().lower()}-0000-1000-8000-00805f9b34fb": data
            for uuid, data in adv.data.get_all(AdvertisingData.SERVICE_DATA_16_BIT_UUID)
        }
        info = BluetoothServiceInfoBleak(
            name="SBWS-90CM", address=address, rssi=adv.rssi, manufacturer_data={},
            service_data=sd, service_uuids=[], source="selftest", device=None,
            advertisement=None, connectable=False, time=time.monotonic(), tx_power=None)
        update = parser.update(info)
        key = next(iter(sd.values()))[1:].hex()
        if key in seen:
            return
        seen.add(key)
        for k, v in update.entity_values.items():
            print(f"  decoded {k.key:28s} = {v.native_value}")
        for k, v in update.binary_entity_values.items():
            print(f"  binary  {k.key:28s} = {v.native_value}")
        for k, v in update.events.items():
            print(f"  event   {k.key:28s} = {v.event_type}")
        if len(seen) >= 3:
            received.set()

    scanner.on("advertisement", on_adv)
    await scanner.start_scanning(active=False, legacy=True)
    task = asyncio.create_task(
        advertise_forever(ws90, period=0.5, burst=0.3,
                          with_packet_id=with_packet_id, button_every=2))
    await asyncio.wait_for(received.wait(), timeout=10)
    task.cancel()
    print("selftest OK")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--transport", help="Bumble transport spec, e.g. vhci or tcp-client:HOST:PORT")
    p.add_argument("--address", default="7C:C6:B6:00:90:01", help="emulated WS90 MAC")
    p.add_argument("--period", type=float, default=DEFAULT_PERIOD_S)
    p.add_argument("--burst", type=float, default=1.0,
                   help="seconds each packet is advertised before switching")
    p.add_argument("--no-packet-id", action="store_true",
                   help="omit BTHome packet id object (0x00); align with a real capture")
    p.add_argument("--button-every", type=int, default=0,
                   help="emit a button event every N packets (0 = never)")
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if not a.selftest and not a.transport:
        p.error("--transport is required unless --selftest")
    asyncio.run(run(a.transport, a.address, a.period, a.burst,
                    not a.no_packet_id, a.button_every, a.selftest))


if __name__ == "__main__":
    main()
