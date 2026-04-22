# private-vpn-bootstrap

One-command WireGuard full private VPN bootstrap for Ubuntu/Debian VPS.

## What it does

- installs WireGuard and qrencode
- enables IPv4 forwarding
- builds a full-tunnel WireGuard gateway on the VPS
- creates one or more client peers
- writes client `.conf` files
- writes QR PNG + ANSI QR text for easy iPhone import
- enables and restarts `wg-quick@wg0`

## Tested target

- Ubuntu 22.04 VPS
- Full-tunnel IPv4 NAT via the VPS public interface

## One-command setup

```bash
sudo bash setup-private-vpn.sh --peer macbook --peer iphone
```

If public endpoint auto-detection is wrong, pin it manually:

```bash
sudo bash setup-private-vpn.sh --endpoint YOUR_SERVER_PUBLIC_IP --peer macbook --peer iphone
```

## Output

By default client files are written to:

```bash
/root/wireguard-clients/
```

Examples:

- `/root/wireguard-clients/macbook.conf`
- `/root/wireguard-clients/macbook.png`
- `/root/wireguard-clients/iphone.conf`
- `/root/wireguard-clients/iphone.png`

## Import on client devices

### macOS

Import the generated `.conf` into the WireGuard app.

### iPhone

Open WireGuard iOS, tap **Add a Tunnel**, then scan the generated QR PNG.

## Notes

- this setup is full-tunnel for **IPv4** only
- it does **not** configure IPv6 routing yet
- it assumes `iptables` NAT on the VPS public interface
- the script is idempotent for existing key material, so re-running it reuses keys when they already exist

## Useful flags

```bash
--peer NAME[:OCTET]
--endpoint HOST
--public-iface IFACE
--port PORT
--output-dir PATH
--dry-run
--no-qr
```

## Dry-run validation

```bash
sudo bash setup-private-vpn.sh --dry-run --endpoint 203.0.113.10 --public-iface eth0 --peer macbook --peer iphone
```

## Safety

Before re-running on an active VPN server, keep a second SSH sess
