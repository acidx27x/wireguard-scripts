# WireGuard Scripts

Small helper scripts for installing a WireGuard server and managing generated clients.

## Install

Run on a Debian/Ubuntu VPS:

```bash
cd wireguard-scripts
sudo ./install.sh
```

The installer installs WireGuard packages, generates server keys, writes `/etc/wireguard/wg0.conf`, enables IPv4 forwarding, opens the WireGuard UDP port with UFW, and starts `wg-quick@wg0`.

## Client Commands

Create a new client, add it to the server config, try to add it to the live `wg0` interface, and print a QR code:

```bash
sudo ./add-client.sh phone
```

Add an already generated client back to the server config:

```bash
sudo ./add-peer.sh phone
```

Temporarily add an already generated client to the live `wg0` interface only:

```bash
sudo ./add-peer.sh --tmp phone
```

Remove an already generated client from the server config:

```bash
sudo ./remove-peer.sh phone
```

Temporarily remove an already generated client from the live `wg0` interface only:

```bash
sudo ./remove-peer.sh --tmp phone
```

Remove a generated client completely: live peer, server config peer block, `/etc/hosts` entry, and client directory:

```bash
sudo ./remove-client.sh phone
```

Remove WireGuard data created by this script bundle:

```bash
sudo ./uninstall.sh
```

`uninstall.sh` stops and disables `wg-quick@wg0`, removes the generated server config and keys, removes generated client files while keeping `clients/.gitkeep`, removes script state files and `install-backups`, and tries to remove the saved UFW UDP allow rule. It does not uninstall apt packages.

## Client Setup

Use the generated `clients/<name>/wg0.conf` file on the client device.

Install WireGuard on the client first. On modern Debian/Ubuntu systems:

```bash
sudo apt update
sudo apt install wireguard
```

Then copy the generated config to the client WireGuard directory:

```bash
sudo install -m 600 wg0.conf /etc/wireguard/wg0.conf
```

Start the client tunnel:

```bash
sudo wg-quick up wg0
```

Optionally enable it on boot:

```bash
sudo systemctl enable wg-quick@wg0.service
```

By default, generated client configs route all IPv4 traffic through the VPN:

```ini
AllowedIPs = 0.0.0.0/0
```

To route only VPN subnet traffic, edit `wg0-client.example.conf` before creating clients.

## Notes

Client names may contain only letters, numbers, dot, underscore, and dash.

The server template uses `SaveConfig = false` so the config file remains the source of truth for these scripts.

This project was influenced by:

- https://www.ckn.io/blog/2017/11/14/wireguard-vpn-typical-setup/
- https://www.wireguard.com/install/
- https://www.wireguard.com/quickstart/
