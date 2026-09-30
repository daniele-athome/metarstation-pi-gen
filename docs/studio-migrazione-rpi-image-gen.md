# Studio di fattibilità: migrazione da pi-gen a rpi-image-gen

Data: 2026-09-30

Versioni analizzate:

* **metarstation-pi-gen**: `ec19c1a`, basato su pi-gen upstream `85b4d56`
* **rpi-image-gen**: `v2.8.0-58-g6fec7d5`, 2026-09-29

## 1. Sintesi

| Domanda                                                        | Risposta breve                                                                                                                                                                                                                                                                                                                                                                                                         |
|----------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| rpi-image-gen è davvero il successore di pi-gen?               | **No, non in senso stretto.** Il README di rpi-image-gen rimanda esplicitamente a pi-gen per il "tool used to create the Raspberry Pi OS distribution". pi-gen è ancora mantenuto (ultimi commit upstream a settembre 2026) ed è lo strumento con cui si produce Raspberry Pi OS 32 bit, che supporta ufficialmente il Pi Zero. rpi-image-gen è uno strumento parallelo, orientato a immagini custom/embedded e a Pi 4/5. |
| rpi-image-gen supporta armhf?                                  | **Sì, ma solo a livello di "mattoni".** Esistono i layer `raspbian-trixie-armhf` / `raspbian-bookworm-armhf` e i kernel `rpi-linux-v7` / `rpi-linux-v7l`. Nessuna config, esempio o test del progetto usa armhf: l'unica config 32 bit è stata rimossa nel luglio 2025 ("The big migration"). Il layer Raspbian è dichiarato "supported by its community".                                                     |
| Supporta il Raspberry Pi Zero (1 / W, BCM2835, ARMv6)?         | **Non out-of-the-box.** Mancano un device layer, un trait hardware (`bcm2835`, `armv6`), un layer kernel `v6`; la classe `pi0`/`pi0w` è esclusa dalle whitelist di `rpi-device-base`, dello schema IDP e del layout A/B `image-rota`. **Però è aggiungibile da fuori, senza toccare rpi-image-gen**: verificato con un PoC (§4).                                                                                        |
| Si può migrare senza perdere niente?                           | **Sì, tecnicamente sì.** Ogni personalizzazione del fork ha un equivalente (§5). Però quasi tutto va riscritto come layer/hook: layout a 4 partizioni, deploy xz/bmap, cache pip, gestione SSH. Due punti vanno verificati su hardware: il Bluetooth su UART senza `raspberrypi-sys-mods` e la build delle wheel sull'host.                                                                                        |
| Raccomandazione                                                | **Fattibile, con riserva.** Ha senso solo se l'obiettivo è smettere di mantenere un fork di pi-gen. Prima di impegnarsi serve un PoC con build reale su host arm64 e boot su Pi Zero W (§8). In alternativa si resta su pi-gen, che per ARMv6 è il percorso ufficialmente supportato.                                                                                                                              |

## 2. Cosa fa oggi il fork (inventario)

Differenze rispetto a pi-gen upstream (`git diff 85b4d56 HEAD`: 77 file, +2683/-451):

**Macchinario di build**

* `build.sh`: `apt-get update` prima di ogni install di pacchetti.
* `build.sh`: rimosso `ARCHIVE_FILENAME`.
* `scripts/common`: fix `udevadm settle -t`.
* `scripts/patch_packages`: nuovo.
* `Dockerfile`: `qemu-user-binfmt`, `bmaptool`.

**stage0/01a-defer-initramfs**

* Sostituisce `update-initramfs` con `/bin/true` per tutta la build.
* Il binario viene ripristinato in `export-image/04b`.

**stage2_slim**

* Symlink ai sub-stage di stage2, senza cloud-init.
* Toglie dalle liste pacchetti quelli in `packages-prepurge`.

**stage6_upgrades**

