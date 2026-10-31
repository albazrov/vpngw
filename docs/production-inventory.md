# Production inventory: Raspberry Pi 4B VPN gateway

## Scope and sensitivity

This inventory records production parameters supplied by the operator and implementation details found in repository scripts. It is not a live-system audit: OS version, permissions, running processes, routes, firewall state, Docker installation and mount status still require verification on the Raspberry Pi.

The network addresses below reveal internal topology. Confirm repository access/classification before publishing. No tokens, passwords, VPN credentials or device authorization URLs belong in this document. Do not copy the contents of `/etc/vpn-gw.conf` or `/etc/msmtprc` into Git, issues or logs.

Status labels: **Provided** means supplied but not independently verified; **Code-confirmed** means referenced by tracked source; **Verify on host** means inspect the live Pi.

## Host and deployment

| Item | Value | Status / note |
| --- | --- | --- |
| Hardware | Raspberry Pi 4B | Provided |
| OS/release/codename | Debian GNU/Linux 13 (`trixie`) | Collected 2026-10-31 21:55 MSK |
| Kernel and architecture | `Linux 6.12.75+rpt-rpi-v8 aarch64 GNU/Linux`, `arm64` | Collected 2026-10-31 |
| Production scripts directory (`MAIN_SH_DIR`) | `/usr/local/bin/vpngw` | Provided; used by root crontab |
| Production repository HEAD | `1f5eec1` | Collector snapshot from `/usr/local/bin/vpngw`; Git HEAD alone does not prove which files are installed |
| Active bot/functions SHA-256 | Not captured by 23:42 report | Re-run updated collector to compare active files against source |
| Production config | `/etc/vpn-gw.conf` | Code-confirmed; sourced as Bash by scripts |
| AdGuard CLI (`ADG_BIN`) | `/opt/adguardvpn_cli/adguardvpn-cli` | Provided; starter also hardcodes this path in recovery |
| SMTP config path | `/etc/msmtprc` | Provided; script assigns this path after sourcing config |
| Test deployment directory | Not configured | Proposed separately as `/srv/vpngw-test/`; verify free space/ownership |
| Production release/rollback layout | Not documented by operator | Current active revision and backup method must be recorded before deployment |
| Docker Engine/Compose | Engine `29.4.3`, Compose `5.1.3` | Already installed and running Gitea; Docker is an active production workload |
| Existing Docker container | `gitea` (`gitea/gitea:latest`), running | Snapshot showed it running for about 38 hours; do not restart/prune Docker or alter daemon/network settings during test setup |
| External storage mount | `/dev/sda1`, ext4, `/mnt/external_data` | Snapshot showed about 54 GB available |
| Bot supervisor | `vpn-tg-bot.service` | Provided via `systemctl status 1104` |
| Bot unit file | `/etc/systemd/system/vpn-tg-bot.service` | Provided by `systemctl cat` output |
| Unit description/type | `AdGuard VPN Telegram Control Bot Daemon` / `simple` | Provided |
| Unit ordering | `After=network.target` | Provided; this orders after network setup target but does not guarantee external API connectivity |
| ExecStart | `/usr/local/bin/vpngw/vpn-tg-bot.sh` | Provided; do not include token-bearing child argv in shared diagnostics |
| Service user | `root` | Provided; bot therefore has root privileges; least-privilege migration is recommended |
| Service group | Default/empty in unit | Collector showed no explicit `Group` value |
| Restart policy | `always`, `RestartSec=10` | Provided |
| Effective start limit | 5 starts per 10 seconds | Collected from systemd properties |
| Enabled at boot | Yes | Provided (`enabled`; preset enabled) |
| Install target | `multi-user.target` | Provided |

## Configuration inventory

### Paths and logs

