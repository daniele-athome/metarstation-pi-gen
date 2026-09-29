[Unit]
Description=METAR Station Weather daemon
After=multi-user.target
StartLimitIntervalSec=300
StartLimitBurst=10
StartLimitAction=reboot
ConditionPathExists=/data/metarstation/config.toml

[Service]
User=$METARSTATION_USER
Restart=on-failure
RestartSec=5s
Type=notify
ExecStart=/opt/metarstation-daemon/bin/weather-daemon -c /data/metarstation/config.toml
StandardError=journal
SyslogIdentifier=weather-daemon

[Install]
WantedBy=default.target