* Mount `/data` (ext4, `x-systemd.growfs`), `/boot/firmware` montato `ro`.
* `overlayroot=tmpfs:recurse=0` in `cmdline.txt`.
* Script `overlayfs-enable` / `overlayfs-disable`.
* `expand-data-partition` al primo boot; `rpi-resize` mascherato e `resize` tolto da cmdline.
* Persistenza del machine-id: script initramfs `init-bottom/machine-id` più `save-machine-id.service`.

**stage7_networking**

* `bestool` (Improv Wi-Fi via BLE, binario ARMv6 in repo) e `improv-wifi.service`.
* NetworkManager con keyfile su `/data/system/NetworkManager`, config `wlan0`.
* `wifi-watchdog`.
* sshd solo con certificati firmati dalla CA (`PUBKEY_SSH_CA`).
* Host key su `/data/system/ssh`: drop-in di `sshd-keygen.service`, `regenerate_ssh_host_keys` mascherato.
* `cloudflared` (scaricato da GitHub `latest`) e relativo service.
* `DefaultIPAccounting=yes`.

**stage8_metar**

* Pacchetti Python e di build.
* Clone di `metarstation-daemon`, virtualenv in `/opt/metarstation-daemon`.
* Doppia passata pip: `check-venv-arch.py` rileva le `.so` non ARMv6 e le ricompila da sorgente.
* Cache delle wheel (`CACHE_OUTPUT`).
* `weather-daemon.service`, `httpd.service` (busybox), tmpfiles.

**export-image**

* Layout MBR a 4 partizioni: boot 512 MiB, root A 4 GiB, root B 4 GiB vuota, data 1 GiB.
* Controllo che il rootfs stia nello slot.
* PARTUUID `-04` per `DATADEV`.
* Purge pacchetti (`packages-purge`) e disabilitazione timer/servizi.
* `arm_freq=900`.
* Archivio della cache pip; output `.img.xz` + `.bmap` + `.info` + `.sbom` + `.pipcache.tar.xz`.

**Strumenti indipendenti dal builder**

* `tools/compare-images.sh`
* `tools/improv-wifi/build-bestool.sh`
* `experimental/emulator` (QEMU raspi0)
* `experimental/wifi-watchdog-v2`

## 3. Come funziona rpi-image-gen (in breve)

* **Config YAML** (`device`, `image`, `layer`, variabili `IGconf_*`) più **layer** YAML con metadati (`X-Env-Layer-Requires/Provides`, variabili tipizzate e validate). Più **hook** per fase: `customize`, `cleanup`, `postbuild`, `preimage`, `postimage`, `deploy`, …
* **Overlay** per layer: `<layer>.d/customize.overlay/`.
* Filesystem costruito con **mmdebstrap/bdebstrap**, immagine disco con **genimage**, SBOM con syft.
* Build **rootless** (`podman unshare`). Serve comunque `CAP_SYS_ADMIN` per i mount nel namespace.
* **Host supportato**: Debian bookworm/trixie **arm64** nativo. x86 e container "possono funzionare ma non sono formalmente supportati"; su x86 serve qemu-user via binfmt_misc.
* Progetto esterno con `-S <dir>`: config, layer, device e image custom vivono nel nostro repo e rpi-image-gen resta **non forkato**. È il vantaggio principale rispetto a oggi.

## 4. Verifica del supporto armhf / Pi Zero

### 4.1 Cosa c'è e cosa manca in rpi-image-gen