| Setting | Value | Note |
| --- | --- | --- |
| `SYSTEM_NAME` | `RPi4` | Provided |
| `MAIN_SH_DIR` | `/usr/local/bin/vpngw` | Production scripts |
| `ADG_BIN` | `/opt/adguardvpn_cli/adguardvpn-cli` | CLI executable path |
| `LOG_RAM` | `/dev/shm/vpn_stats/vpn-live.log` | Volatile RAM log |
| `LOG_DISK` | `/mnt/external_data/vpn-gateway.log` | Persistent log target |
| `STATS_DIR` | `/dev/shm/vpn_stats` | Volatile counters/state |
| `IPSET_CACHE` | `/mnt/external_data/ru-zones.cache` | Persistent RU ranges cache |
| `LOC_CACHE_DISK` | `/mnt/external_data/adguard_locs.db` | Persistent location cache |
| `CACHE_FILE` | `/dev/shm/adguard_locs.cache` | RAM location cache |
| `MSMTP_CONF` | `/etc/msmtprc` | Listed twice in supplied config; see discrepancies |
| `MSMTP_ACC` | `default` | Account name, not a credential |
| `AUTH_TMP` | `/dev/shm/adguard_auth.tmp` | Volatile auth session output; do not copy to reports |
| `AUTH_FLAG` | `/dev/shm/vpn_stats/waiting_auth` | Auth wait marker |
| `LAST_URL_FILE` | `/dev/shm/last_auth_url.txt` | Sensitive short-lived device URL; never include contents in logs/backups |
| `LAST_SEND_TIME` | `/dev/shm/last_auth_time.txt` | Provided; no tracked consumer found |
| `TG_LAST_SEND_FILE` | `/dev/shm/vpn_stats/tg_last_report.txt` | Report timestamp state |
| `EM_LAST_SEND_FILE` | `/dev/shm/vpn_stats/em_last_report.txt` | Report timestamp state |
| `QUEUE_DIR` | `/dev/shm/tg_queue` | Telegram send queue |
| `OFFSET_FILE` | `/dev/shm/vpn_stats/tg_bot_offset.txt` | Telegram polling offset; volatile across reboot |

All `/dev/shm` files are volatile and may disappear on reboot. The collector found `/dev/shm/vpn_stats` currently owned by `root:root` with mode `777`; this is unsafe for shared state and must be tightened after reviewing consumers. A prior service start logged that this directory was missing, so startup creation must also be made deterministic.

### Collected file permissions

| Path | Owner:group | Mode | Status |
| --- | --- | --- | --- |
| `/etc/vpn-gw.conf` | `root:root` | `600` | Collected 2026-10-31 |
| `/etc/msmtprc` | `root:root` | `600` | Collected 2026-10-31 |
| `/usr/local/bin/vpngw/vpn-tg-bot.sh` | `root:root` | `755` | Latest collector snapshot 2026-10-31 23:42; earlier snapshot was `pi:pi 755` |
| `/usr/local/bin/vpngw/vpn-functions.sh` | `root:root` | `755` | Latest collector snapshot 2026-10-31 23:42; earlier snapshot was `pi:pi 755` |

### Network and routing

These internal addresses are operator-provided and not independently verified.

| Setting | Value | Purpose |
| --- | --- | --- |
| `NET_IF` | `eth0` | ISP/WAN interface |
| `VPN_IF` | `tun0` | VPN tunnel interface |
| `GATEWAY` | `192.168.3.1` | ISP-side gateway |
| `NET_IF_IP` | `192.168.3.2` | Provided host address; no tracked script consumer found |
| `LOCAL_NET` | `192.168.3.0/24` | Local network routing rules |
| `HOME_NET` | `192.168.1.0/24` | Home subnet exemption |
| `TABLE` | `no-vpn-ru` | Policy routing table |
| `MARK` | `0x371` | Firewall packet mark |
| `IPSET_NAME` | `updateru` | IP set used by bypass rules |
| `IPSET_TIMEOUT` | `172800` seconds | Two days |
| `SOURCE_URL` | `https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone` | IP range feed |
| `CHECK_TARGETS` | `1.1.1.1`, `8.8.8.8`, `google.com`, `cloudflare.com` | Connectivity targets |
| Docker test subnet | Not allocated | Must be checked against all IPv4/IPv6/VPN routes before use |
| IPv6 routing/firewall policy | Not supplied | Verify on host; do not assume IPv4 policy covers IPv6 |

### VPN policy and monitoring

| Setting | Value | Note |
| --- | --- | --- |
| `TEMP_LIMIT` | `75` °C | CPU temperature threshold |
| `CHECK_PRIORITY` | `false` | Starter priority check flag |
| `ENABLE_SPEED_TEST` | `true` | No tracked script consumer found |
| `MIN_SPEED_KBPS` | `1500` | No tracked script consumer found |
| `PRIORITY_LOCS` | `LT`, `FI`, `PL`, `DE`, `NL` | Recovery order supplied |
| `EXCLUDE_LOCS` | `BR`, `RU`, `CN`, `IR`, `TR` | Excluded recovery locations |
| `LOC_CACHE_TTL` | `86400` seconds | One day |
| `AUTH_POLL_INTERVAL` / `AUTH_POLL_COUNT` | `5` seconds / `5` polls | Supplied values |
| `URL_TIME_VALID` | `1800` seconds | Auth link validity |

