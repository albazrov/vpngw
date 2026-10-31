#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/vpn-gw.conf"
BOT_UNIT="vpn-tg-bot.service"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
REPORT_OUTPUT="${1:-/root/vpngw-production-inventory-update-$STAMP.md}"
DETAILS_OUTPUT="${2:-${REPORT_OUTPUT%.md}-private-details.txt}"

if (( EUID != 0 )); then
    printf 'Run with sudo so the inventory can read host metadata safely.\n' >&2
    exit 1
fi

if [[ ! -r "$CONFIG_FILE" ]]; then
    printf 'Cannot read %s\n' "$CONFIG_FILE" >&2
    exit 1
fi

if [[ -e "$REPORT_OUTPUT" || -e "$DETAILS_OUTPUT" ]]; then
    printf 'Refusing to overwrite an existing output file.\n' >&2
    exit 1
fi

umask 077
mkdir -p -- "$(dirname -- "$REPORT_OUTPUT")" "$(dirname -- "$DETAILS_OUTPUT")"
TEMP_DETAILS=$(mktemp "$(dirname -- "$DETAILS_OUTPUT")/.inventory-details.XXXXXX")
TEMP_REPORT=$(mktemp "$(dirname -- "$REPORT_OUTPUT")/.inventory-report.XXXXXX")
trap 'rm -f -- "$TEMP_DETAILS" "$TEMP_REPORT"' EXIT
exec > "$TEMP_DETAILS"

printf 'Production inventory collected at: %s\n' "$(date --iso-8601=seconds)"
printf 'Host: %s\n' "$(hostname)"
printf 'Output file mode: 0600 (secrets and network details are not intended for public sharing)\n'

section() {
    printf '\n## %s\n' "$1"
}

show_command() {
    local label="$1"
    shift
    printf '\n### %s\n' "$label"
    if command -v "$1" >/dev/null 2>&1; then
        "$@" 2>&1 || printf '[command returned non-zero: %s]\n' "$*"
    else
        printf '[not installed: %s]\n' "$1"
    fi
}

section "Host and operating system"
uname -a
cat /etc/os-release
dpkg --print-architecture
hostnamectl 2>&1 || true

section "Production configuration metadata (contents not printed)"
stat -c '%U:%G %a %n' "$CONFIG_FILE" /etc/msmtprc 2>&1 || true

# The config is sourced by production scripts. This collector also sources it,
# so run only a reviewed copy and emit only this explicit non-secret allowlist.
set +u
source "$CONFIG_FILE"
set -u
CONFIGURED_TG_TOKEN="${TG_TOKEN:-}"

safe_config_vars=(
    SYSTEM_NAME MAIN_SH_DIR ADG_BIN LOG_RAM LOG_DISK STATS_DIR IPSET_CACHE
    LOC_CACHE_DISK CACHE_FILE MSMTP_CONF MSMTP_ACC NET_IF VPN_IF GATEWAY
    LOCAL_NET NET_IF_IP HOME_NET TEMP_LIMIT IPSET_NAME IPSET_TIMEOUT MARK
    TABLE SOURCE_URL AUTH_TMP AUTH_FLAG LAST_URL_FILE LAST_SEND_TIME
    AUTH_POLL_INTERVAL AUTH_POLL_COUNT URL_TIME_VALID CHECK_TARGETS
    CHECK_PRIORITY ENABLE_SPEED_TEST MIN_SPEED_KBPS PRIORITY_LOCS EXCLUDE_LOCS
    LOC_CACHE_TTL REPORT_TO_TG REPORT_TG_INTERVAL REPORT_TO_EMAIL
    REPORT_EMAIL_INTERVAL TG_LAST_SEND_FILE EM_LAST_SEND_FILE QUEUE_DIR OFFSET_FILE
)

for name in "${safe_config_vars[@]}"; do
    if declare -p "$name" >/dev/null 2>&1; then
        declare -p "$name"
    else
        printf '%s=<unset>\n' "$name"
    fi
done

