# vpngw Python Telegram bot

This is the Telegram bot for the current release. The service runs as `vpngw-bot`; privileged VPN switching is limited to the root helper and the allowlisted locations `RO`, `DE`, and `FI`. Shell scripts remain the system's VPN, routing, recovery, and notification layer.

## Commands

- `/start` and `/menu`: show the VPN location and status menu.
- `/status`: report the GeoIP city/country observed through the active tunnel and measure download speed using the first configured profile.
- `/speed`: choose a configured speed-test service.
- `/speedadd <id> <name> <https-url> <connect-timeout> <max-time>`: add a speed-test service as an administrator. The name is one word.
- Menu buttons switch to the fixed VPN locations or run status/speed checks. Long operations show progress and then update the same message.

Example:

```text
/speedadd fast FastTest https://speed.example/test.bin 8 30
```

The endpoint must be a direct HTTPS download on port 443, without redirects or credentials, and resolve only to public IP addresses including at least one IPv4 address. Connect timeout is 1-60 seconds; maximum test time is 1-120 seconds. User-added profiles are stored in the bot SQLite state database and appear in `/speed`. Measurements always use the current tunnel interface; the endpoint's country is independent of the selected VPN location.

`TG_ALLOWED_CHAT_IDS` and `TG_ADMIN_CHAT_IDS` accept only positive private-chat/user IDs; group and channel IDs are rejected so every allowed principal is a single account. By default, every allowed chat ID is also an administrator. To use a smaller admin set, define `TG_ADMIN_CHAT_IDS` as a comma-separated subset of `TG_ALLOWED_CHAT_IDS` in `/etc/vpngw-bot.env`.

## Deployment

The Pi deployment uses `/home/pi/.venv`, `/etc/vpngw-bot.env`, `/etc/vpngw-bot.conf`, `/etc/vpngw-speed-tests.conf`, and `/var/lib/vpngw`. Store `TG_TOKEN` only in the protected environment file; never put it in a command line or this repository.

Only the Python service polls Telegram. Manual bot switches and automatic starter recovery share the `/dev/shm/vpn_stats/vpn-switch.lock`; if either path is busy, the competing operation fails immediately with an explicit retry message.

From the deployed checkout on the Pi:

```bash
sudo /home/pi/app/vpngw/tools/pi-bot-deploy-commands.sh
```

The script installs and enables the Python systemd unit, updates the root recovery/logging scripts, installs the sudoers allowlist, fixes the runtime directory and SQLite permissions, and restarts `vpngw-bot.service`. It does not change the VPN location. The service runs as `vpngw-bot`; only the switch helper runs as root.

## Operations

```bash
sudo systemctl is-active vpngw-bot.service
sudo journalctl -u vpngw-bot.service -f
sudo /opt/adguardvpn_cli/adguardvpn-cli status
sudo stat -c '%U:%G %a %n' /dev/shm/vpn_stats /var/lib/vpngw/bot_state.db
```

Expected permissions are `root:root 700` for `/dev/shm/vpn_stats` and `vpngw-bot:vpngw-bot` for the bot database files. A SQLite `readonly database` startup error usually means the database file is not writable by the service account.

`vpn-log-sync.sh` is the only script that drains `vpn-live.log` into the persistent log. Writers and the drainer share `vpn-log.lock`, preventing a writer from appending while the RAM log is copied and truncated.

After reboot, `/dev/shm` is recreated. The deploy script installs and applies the tmpfiles rule described in the [production runbook](../docs/runbooks/python-bot-production.md), so root-owned recovery scripts have their required directory before their first run.

## Development and tests

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r python_bot/requirements.txt
python -m pytest -q python_bot/tests
```

Tests use fake shell functions and never require a real Telegram token or VPN switch. The service definition is in [python_bot/systemd/vpngw-bot.service](systemd/vpngw-bot.service); the safe adapter is in [vpngw_bot/adapter.py](../vpngw_bot/adapter.py).