The supplied comment says auth monitoring performs 10 polls × 10 seconds. The supplied values are 5 polls × 5 seconds; the tracked helper sleeps between polls, giving about 20 seconds of sleep plus command overhead per invocation. Update the comment or values only after confirming intended behavior.

### Reports and credentials

| Setting | Value | Note |
| --- | --- | --- |
| `REPORT_TO_TG` / `REPORT_TG_INTERVAL` | `true` / `60` minutes | Hourly cron aligns with this interval |
| `REPORT_TO_EMAIL` / `REPORT_EMAIL_INTERVAL` | `true` / `30` minutes | Cron invokes report hourly, so effective scheduled cadence is at most once per hour |
| `TG_TOKEN` | Not recorded | Secret; verify presence/permission without printing |
| `TG_CHAT_ID` | Not recorded | Access-control identifier; verify securely |
| SMTP password/credentials | Not recorded | Secret; inspect only metadata and service access |
| Email sender/recipients | Not copied here | `vpn-email-send.sh` supplies recipient arguments in source; compare with operational requirements |

## Root crontab

The following was supplied as output of `sudo crontab -l`; `MAILTO=""` disables cron mail. These entries therefore run as root unless the crontab is later changed.

| Schedule | Command | Purpose / note |
| --- | --- | --- |
| Every minute | `/usr/local/bin/vpngw/adguardvpn-starter.sh \| systemd-cat -t STARTER` | VPN check/recovery; starter uses nonblocking lock. Overlapping cron launches exit rather than wait. |
| Every 10 minutes | `/usr/local/bin/vpngw/vpn-log-sync.sh \| systemd-cat -t LOG-SYNC` | Append RAM log to persistent storage |
| Every hour, minute 0 | `/usr/local/bin/vpngw/vpn-hourly-report.sh \| systemd-cat -t HOURLY-REPORT` | Reports; email interval config is 30 minutes but schedule is hourly |
| Every 15 minutes | `/usr/local/bin/vpngw/vpn-bypass-update.sh \| systemd-cat -t BYPASS-UPDATE` | Routing/IP set infrastructure check; script has nonblocking lock |
| At reboot, after 45 seconds | `sleep 45 && /usr/local/bin/vpngw/adguardvpn-starter.sh reboot_event \| systemd-cat -t STARTER` | Recovery after boot |
| Daily at 03:00 | `/usr/local/bin/vpngw/vpn-loc-update.sh \| systemd-cat -t LOC-UPDATE` | Refresh location cache |
| Daily at 02:00 | `/usr/local/bin/vpngw/vpn-bypass-update.sh force \| systemd-cat -t BYPASS-UPDATE` | Force IP feed refresh; may exit if another bypass update holds lock |

The Telegram bot is not listed in this crontab; it is supervised by `vpn-tg-bot.service`. There is currently no shared lock between manual bot reconnects and the minute-by-minute starter; do not run production reconnect smoke tests until coordinated or protected by the planned common lock.

## Telegram bot systemd observation

Snapshot supplied by the operator on 2026-10-31 (times shown by the host in MSK):

| Property | Observed value | Status / note |
| --- | --- | --- |
| Unit | `vpn-tg-bot.service` | Loaded from `/etc/systemd/system/vpn-tg-bot.service` |
| Description / type | `AdGuard VPN Telegram Control Bot Daemon` / `simple` | Provided unit content |
| Ordering | `After=network.target` | Does not guarantee DNS/Internet/Telegram API is ready |
| ExecStart | `/usr/local/bin/vpngw/vpn-tg-bot.sh` | Provided; starts Bash bot entrypoint |
| Service user | `root` | Provided; bot has full root authority unless further constrained by systemd settings |
| Restart | `always`, after 10 seconds | Provided |
| Start limit | 5 starts per 10 seconds | Effective systemd properties collected 2026-10-31 |
| Install target | `multi-user.target` | Provided |
| Enabled | Yes | Starts at boot according to systemd snapshot |
| State | Active/running | Collector snapshot showed running at 2026-10-31 21:55 MSK |
| Latest observed service check | Active | Collector snapshot 2026-10-31 23:42 MSK |
| Main process | `vpn-tg-bot.sh` (`/bin/bash /usr/local/bin/vpngw/vpn-tg-bot.sh`) | PID intentionally not retained from collector |
| Long-poll child | `curl` calling Telegram `getUpdates` | Collector still found the configured token in argv for one process at 2026-10-31 21:55 MSK; token value omitted |
| Effective group | Default/empty in unit | Collector showed no explicit `Group` value |
| Sandboxing | `NoNewPrivileges=no`, `PrivateTmp=no`, `ProtectSystem=no`, `ProtectHome=no`, no read/write path restrictions, full capability set | Collector output; service is effectively unsandboxed and runs as root |
| Startup log error | `vpn-functions.sh` failed to append `/dev/shm/vpn_stats/vpn-live.log` because the parent directory did not exist | Earlier start observation; current directory exists but is world-writable; fix initialization and permissions |

