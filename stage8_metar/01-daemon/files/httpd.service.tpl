[Unit]
Description=Simple HTTP server
After=multi-user.target
StartLimitIntervalSec=300
StartLimitBurst=10
StartLimitAction=reboot
ConditionPathExists=$METARSTATION_DASHBOARD_PUBROOT

[Service]
User=$METARSTATION_USER
Restart=on-failure
RestartSec=5s
Type=simple
ExecStart=/usr/bin/busybox httpd -f -p 9321 -h "$METARSTATION_DASHBOARD_PUBROOT"
StandardError=journal
SyslogIdentifier=httpd

[Install]
WantedBy=default.target
