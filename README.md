# MTProxy Setup Script

A single-script installer for [Telegram MTProxy](https://github.com/TelegramMessenger/MTProxy) on Ubuntu. Builds from source, registers a systemd service, sets up a daily config-refresh cron job, and prints a ready-to-use `tg://` link on completion.

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04
- Root access (`sudo`)
- Outbound internet access (to reach GitHub and `core.telegram.org`)

## Quick Start

```bash
sudo bash setup_mtproxy.sh
```

That’s it. The script will handle everything and print your proxy link at the end.

## Usage

```
sudo bash setup_mtproxy.sh [OPTIONS]
```

|Option                     |Default       |Description                        |
|---------------------------|--------------|-----------------------------------|
|`-p`, `--port <port>`      |`443`         |Client port (what users connect to)|
|`-s`, `--stats-port <port>`|`8888`        |Local stats port                   |
|`-w`, `--workers <n>`      |`1`           |Number of worker processes         |
|`-d`, `--dir <path>`       |`/opt/MTProxy`|Installation directory             |
|`-h`, `--help`             |—             |Show help and exit                 |

**Examples:**

```bash
# Default install on port 443
sudo bash setup_mtproxy.sh

# Custom client port (useful if 443 is already taken by nginx/apache)
sudo bash setup_mtproxy.sh --port 8443

# Multi-core server with 4 workers
sudo bash setup_mtproxy.sh --port 8443 --workers 4

# Custom port, dir, and workers
sudo bash setup_mtproxy.sh --port 2443 --dir /srv/mtproxy --workers 2
```

## What the Script Does

The script runs these steps in order, stopping immediately if any step fails:

1. **Check port availability** — fails early if the chosen port is already in use
1. **Install dependencies** — `git`, `curl`, `build-essential`, `libssl-dev`, `zlib1g-dev`, `openssl`, `iproute2`
1. **Clone & build** — clones the MTProxy repo to the install directory and compiles with `make -j$(nproc)`; on re-runs, pulls the latest changes instead of re-cloning
1. **Fetch Telegram configs** — downloads `proxy-secret` and `proxy-multi.conf` from `core.telegram.org`; writes to a temp file first, replaces the live file only on success
1. **Generate secret** — generates a 32-char hex secret via `openssl rand`; saved to `<INSTALL_DIR>/.secret` (chmod 600) and reused on subsequent runs
1. **Set up daily cron** — installs `/etc/cron.daily/mtproxy-update-config` to refresh Telegram configs every day and restart the service; uses the same safe temp-file approach
1. **Create systemd service** — writes `/etc/systemd/system/MTProxy.service`, enables it, starts it, and verifies it’s actually running
1. **Open firewall** — adds a ufw rule for the client port if ufw is active
1. **Print summary** — shows server IP, port, secret, the `tg://` link, and useful commands

## After Installation

### Connect from Telegram

Use the `tg://` link printed at the end of the script, or enter the details manually in Telegram → Settings → Data and Storage → Proxy.

### Anti-DPI / Random Padding

Add `dd` prefix to the secret when sharing with clients (`cafe...babe` → `ddcafe...babe`). This enables random padding to help avoid detection by traffic analysis.

### Register with @MTProxybot (optional)

Registering your proxy with [@MTProxybot](https://t.me/MTProxybot) on Telegram gives you a tag that lets you monetize the proxy (users get a “Telegram Premium” promotion). Once you have the tag:

1. Edit the service file:
   
   ```bash
   sudo nano /etc/systemd/system/MTProxy.service
   ```
1. Add `-P <your_tag>` to the `ExecStart` line
1. Reload and restart:
   
   ```bash
   sudo systemctl daemon-reload && sudo systemctl restart MTProxy
   ```

## Managing the Service

```bash
# Status
systemctl status MTProxy

# Live logs
journalctl -u MTProxy -f

# Restart
systemctl restart MTProxy

# Stop / disable
systemctl stop MTProxy
systemctl disable MTProxy

# Connection stats
wget -qO- localhost:8888/stats
```

## File Layout

```
/opt/MTProxy/                        ← install directory (default)
├── objs/bin/mtproto-proxy           ← compiled binary
├── proxy-secret                     ← Telegram server secret (refreshed daily)
├── proxy-multi.conf                 ← Telegram server config (refreshed daily)
└── .secret                          ← your generated proxy secret (chmod 600)

/etc/systemd/system/MTProxy.service  ← systemd unit
/etc/cron.daily/mtproxy-update-config ← daily config refresh cron job
```

## Re-running the Script

Running the script again on an already-configured server is safe:

- The install directory is pulled (not re-cloned)
- The existing secret in `.secret` is reused — your proxy link stays the same
- The systemd service and cron job are overwritten with the current settings
- The binary is rebuilt from the latest source

## Troubleshooting

**Service won’t start**

```bash
journalctl -u MTProxy -n 50
```

**Port already in use**

Pass a different port: `sudo bash setup_mtproxy.sh --port 8443`

**Clients can’t connect**

Check that the port is open in your cloud provider’s firewall/security group (ufw alone is not enough on GCP, AWS, Hetzner, etc.).

**Config files look empty or corrupted**

Manually re-fetch them:

```bash
curl -sSf https://core.telegram.org/getProxySecret -o /opt/MTProxy/proxy-secret
curl -sSf https://core.telegram.org/getProxyConfig -o /opt/MTProxy/proxy-multi.conf
sudo systemctl restart MTProxy
```

## License

This script is released under the MIT License.
The MTProxy binary itself is licensed under [GPLv2](https://github.com/TelegramMessenger/MTProxy/blob/master/GPLv2).