**Credential incident:** the Telegram bot token appeared in the original `systemctl status` output and the collector again found it in argv for one process at 2026-10-31 21:55 MSK. Rotation/remediation is therefore **not yet verified**. Treat the exposed token as compromised: revoke/rotate via BotFather, update the protected runtime config, restart the bot, and verify the replacement no longer appears in process arguments or status output. Do not copy the old/new token into this inventory, logs, PRs or support messages. Rotation alone is insufficient while code still places the replacement token in argv.

Avoid `systemctl status <pid>` and `ps ... args` while the current implementation puts credentials in command-line URLs. Use explicitly selected non-secret unit properties; inspect unit contents locally and redact any `Environment`, URL or credential values before sharing.

## Implementation findings and discrepancies

- Tracked scripts source `/etc/vpn-gw.conf`; it is executable shell code, so ownership and write permissions are code-integrity controls as well as secret protection.
- Collector measured `/etc/vpn-gw.conf` and `/etc/msmtprc` as `root:root 600`; this limits direct reads but does not prevent the bot's current argv token leak.
- `vpn-tg-bot.sh` and `vpn-tg-send.sh` read `TG_TOKEN`; bot checks `TG_CHAT_ID`. Actual values are intentionally absent.
- The supplied systemd unit runs the bot as `root` with `Type=simple`, `Restart=always`, `RestartSec=10`, and `After=network.target`; collector showed no sandboxing restrictions and the full default capability set. Root execution magnifies the impact of bot compromise and should be addressed in the privilege-separation plan.
- Collector measured `/usr/local/bin/vpngw/vpn-tg-bot.sh` and `vpn-functions.sh` as `pi:pi` mode `755`, while systemd executes the bot as root and sources the functions file. The `pi` owner can modify code later executed with root privileges; production scripts should be root-owned/non-writable by untrusted accounts and deployed through a controlled privileged process.
- A later collector snapshot (2026-10-31 23:42) reports both files as `root:root 755`, so file ownership was changed after the earlier finding. F-14 remains open until parent-directory modes and all root-cron scripts are checked and the deployment is tied to a clean approved source SHA.
- Current bot polling passes the Telegram API URL, including its token path, as a `curl` argument. The supplied systemd cgroup output confirmed command-line exposure; rotate the exposed token and fix argv handling before treating the bot credential as protected.
- Bot startup previously logged a failure because `/dev/shm/vpn_stats` did not exist at startup. At latest collection the directory exists but is `root:root 777`; verify it is created consistently and tighten permissions. Do not use `chmod 777` as the fix.
- Latest collector health snapshot: bot unit `active`, configured VPN interface `tun0` present, `net.ipv4.ip_forward=1`. This is not a full client-routing/connectivity smoke test.
- `vpn-email-send.sh` assigns `MSMTP_CONF="/etc/msmtprc"` and `MSMTP_ACC="default"` after sourcing the common config, overriding alternatives configured there. `MSMTP_CONF` is also duplicated in the supplied config.
- `NET_IF_IP`, `ENABLE_SPEED_TEST`, `MIN_SPEED_KBPS` and `LAST_SEND_TIME` had no tracked consumers in the inspected scripts. Check local/untracked consumers before removing them.
- `vpn-bypass-update.sh` changes IP forwarding, policy routing, iptables and ipset. Installing/running Docker on this router needs a separate reviewed maintenance plan.
- `.gitignore` excludes `*.conf`, `*.env` and `config.sh`; still check Git history/status before assuming no secret was ever committed.
- Docker Engine `29.4.3` and Compose `5.1.3` are installed; a Gitea container was running during collection. Treat Docker daemon changes/cleanup as production changes and use a separate host for test Docker workloads.

## Host facts to complete

Do not put secret values in this section.