section "Secret exposure check (values suppressed)"
if [[ -n "${TG_TOKEN:-}" ]]; then
    token_arg_count=0
    for cmdline_file in /proc/[0-9]*/cmdline; do
        [[ -r "$cmdline_file" ]] || continue
        process_args=$(tr '\0' ' ' < "$cmdline_file" 2>/dev/null || true)
        if [[ "$process_args" == *"$TG_TOKEN"* ]]; then
            token_arg_count=$((token_arg_count + 1))
        fi
    done
    if (( token_arg_count > 0 )); then
        TOKEN_ARG_STATUS="YES ($token_arg_count process(es))"
        printf 'Configured Telegram token appears in process argv: YES (%d process(es)); values suppressed\n' "$token_arg_count"
    else
        TOKEN_ARG_STATUS="NO (at collection time)"
        printf 'Configured Telegram token appears in process argv: NO (at collection time)\n'
    fi
    unset process_args
else
    TOKEN_ARG_STATUS="NOT CHECKED (TG_TOKEN unset)"
    printf 'TG_TOKEN is unset; process-argument check was not possible\n'
fi
unset TG_TOKEN

redact_sensitive_text() {
    local text="$1"
    if [[ -n "$CONFIGURED_TG_TOKEN" ]]; then
        text=${text//"$CONFIGURED_TG_TOKEN"/[REDACTED_TELEGRAM_TOKEN]}
    fi
    printf '%s\n' "$text" | sed -E \
        -e 's/[0-9]{8,}:[A-Za-z0-9_-]{20,}/[REDACTED_TELEGRAM_TOKEN]/g' \
        -e 's/(TOKEN|PASSWORD|SECRET|API_KEY)=([^[:space:]]+)/\1=[REDACTED]/Ig'
}

section "Bot systemd metadata (no ExecStart or Environment values)"
systemctl show "$BOT_UNIT" --no-pager \
    -p Id -p Description -p FragmentPath -p LoadState -p UnitFileState \
    -p ActiveState -p SubState -p Type -p User -p Group -p Restart \
    -p RestartUSec -p After -p Wants -p Requires -p MainPID \
    -p ExecMainStartTimestamp -p NRestarts -p StartLimitIntervalUSec \
    -p StartLimitBurst -p WorkingDirectory -p RuntimeDirectory \
    -p NoNewPrivileges -p PrivateTmp -p ProtectSystem -p ProtectHome \
    -p ReadWritePaths -p ReadOnlyPaths -p CapabilityBoundingSet \
    -p AmbientCapabilities 2>&1 || true

section "Root crontab (token-shaped values redacted)"
CRONTAB_RAW=$(crontab -l 2>&1 || true)
CRONTAB_SAFE=$(redact_sensitive_text "$CRONTAB_RAW")
printf '%s\n' "$CRONTAB_SAFE"

section "Processes (command arguments deliberately omitted)"
ps -eo user,pid,ppid,lstart,comm --sort=pid

section "Runtime directories and production paths"
for path in \
    /usr/local/bin/vpngw \
    /dev/shm/vpn_stats \
    /dev/shm/tg_queue \
    /mnt/external_data \
    /opt/adguardvpn_cli/adguardvpn-cli
 do
    if [[ -e "$path" ]]; then
        stat -c '%F %U:%G %a %n' "$path"
    else
        printf 'MISSING %s\n' "$path"
    fi
done

section "Mount and disk state"
findmnt -T /mnt/external_data 2>&1 || true
df -h / /dev/shm /mnt/external_data 2>&1 || true

section "Network and routing state"
ip -brief address 2>&1 || true
ip -4 route show table all 2>&1 || true
ip -6 route show table all 2>&1 || true
ip rule show 2>&1 || true
ip -6 rule show 2>&1 || true
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding 2>&1 || true

section "Firewall state"
show_command "iptables rules" iptables-save
show_command "IPv6 iptables rules" ip6tables-save
show_command "nftables ruleset" nft list ruleset

section "Docker state"
if command -v docker >/dev/null 2>&1; then
    docker version 2>&1 || true
    docker compose version 2>&1 || true
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>&1 || true
else
    printf 'docker is not installed\n'
fi

section "Collection complete"
printf 'Review and redact internal topology before sharing this file. Never add raw config contents, process argv, tokens, passwords, auth URLs or unredacted unit files to the repository.\n'

chmod 0600 "$TEMP_DETAILS"
mv -- "$TEMP_DETAILS" "$DETAILS_OUTPUT"

HOST_NAME=$(hostname 2>/dev/null || printf 'unknown')
OS_PRETTY_NAME=$(awk -F= '$1 == "PRETTY_NAME" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true)
OS_VERSION_CODENAME=$(awk -F= '$1 == "VERSION_CODENAME" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true)
ARCHITECTURE=$(dpkg --print-architecture 2>/dev/null || printf 'unknown')
KERNEL_INFO=$(uname -srmo 2>/dev/null || printf 'unknown')
CONFIG_METADATA=$(stat -c '%U:%G %a %n' "$CONFIG_FILE" /etc/msmtprc 2>&1 || true)
BOT_SCRIPT_METADATA=$(stat -c '%U:%G %a %n' /usr/local/bin/vpngw/vpn-tg-bot.sh 2>&1 || true)
FUNCTIONS_METADATA=$(stat -c '%U:%G %a %n' /usr/local/bin/vpngw/vpn-functions.sh 2>&1 || true)
RUNTIME_DIR_METADATA=$(stat -c '%F %U:%G %a %n' /dev/shm/vpn_stats 2>&1 || printf 'MISSING /dev/shm/vpn_stats\n')
EXTERNAL_MOUNT=$(findmnt -n -o SOURCE,FSTYPE,TARGET -T /mnt/external_data 2>&1 || printf 'NOT MOUNTED /mnt/external_data\n')
EXTERNAL_DISK=$(df -hP /mnt/external_data 2>&1 | tail -n 1 || true)
PRODUCTION_SHA=$(git -C /usr/local/bin/vpngw rev-parse --short HEAD 2>/dev/null || printf 'not a git checkout / unknown')
BOT_UNIT_FACTS=$(systemctl show "$BOT_UNIT" --no-pager \
    -p Id -p Description -p FragmentPath -p LoadState -p UnitFileState \
    -p ActiveState -p SubState -p Type -p User -p Group -p Restart \
    -p RestartUSec -p After -p Wants -p Requires -p ExecMainStartTimestamp \
    -p NRestarts -p StartLimitIntervalUSec -p StartLimitBurst \
    -p WorkingDirectory -p RuntimeDirectory -p NoNewPrivileges -p PrivateTmp \
    -p ProtectSystem -p ProtectHome -p ReadWritePaths -p ReadOnlyPaths \
    -p CapabilityBoundingSet -p AmbientCapabilities 2>&1 || true)
DOCKER_VERSION="not installed"
DOCKER_COMPOSE_VERSION="not installed"
DOCKER_CONTAINERS="not installed"
if command -v docker >/dev/null 2>&1; then
    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf 'installed; daemon unavailable')
    DOCKER_COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || printf 'plugin unavailable')
    DOCKER_CONTAINERS=$(docker ps --format '{{.Names}} | {{.Image}} | {{.Status}}' 2>/dev/null || printf 'daemon unavailable')
fi
ROOT_CRONTAB_SHA=$(printf '%s\n' "$CRONTAB_SAFE" | sha256sum | awk '{print $1}')
ROOT_CRONTAB_LINES=$(printf '%s\n' "$CRONTAB_SAFE" | awk 'NF {count++} END {print count+0}')
ROOT_CRONTAB_SUMMARY=$(while IFS= read -r cron_line; do
    [[ -z "$cron_line" || "$cron_line" =~ ^[[:space:]]*# ]] && continue
    read -r -a cron_fields <<< "$cron_line"
    ((${#cron_fields[@]} >= 2)) || continue
    if [[ "${cron_fields[0]}" == @* ]]; then
        cron_schedule="${cron_fields[0]}"
    elif ((${#cron_fields[@]} >= 6)); then
        cron_schedule="${cron_fields[0]} ${cron_fields[1]} ${cron_fields[2]} ${cron_fields[3]} ${cron_fields[4]}"
    else
        continue
    fi
    if [[ "$cron_line" =~ (/usr/local/bin/vpngw/[[:alnum:]_.-]+) ]]; then
        cron_command="${BASH_REMATCH[1]##*/}"
    else
        cron_command="[non-vpngw entry omitted]"
    fi
    printf -- '- `%s` — `%s` (arguments omitted)\n' "$cron_schedule" "$cron_command"
done <<< "$CRONTAB_SAFE")

{
    printf '# Production inventory update\n\n'
    printf 'Collected: `%s`\n\n' "$(date --iso-8601=seconds)"
    printf 'Host: `%s`\n\n' "$HOST_NAME"
    printf '> Review locally. This report is mode `0600`, may contain internal topology and must not be committed or shared raw. The private snapshot is `%s`.\n\n' "$DETAILS_OUTPUT"

    printf '## Host and deployment\n\n'
    printf -- '- Hostname: `%s`\n' "$HOST_NAME"
    printf -- '- OS: `%s`\n' "${OS_PRETTY_NAME:-unknown}"
    printf -- '- OS codename: `%s`\n' "${OS_VERSION_CODENAME:-unknown}"
    printf -- '- Kernel: `%s`\n' "$KERNEL_INFO"
    printf -- '- Architecture: `%s`\n' "$ARCHITECTURE"
    printf -- '- Production commit SHA: `%s`\n' "$PRODUCTION_SHA"
    printf -- '- Docker Engine: `%s`\n' "$DOCKER_VERSION"
    printf -- '- Docker Compose: `%s`\n' "$DOCKER_COMPOSE_VERSION"
    printf -- '- Running containers (name | image | state):\n\n```text\n%s\n```\n\n' "$DOCKER_CONTAINERS"

    printf '## File metadata (no file contents)\n\n```text\n%s\n%s\n%s\n```\n\n' \
        "$CONFIG_METADATA" "$BOT_SCRIPT_METADATA" "$FUNCTIONS_METADATA"
    printf -- '- `/dev/shm/vpn_stats`: `%s`\n' "$RUNTIME_DIR_METADATA"
    printf -- '- External mount: `%s`\n' "$EXTERNAL_MOUNT"
    printf -- '- External disk: `%s`\n\n' "$EXTERNAL_DISK"

    printf '## Bot systemd properties\n\n```text\n%s\n```\n\n' "$BOT_UNIT_FACTS"
    printf -- '- Configured Telegram token found in process argv: **%s**\n\n' "$TOKEN_ARG_STATUS"

    printf '## Allowlisted configuration values\n\n'
    printf 'Values below exclude credentials. Review internal network/path data before copying into tracked docs.\n\n```bash\n'
    for name in "${safe_config_vars[@]}"; do
        if declare -p "$name" >/dev/null 2>&1; then
            declare -p "$name"
        else
            printf '%s=<unset>\n' "$name"
        fi
    done
    printf '```\n\n'

    printf '## Root crontab verification\n\n'
    printf -- '- Non-empty entries: `%s`\n' "$ROOT_CRONTAB_LINES"
    printf -- '- SHA-256 of sanitized crontab: `%s`\n\n' "$ROOT_CRONTAB_SHA"
    printf 'Sanitized schedule summary (command arguments omitted):\n\n%s\n' "$ROOT_CRONTAB_SUMMARY"
    printf '\nFull redacted crontab is only in the private snapshot; review it locally before use.\n\n'

    printf '## Private route/firewall snapshot\n\n'
    printf -- '- Full IPv4/IPv6 routes, rules, forwarding sysctls and firewall state are in `%s`; do not commit that file.\n' "$DETAILS_OUTPUT"
    printf -- '- Snapshot file mode: `0600`\n'
    printf -- '- Inventory update report mode: `0600`\n'
} > "$TEMP_REPORT"

chmod 0600 "$TEMP_REPORT"
mv -- "$TEMP_REPORT" "$REPORT_OUTPUT"
trap - EXIT
unset CONFIGURED_TG_TOKEN CRONTAB_RAW
printf 'Inventory update report: %s (mode 0600)\nPrivate details snapshot: %s (mode 0600)\n' \
    "$REPORT_OUTPUT" "$DETAILS_OUTPUT" >&2