| Elemento                                                                 | Stato                                                                                                                                                                                                                                                                                  |
|--------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Base Raspbian trixie armhf (`layer/raspbian/trixie/base-apt.yaml`)       | ✅ presente, con keyring Raspbian in `keydir/`                                                                                                                                                                                                                                          |
| Repo `archive.raspberrypi.com` (`rpi-debian-trixie`)                     | ✅ presente (senza vincolo di architettura, quindi usa armhf)                                                                                                                                                                                                                           |
| Kernel v6 (BCM2835)                                                      | ❌ solo `rpi-linux-v7`, `rpi-linux-v7l`, `rpi-linux-v8`, `rpi-linux-2712`. Il pacchetto `linux-image-rpi-v6` esiste per trixie armhf (1:6.18.50-1+rpt1, verificato sull'archivio), quindi basta un layer di 10 righe                                                                     |
| Device layer Pi Zero / Pi 1                                              | ❌ esistono solo `zero2w`, `pi3`, `pi4`, `pi5`, `cm4`, `cm5`, tutti basati su `rpi-generic64` (kernel v8, 64 bit)                                                                                                                                                                         |
| Trait hardware (`bcm2835`, `arm1176`, `armv6`)                           | ❌ assenti; servono solo a logiche condizionali, non sono obbligatori                                                                                                                                                                                                                   |
| `rpi-device-base`                                                        | ⚠️ `class` valida solo in `zero2w,pi3,pi4,cm4,pi5,cm5`; aggiunge `rpi-idp` e file systemd-networkd per eth0/wlan0 (che non vogliamo). **Si aggira** con un device layer che dipende direttamente da `device-base` (pattern dell'esempio ufficiale `examples/slim`)                      |
| IDP (Image Description Provisioning)                                     | ⚠️ lo schema JSON ammette solo le classi sopra. Si attiva solo se è presente il trait `hw:device:rpi`: con un device layer custom resta disattivato (`IGconf_image_idp_enable=n`, verificato). A noi non serve                                                                           |
| Layout A/B `image-rota`                                                  | ❌ `X-Env-VarRequires-Valid: regex:^(cm4\|pi4\|cm5\|pi5)$`, GPT, tryboot. **Non utilizzabile** sul Pi Zero: il layout A/B va scritto da noi (come oggi)                                                                                                                                  |
| `config.txt` di default (`templates/rpi/boot-firmware`)                  | ✅ non forza `arm_64bit`; il firmware sceglie `kernel.img` (v6) sul Pi Zero. Nel device layer custom conviene comunque fornire un `config.txt` nostro                                                                                                                                  |
| Test / CI upstream su armhf                                              | ❌ nessuno: regressioni sul percorso armhf possono passare inosservate                                                                                                                                                                                                                  |

### 4.2 Proof of concept eseguito

Ho creato un source dir esterno con tre file (in Appendice A):

* un device layer `metar-pizerow` (dipende da `device-base`, `rpi-boot-firmware`, `rpi-linux-v6`; classe `pi0w`);
* un layer kernel `rpi-linux-v6`;
* una suite `metar-base`: Raspbian trixie armhf, repo RPi, systemd, NetworkManager, bluez, openssh-server, regdb, timesyncd, fake-hwclock.

Poi ho lanciato `rpi-image-gen build -S poc -c metar-pizerow.yaml`.

Risultati:

* **Risoluzione layer, provider e validazione variabili: `PIPELINE: OK`.** Provider risolti: `debian-base → raspbian-trixie-armhf`, `device → metar-pizerow`, `image → image-rpios`, `systemd → systemd-min`, `network-activator → network-manager`, ecc. IDP disattivato automaticamente.
* La fase successiva (compilazione dei tool host: bdebstrap, genimage) non è partita. Il proxy di questa sandbox blocca i download da GitHub e non è disponibile binfmt_misc/qemu. **La build completa del filesystem armhf non è quindi stata eseguita**: è il primo passo del piano (§8).
* **Risoluzione pacchetti armhf**: simulazione `apt-get install -s` con `APT::Architecture=armhf` sui repo Raspbian trixie e archive.raspberrypi.com, con l'insieme dei pacchetti usati dal fork. Tutto risolto (504 pacchetti), fra cui:
  * `linux-image-rpi-v6` 6.18.50
  * `raspi-firmware` 1.20260915
  * `overlayroot` 0.18.debian14
  * `cloud-guest-utils`
  * `network-manager` 1.52.1+rpt4
  * `bluez` 5.82+rpt2
  * `python3` 3.13.5, `python3-pip`, `busybox`, `ffmpeg`, `build-essential`

**Conclusione sul supporto**: rpi-image-gen non "supporta" il Pi Zero W come prodotto, ma il motore non ha nulla che lo impedisca. I repository sono gli stessi di pi-gen, quindi i binari sono gli stessi, compilati per ARMv6. Il supporto si ottiene con 2 layer nostri. Il rischio è di manutenzione: è un percorso che upstream non testa.

## 5. Mappatura completa: nulla va perso

Legenda sforzo: **S** = poche righe / config, **M** = layer o hook dedicato, **L** = riprogettazione.

| # | Funzionalità del fork                                                                  | Equivalente in rpi-image-gen                                                                                                                                                                                                                                                                                                                     | Sforzo |
|---|----------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------|
| 1 | `ARCH=armhf`, `RELEASE=trixie`, repo Raspbian + RPi                                    | Layer `raspbian-trixie-armhf` + `rpi-debian-trixie`                                                                                                                                                                                                                                                                                              | S      |
| 2 | Kernel per Pi Zero W (pi-gen installa v6, v7, v8)                                      | Layer nostro `rpi-linux-v6`; bastano v6 e niente headers, quindi immagine più piccola                                                                                                                                                                                                                                                            | S      |
| 3 | Firmware Wi-Fi/BT (`firmware-brcm80211`, `bluez-firmware`)                             | Nel device layer; opzionale `dpkgopts path-exclude` per tenere solo i blob 43430 del Zero W (come `examples/slim`)                                                                                                                                                                                                                               | S      |
| 4 | `config.txt` / `cmdline.txt`, `arm_freq=900`                                           | `config.txt` nostro nell'assetdir del device layer: si possono anche togliere `vc4-kms-v3d`, `camera_auto_detect`, ecc. (headless)                                                                                                                                                                                                              | S      |
| 5 | stage0 defer-initramfs (hack `dpkg-divert`)                                            | **Nativo**: i layer kernel impostano `INITRD=No` e `customize60-initramfs-tools` genera l'initramfs una volta sola, alla fine. Lo hack sparisce                                                                                                                                                                                                  | —      |
| 6 | `apt-get update` prima di ogni install (build.sh)                                      | Non serve: i pacchetti sono dichiarati nei layer e risolti da mmdebstrap in una passata                                                                                                                                                                                                                                                          | —      |
| 7 | stage2_slim + `packages-prepurge` + `01a-optimize/packages-purge`                      | **Semplificato**: rpi-image-gen parte da una base minima e si aggiunge solo ciò che serve. Cloud-init, rpi-connect, udisks2, man-db, rpicam, ecc. non ci sono. Resta da purgare solo la toolchain usata per pip (`python3-dev`, `build-essential`, `libffi-dev`, `libssl-dev`…) con un hook `cleanup`/`customize` del layer app              | M      |
| 8 | Utente `pi` + password, niente rinomina al primo boot (`userconf-pi`)                  | `device.user1`, `device.user1pass` (o `user1passhash`), `user1sudo`. `userconf-pi` non viene installato                                                                                                                                                                                                                                          | S      |
| 9 | Hostname, locale, timezone, keymap, `WPA_COUNTRY`                                      | `device.hostname`, `locale.*`, `ieee80211.regdom` (via `cfg80211 ieee80211_regdom`, non `raspi-config do_wifi_country`)                                                                                                                                                                                                                          | S      |
| 10 | Layout 4 partizioni MBR (boot, root A, root B vuota, data)                            | **Image layer nostro** (template genimage): `hdimage` MBR con 4 primarie, `root_b` senza contenuto a dimensione fissa, `data` ext4 label `data` da 1 GiB. `image-rpios` (2 partizioni) e `image-rota` (GPT, Pi 4/5) non sono adatti                                                                                                             | M      |
| 11 | PARTUUID in fstab/cmdline (`ROOTDEV`, `DATADEV`)                                      | Hook `preimage` del layer immagine: genera la disk signature, la passa a genimage (`disk-signature`) e scrive fstab/cmdline con `PARTUUID=<sig>-02/-04`. In alternativa si usa `rpi-storage-binder` (`/dev/disk/by-slot/*`), che però va esteso per la partizione dati                                                                           | M      |
| 12 | Controllo "rootfs + margine ≤ slot 4 GiB"                                             | genimage fallisce da sé se il contenuto non sta nella `size`; un controllo esplicito con messaggio chiaro nello stesso hook `preimage`                                                                                                                                                                                                           | S      |
| 13 | FAT boot con 1 settore/cluster, feature ext4 (`^huge_file`, …) | `vfat extraargs` e `mke2fs.conf` del layer immagine (come fa `image-rpios`)                                                                                                                                                                                                                                                                      | S      |
| 14 | `overlayroot`, `/boot/firmware` ro, `overlayfs-enable/disable`                         | Layer `metar-readonly`: pacchetto `overlayroot`, overlay con gli script, hook per `cmdline.txt`. Richiede initramfs-tools (già tirato dal layer immagine)                                                                                                                                                                                        | M      |
| 15 | Niente `rpi-resize` / `resize` in cmdline                                              | **Non serve più**: `raspberrypi-sys-mods` / `rpi-resize` non vengono installati                                                                                                                                                                                                                                                                  | —      |
| 16 | `expand-data-partition` + `cloud-guest-utils`                                          | Stesso layer `metar-readonly` (overlay + `enable-units`)                                                                                                                                                                                                                                                                                         | S      |
| 17 | machine-id persistente (script initramfs `init-bottom` + `save-machine-id`)            | Il layer installa lo script in `<layer>.d/device/initramfs-tools/scripts/init-bottom/`: `customize60-initramfs-tools` lo sincronizza da solo prima di generare l'initramfs. Il `machine-id-sync.service` di `image-rota` fa una cosa simile ma solo in quel layout                                                                             | M      |
| 18 | Improv Wi-Fi (`bestool`, service), config NetworkManager su `/data`                    | Layer `metar-networking` che richiede `network-manager` e `bluez` (layer stock) + overlay con `bestool`, unit, `conf.d`, tmpfiles                                                                                                                                                                                                                | S      |
| 19 | `wifi-watchdog`                                                                        | Overlay + `enable-units` nello stesso layer                                                                                                                                                                                                                                                                                                      | S      |
| 20 | SSH con CA, host key su `/data`, `PUBKEY_SSH_CA` obbligatoria                          | ⚠️ **Non usare il layer stock `openssh-server`**: maschera `sshd-keygen.service` e installa un suo `ssh-hostkeys-generate.service` che scrive in `/etc/ssh`, in conflitto con il nostro drop-in. Serve un layer `metar-ssh` con variabile `IGconf_metar_ssh_ca` (`Required: y`, validata), che replica l'attuale `01-remote/01-run.sh` | M      |
| 21 | `cloudflared` + service                                                                | Hook `customize` (download lato host). **Consiglio**: fissare versione e sha256 invece di `latest`, per build riproducibili                                                                                                                                                                                                                     | S      |
| 22 | `DefaultIPAccounting=yes`, mask `mpris-proxy`, disable `apt-daily*`, `dpkg-db-backup`  | Overlay + hook. `sshswitch.service` non esiste più (è di `raspberrypi-sys-mods`)                                                                                                                                                                                                                                                                | S      |
| 23 | App: clone `metarstation-daemon`, venv, doppia passata pip + `check-venv-arch.py`      | Layer `metar-app`, hook `customize` con `chroot "$1" …`, identico nella sostanza. Pacchetti Python dichiarati nel layer                                                                                                                                                                                                                          | M      |
| 24 | Cache wheel pip (`CACHE_OUTPUT`, `.pipcache.tar.xz`)                                   | Hook `customize` che copia la cache host in `$1/root/.cache/pip` prima di pip e la estrae dopo (verso `LAYER_WORKDIR` o una variabile `IGconf_metar_pipcache`). Hook `deploy` per l'archivio. ⚠️ Da verificare la proprietà dei file sotto `podman unshare` (uid mappati)                                                                       | M      |
| 25 | Unit `weather-daemon`, `httpd` (busybox), tmpfiles con `envsubst`                      | Hook con `envsubst` (host) oppure file statici (l'utente è noto in config: `IGconf_device_user1`)                                                                                                                                                                                                                                               | S      |
| 26 | Output `.img.xz`, `.bmap`, `.info`, `.sbom`                                            | `deploy.compression` accetta solo `none`/`zstd` → hook `deploy` nostro per `xz` + `bmaptool create`. SBOM (syft) e manifest pacchetti sono **nativi**                                                                                                                                                                                           | S      |
| 27 | Nome immagine (`IMG_FILENAME`, no prefisso archivio)                                   | `image.name`, `image.version`                                                                                                                                                                                                                                                                                                                    | S      |
| 28 | Build in Docker (`build-docker.sh`)                                                    | Build rootless nativa (podman). Host consigliato: **arm64 Debian/RPi OS**, idealmente un Pi 5 (vedi §6.2)                                                                                                                                                                                                                                       | M      |
| 29 | `tools/compare-images.sh`, `build-bestool.sh`, emulatore QEMU, wifi-watchdog-v2        | Indipendenti dal builder: restano invariati. `compare-images.sh` va usato per confrontare immagine pi-gen e rpi-image-gen (vanno aggiunte le partizioni 3,4 a `PARTS`)                                                                                                                                                                           | —      |

### 5.1 Cose che oggi arrivano "gratis" da pi-gen e vanno ri-decise

Con pi-gen stage1/stage2 arrivano implicitamente `raspberrypi-sys-mods`, `raspi-config`, `rpi-swap`, `avahi-daemon`, `sudo`, `less`, `htop`, `rsync`, `usbutils`, ecc. In rpi-image-gen non ci sono, a meno di aggiungerli. Per ciascuno va deciso se serve:

* **Bluetooth su UART del Pi Zero W (critico)**: Improv Wi-Fi e la lettura del WS90 dipendono dall'attach dell'HCI su UART. In trixie il `bluez` del repo RPi (`+rpt`) include la parte Pi-specifica; la simulazione conferma che viene scelto il `bluez 5.82-1.1+rpt2` del repo RPi. Va comunque **verificato sul dispositivo** che `hci0` compaia senza `raspberrypi-sys-mods`.
* **`raspberrypi-sys-mods`**: regole udev per i gruppi `gpio`/`i2c`/`spi`, rfkill di default, sudoers per `pi`. Il fork oggi ne neutralizza una parte (`regenerate_ssh_host_keys`, `rpi-resize`, `sshswitch`). Opzioni: non installarlo e aggiungere solo ciò che serve (preferibile), oppure installarlo e rimettere le maschere attuali.
* **rfkill**: pi-gen scrive `/var/lib/systemd/rfkill/*:bluetooth=0` perché `sys-mods` imposta `rfkill.default_state=0`; senza `sys-mods` non serve. `improv-wifi.service` fa comunque `rfkill unblock`.
* **Rete**: `rpi-device-base` (che non useremo) genera file systemd-networkd. Con NetworkManager non vanno inclusi `systemd-net-min`/`systemd-resolved`.
* **Utility di manutenzione** (`sudo`, `less`, `vim`, `htop`, `raspi-config`…): lista esplicita nel layer.

## 6. Rischi e punti aperti

1. **armhf/ARMv6 non è un percorso testato upstream** (rischio principale). Una modifica a layer base, hook o tool host (ad es. un nuovo requisito tipo "page size", dracut, trait) può rompere il Pi Zero senza che upstream se ne accorga. Mitigazioni:
   * fissare la versione di rpi-image-gen (tag/commit, submodule o clone a SHA fisso) e aggiornarla volontariamente;
   * tenere nostri i layer device, kernel e immagine.
2. **Host di build.** Supportato: arm64 nativo. Su x86 con qemu funziona ma "non è formalmente supportato".
   * Su un **Pi 4/5 (Cortex-A72/A76, AArch32 a EL0)** il chroot armhf gira **nativo**. Il passo pip, oggi di ore sotto qemu, potrebbe accorciarsi molto.
   * Molti server arm64 **non eseguono codice a 32 bit** (Neoverse N2/V2, Graviton 3+, Apple M*, i runner GitHub `ubuntu-24.04-arm`): lì serve comunque qemu-user.
   * Serve `CAP_SYS_ADMIN` anche in container.
3. **Tag delle wheel pip su host arm64.** In un chroot armhf su kernel arm64, `uname -m` può restituire `armv8l` invece di `armv7l`, e pip potrebbe scegliere wheel diverse (o nessuna, e compilare tutto). Il controllo `check-venv-arch.py` resta la rete di sicurezza. Il comportamento effettivo va verificato nel PoC.
4. **Proprietà dei file sotto `podman unshare`** quando la cache pip viene copiata verso l'host (uid mappati).
5. **A/B futuro.** Il layout A/B "vero" di rpi-image-gen (`image-rota` + slot mapper + tryboot + OTA) è limitato a Pi 4/5/CM4/CM5 e usa GPT. Per il Pi Zero gli aggiornamenti A/B andranno progettati comunque da noi, come oggi. Qui la migrazione non porta un guadagno.
6. **Sforzo.** Non è un porting incrementale: gli stage 6-8 e le modifiche a export-image vanno riscritti come ~5 layer (`metar-pizerow`, `rpi-linux-v6`, `metar-image`, `metar-readonly`, `metar-networking`/`metar-ssh`, `metar-app`) più 3-4 hook. La logica degli script (unit, initramfs, script runtime) si riusa quasi tutta così com'è, come file di overlay.

## 7. Vantaggi della migrazione

* **Niente più fork**: rpi-image-gen resta intatto. Il nostro repo contiene solo config, layer e hook: basta con i merge periodici di pi-gen su `build.sh`, `export-image`, `scripts/common`.
* **Base minima per costruzione**: non si installa-poi-purga. Immagine più piccola e build più veloce; spariscono `stage2_slim`, `packages-prepurge`, `packages-purge`, `patch_packages`.
* **Initramfs generato una sola volta nativamente** (spariscono gli hack stage0/export-image).
* **Config dichiarativa e validata**: variabili tipizzate, `Required`, regex. `PUBKEY_SSH_CA` diventa una variabile obbligatoria validata, non un `export` a mano.
* **SBOM e manifest nativi**; build rootless.

## 8. Piano consigliato

1. **PoC di build reale** su host arm64: Pi 5 con Raspberry Pi OS 64 bit o Debian trixie arm64.
   * Partire dai file dell'Appendice A più un image layer MBR a 4 partizioni.
   * Obiettivo: immagine che fa boot su **Pi Zero W**, con Wi-Fi e `hci0` funzionanti.
2. **Porting per layer** nell'ordine: read-only/data → networking/SSH → app/pip-cache → deploy xz/bmap.
3. **Confronto** con `tools/compare-images.sh` (partizioni 1-4) fra l'ultima immagine pi-gen e quella nuova. Ogni differenza dev'essere spiegata (attese: `raspberrypi-sys-mods`, kernel v7/v8, pacchetti purgati).
4. **Test su hardware**, anche con l'emulatore `experimental/emulator/raspi0.sh` per i primi giri:
   * primo boot: growpart di `/data`, salvataggio del machine-id;
   * secondo boot: machine-id ripristinato, host key SSH stabili;
   * provisioning Improv, tunnel Cloudflare;
   * `weather-daemon` con il WS90;
   * `overlayfs-disable` / `overlayfs-enable`.
5. Solo dopo, **cutover**: il repo diventa un "source dir" per rpi-image-gen, con rpi-image-gen a commit fisso, e il fork di pi-gen viene archiviato.

Criterio di stop: se il punto 1 fallisce per limiti del motore (non per nostra configurazione), restare su pi-gen, ufficialmente supportato per ARMv6. In quel caso si possono ridurre le divergenze dal fork spostando le modifiche a `export-image` in stage propri.

---

## Appendice A: file del PoC (validati da `ig pipeline`)

`device/pizerow/device.yaml`

```yaml
# METABEGIN
# X-Env-Layer-Name: metar-pizerow
# X-Env-Layer-Category: device
# X-Env-Layer-Desc: Raspberry Pi Zero W (BCM2835, ARMv6) - METAR Station
# X-Env-Layer-Version: 0.1.0
# X-Env-Layer-Requires: device-base,rpi-boot-firmware,rpi-linux-v6
# X-Env-Layer-Provides: device,rpi-device
#
# X-Env-VarPrefix: device
#
# X-Env-Var-class: pi0w
# X-Env-Var-class-Desc: Device class
# X-Env-Var-class-Required: n
# X-Env-Var-class-Valid: keywords:pi0w
# X-Env-Var-class-Set: y
#
# X-Env-Var-storage_type: sd
# X-Env-Var-storage_type-Desc: Storage type
# X-Env-Var-storage_type-Required: n
# X-Env-Var-storage_type-Valid: keywords:sd
# X-Env-Var-storage_type-Set: y
#
# X-Env-Var-assetdir: ${DIRECTORY}
# X-Env-Var-assetdir-Desc: Device asset dir
# X-Env-Var-assetdir-Required: n
# X-Env-Var-assetdir-Valid: dir
# X-Env-Var-assetdir-Set: y
# METAEND
---
mmdebstrap:
  packages:
    - udev
    - firmware-brcm80211
    - bluez-firmware
```

`layer/linux-image-v6.yaml`

```yaml
# METABEGIN
# X-Env-Layer-Name: rpi-linux-v6
# X-Env-Layer-Category: kernel
# X-Env-Layer-Desc: Raspberry Pi v6 kernel (BCM2835: Pi 1, Zero, Zero W)
# X-Env-Layer-Version: 1.0.0
# X-Env-Layer-Requires: linux-base
# METAEND
---
env:
  INITRD: "No"
mmdebstrap:
  packages:
    - linux-image-rpi-v6
```

`layer/metar-base.yaml`

```yaml
# METABEGIN
# X-Env-Layer-Name: metar-base
# X-Env-Layer-Category: suite
# X-Env-Layer-Desc: Raspbian trixie armhf base for the METAR Station
# X-Env-Layer-Version: 0.1.0
# X-Env-Layer-Requires: raspbian-trixie-armhf,rpi-debian-trixie,rpi-essential-base,
#  rpi-misc-skel,systemd-min,network-manager,bluez,openssh-server,
#  wireless-regulatory,systemd-timesyncd,fake-hwclock
# METAEND
---
```

(Nella versione definitiva `openssh-server` va sostituito da un layer `metar-ssh`, vedi §5 riga 20.)

`config/metar-pizerow.yaml`

```yaml
device:
  layer: metar-pizerow
  hostname: metarstation
  user1: pi

image:
  layer: image-rpios        # da sostituire con l'image layer a 4 partizioni
  name: metar-pizerow

locale:
  default: en_GB.UTF-8
  timezone: Europe/Rome
  keyboard_keymap: it
  keyboard_layout: Italian

ieee80211:
  regdom: IT

layer:
  base: metar-base
```

Comando: `rpi-image-gen build -S <repo> -c metar-pizerow.yaml`

Esito in sandbox: `PIPELINE: OK`. Stop successivo alla compilazione dei tool host, per restrizioni di rete della sandbox; non è un limite di rpi-image-gen.