- Hostname / OS release / architecture: `pi4b` / Debian 13 `trixie` / `arm64` (collected 2026-10-31)
- Kernel: `Linux 6.12.75+rpt-rpi-v8 aarch64 GNU/Linux`
- `/etc/vpn-gw.conf` owner:mode: `root:root 600`
- `/etc/msmtprc` owner:mode: `root:root 600`
- `vpn-tg-bot.service`: root, enabled/active, Restart=always/10s, start limit 5 per 10s; no sandboxing restrictions shown
- Telegram token rotated after argv exposure; date/reference (no token value): `________________`
- Bot argv no longer contains Telegram token: latest collection was **YES, one process** at 2026-10-31 23:42 MSK
- Bot/functions files: latest snapshot `root:root 755`; parent directory and all root-executed scripts still need permission audit
- `/dev/shm/vpn_stats`: `root:root 777`; permission remediation remains open
- Cron checked against current root crontab on date: `________________`
- `/mnt/external_data`: `/dev/sda1`, ext4, about 54 GB free in snapshot
- Docker Engine/Compose: `29.4.3` / `5.1.3`; Gitea container running
- Current production commit SHA: `1f5eec1` (short SHA)
- Source checkout at collection: `6cb2721`, **dirty**; fake CLI test was **NOT RUN**
- Runbook 0.1 backups found: `/usr/local/bin/vpngw/vpn-functions.sh.pre-0.1.20261031T203711Z` and `/usr/local/bin/vpngw/vpn-tg-bot.sh.pre-0.1.20261031T203711Z`; this confirms backup files exist, not that rollback was tested
- Latest smoke results: bot service active, `tun0` present, IPv4 forwarding `1`; production reconnect and rollback tests not run
- IPv4/IPv6 route and firewall baseline stored at restricted path: `________________`
- Inventory verified by / date: `________________`

## Safe verification commands

Run from an authorized local/admin session. Do not print or store config contents or secrets.

### Automated collector

The repository includes [collect-production-inventory.sh](../tools/collect-production-inventory.sh). It reads an allowlist of non-secret values from `/etc/vpn-gw.conf`, reports selected systemd properties without `ExecStart`/environment, prints process names without arguments, checks whether the configured Telegram token appears in process argv (yes/no and count only), collects routing/firewall/Docker metadata, and creates a `Runbook task 0.1: result fields` section. It reports both Git HEAD and SHA-256 checksums of the active/source bot and functions files; the Git HEAD is not treated as proof of what is deployed. The fake CLI test is run only when the source checkout is clean.

Run only a reviewed copy from a trusted commit on the Pi. The collector sources `/etc/vpn-gw.conf`, so it executes that file as root just like the production scripts. It writes two files, both mode `0600`, and refuses to overwrite either existing output:

- `/root/vpngw-production-inventory-update-<UTC timestamp>.md` — ready-to-review values for the blank fields in this document; process arguments and cron command arguments are omitted.
- `/root/vpngw-production-inventory-update-<UTC timestamp>-private-details.txt` — detailed routing/firewall/Docker snapshots and sanitized crontab; contains sensitive internal topology and stays outside Git.

Do not commit either raw output or paste it into chat. Review locally and transfer only approved, redacted facts from the Markdown report into this inventory. Keep the private details file at mode `0600` in `/root` and remove it securely according to local policy when no longer needed.

```bash
sudo bash tools/collect-production-inventory.sh
```

Optional absolute paths for the report and private details can be supplied as the first and second arguments; both must remain root-only and outside the repository. Never add raw config contents, process argv, tokens, passwords, auth URLs or unredacted unit files to either output or Git.

The collector intentionally does not print `ExecStart`, unit environment, process arguments or secret values. For extra unit settings, inspect the unit locally and record only the selected non-secret properties; redact before sharing.

```bash
hostnamectl
uname -a
cat /etc/os-release
dpkg --print-architecture
sudo stat -c '%U:%G %a %n' /etc/vpn-gw.conf /etc/msmtprc
sudo crontab -l
sudo find /usr/local/bin/vpngw -maxdepth 1 -type f -printf '%M %u:%g %p\n'
sudo systemctl show vpn-tg-bot.service \
  -p FragmentPath -p LoadState -p UnitFileState -p ActiveState -p SubState \
  -p MainPID -p ExecMainStartTimestamp -p User -p Group -p Restart -p NRestarts
sudo systemctl list-timers --all
ps -eo user,pid,ppid,lstart,comm | grep -E '[v]pn-tg-bot|[a]dguardvpn-cli|[a]dguardvpn-starter|[c]url'
```

Do not add `ExecStart`, `Environment`, full command-line arguments or raw unit contents to shared output; these may disclose credentials. Check `/dev/shm/vpn_stats` existence/permissions without printing file contents. For the routing/firewall baseline, follow [the Raspberry Pi Docker setup guide](raspberry-pi-4b-docker-test-server-setup.md).
