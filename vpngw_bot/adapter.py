"""Safe adapter for validating bot commands before invoking shell actions."""

from __future__ import annotations

import ipaddress
import os
import re
import socket
import subprocess
from typing import Any
from urllib.parse import urlsplit

ALLOWED_ACTIONS = {"status", "connect", "speed"}
ALLOWED_LOCATIONS = {"RO", "DE", "FI"}
SPEED_PROFILE_PATTERN = re.compile(r"^[a-zA-Z0-9_-]{1,32}$")
SPEED_PROFILE_NAME_PATTERN = re.compile(r"^[^|\r\n]{1,32}$")
HOSTNAME_PATTERN = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$")


class AdapterError(ValueError):
    """Raised when the command or payload is invalid."""


class SafeAdapter:
    """Validate a fixed command contract and then invoke an approved shell adapter.

    The Python bot must never build arbitrary shell commands from Telegram input.
    The only dynamic values passed to Bash are the action name and a validated
    location code. Everything else is fixed in the script.
    """

    def _config_path(self) -> str:
        return os.environ.get("VPNGW_CONFIG", "/etc/vpngw-bot.conf")

    def _functions_path(self) -> str:
        return os.environ.get("VPNGW_FUNCTIONS", "/usr/local/bin/vpngw/vpn-functions.sh")

    def _speed_config_path(self) -> str:
        return os.environ.get("VPNGW_SPEED_CONFIG", "/etc/vpngw-speed-tests.conf")

    def _validate_action(self, action: str) -> None:
        if action not in ALLOWED_ACTIONS:
            raise AdapterError(f"Unknown action: {action}")

    def _validate_location(self, loc: str | None) -> str:
        norm = str(loc or "").strip().upper()
        if norm not in ALLOWED_LOCATIONS:
            raise AdapterError(f"Invalid VPN location: {loc!r}")
        return norm

    def validate_custom_speed_profile(
        self,
        profile_id: str,
        name: str,
        url: str,
        connect_timeout: str | int,
        max_time: str | int,
    ) -> dict[str, Any]:
        profile_id = str(profile_id).strip()
        name = str(name).strip()
        url = str(url).strip()
        if not SPEED_PROFILE_PATTERN.fullmatch(profile_id):
            raise AdapterError("id должен содержать 1-32 латинских букв, цифр, _ или -.")
        if not SPEED_PROFILE_NAME_PATTERN.fullmatch(name):
            raise AdapterError("Название должно быть длиной 1-32 символа без переносов строк.")
        if len(url) > 2048 or any(character.isspace() for character in url):
            raise AdapterError("URL некорректен или слишком длинный.")
        try:
            parsed = urlsplit(url)
            hostname = parsed.hostname or ""
            port = parsed.port
        except ValueError as exc:
            raise AdapterError("URL некорректен.") from exc
        if (
            parsed.scheme.lower() != "https"
            or not HOSTNAME_PATTERN.fullmatch(hostname)
            or parsed.username is not None
            or parsed.password is not None
            or port not in (None, 443)
            or parsed.fragment
        ):
            raise AdapterError("Разрешён только HTTPS URL публичного домена на порту 443, без credentials и fragment.")
        try:
            connect_seconds = int(connect_timeout)
            max_seconds = int(max_time)
        except (TypeError, ValueError) as exc:
            raise AdapterError("Таймауты должны быть целыми числами.") from exc
        if not 1 <= connect_seconds <= 60 or not 1 <= max_seconds <= 120:
            raise AdapterError("connect-timeout должен быть 1-60, max-time 1-120 секунд.")
        return {
            "id": profile_id,
            "name": name,
            "url": url,
            "connect_timeout": connect_seconds,
            "max_time": max_seconds,
        }

    def _resolve_public_endpoint(self, url: str) -> tuple[str, str]:
        hostname = urlsplit(url).hostname or ""
        try:
            answers = socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)
        except OSError as exc:
            raise AdapterError(f"Не удалось разрешить DNS для {hostname}.") from exc
        addresses = list(dict.fromkeys(answer[4][0] for answer in answers))
        if not addresses:
            raise AdapterError(f"DNS не вернул адреса для {hostname}.")
        try:
            parsed_addresses = [ipaddress.ip_address(address) for address in addresses]
        except ValueError as exc:
            raise AdapterError("DNS вернул некорректный IP-адрес.") from exc
        if any(not address.is_global for address in parsed_addresses):
            raise AdapterError("Сервис должен разрешаться только в публичные IP-адреса.")
        ipv4 = next((str(address) for address in parsed_addresses if address.version == 4), None)
        if ipv4 is None:
            raise AdapterError("Сервис должен иметь публичный IPv4-адрес.")
        return hostname, ipv4

    def verify_custom_speed_endpoint(self, url: str) -> None:
        self._resolve_public_endpoint(url)

    def _run_bash(self, action: str, payload: dict[str, Any]) -> str:
        config_path = self._config_path()
        functions_path = self._functions_path()

        if action == "status":
            script = f'''
set -e
if [ -f "{config_path}" ]; then . "{config_path}"; fi
if [ -f "{functions_path}" ]; then . "{functions_path}"; fi
if [ -n "${{VPN_IF:-}}" ] && command -v check_geo >/dev/null 2>&1; then
    loc_raw=$(check_geo "${{VPN_IF}}" detail 2>/dev/null || echo DISCONNECTED)
    if [[ "$loc_raw" == *"|"* ]]; then
        loc_country="${{loc_raw%%|*}}"
        loc_city="${{loc_raw#*|}}"
        loc="$loc_city ($loc_country)"
    else
        loc="$loc_raw"
    fi
else
    loc=DISCONNECTED
fi
if [ -n "${{VPN_IF:-}}" ] && command -v get_vpn_download_speed >/dev/null 2>&1; then
    if speed=$(get_vpn_download_speed "${{VPN_IF}}" 2>/dev/null); then
        :
    else
        speed=unavailable
    fi
else
    speed=unavailable
fi
printf "%s|%s\n" "$loc" "$speed"
'''
            result = subprocess.run(["/bin/bash", "-lc", script], capture_output=True, text=True, check=False)
            if result.returncode != 0:
                raise AdapterError(f"status command failed: {result.stderr.strip() or result.stdout.strip() or 'unknown error'}")
            return result.stdout.strip()

        if action == "speed_options":
            script = f'''
set -e
if [ -f "{functions_path}" ]; then . "{functions_path}"; fi
if ! command -v list_vpn_speed_tests >/dev/null 2>&1; then
    echo "missing list_vpn_speed_tests" >&2
    exit 127
fi
list_vpn_speed_tests
'''
            result = subprocess.run(
                ["/bin/bash", "-lc", script], capture_output=True, text=True, check=False,
                env={**os.environ, "VPNGW_SPEED_CONFIG": self._speed_config_path()},
            )
            if result.returncode != 0:
                raise AdapterError(f"speed options failed: {result.stderr.strip() or 'unknown error'}")
            return result.stdout.strip()

        if action == "speed":
            profile = str(payload.get("profile") or "").strip()
            custom_url = payload.get("url")
            custom = None
            if custom_url:
                custom = self.validate_custom_speed_profile(
                    profile,
                    str(payload.get("name") or profile),
                    str(custom_url),
                    payload.get("connect_timeout", 6),
                    payload.get("max_time", 20),
                )
            elif not SPEED_PROFILE_PATTERN.fullmatch(profile):
                raise AdapterError("Invalid speed test profile")
            script = f'''
set -e
if [ -f "{config_path}" ]; then . "{config_path}"; fi
if [ -f "{functions_path}" ]; then . "{functions_path}"; fi
if [ -z "${{VPN_IF:-}}" ] || ! command -v get_vpn_download_speed >/dev/null 2>&1; then
    echo "speed test is unavailable" >&2
    exit 1
fi
get_vpn_download_speed "${{VPN_IF}}" "$1" "${{2:-}}" "${{3:-}}" "${{4:-}}" "${{5:-}}" "${{6:-}}"
'''
            args = ["/bin/bash", "-lc", script, "vpngw-speed", profile]
            if custom:
                resolve_host, resolve_ip = self._resolve_public_endpoint(custom["url"])
                args.extend(
                    [
                        custom["url"],
                        str(custom["connect_timeout"]),
                        str(custom["max_time"]),
                        resolve_host,
                        resolve_ip,
                    ]
                )
            result = subprocess.run(
                args,
                capture_output=True, text=True, check=False,
                env={**os.environ, "VPNGW_SPEED_CONFIG": self._speed_config_path()},
            )
            if result.returncode != 0:
                raise AdapterError(f"speed test failed: {result.stderr.strip() or 'profile unavailable'}")
            return result.stdout.strip()

        if action == "connect":
            loc = self._validate_location(payload.get("loc"))
            script = f'''
set -e
if [ -f "{config_path}" ]; then . "{config_path}"; fi
if [ -f "{functions_path}" ]; then . "{functions_path}"; fi
if command -v run_adguard_connect >/dev/null 2>&1; then
    if [ -z "${{VPNGW_SWITCH_BIN:-}}" ] || [ ! -x "${{VPNGW_SWITCH_BIN}}" ]; then
        echo "missing or non-executable privileged switch helper" >&2
        exit 127
    fi
    run_adguard_connect "{loc}"
    printf "switch:{loc}\n"
else
    echo "missing run_adguard_connect" >&2
    exit 127
fi
'''
            result = subprocess.run(["/bin/bash", "-lc", script], capture_output=True, text=True, check=False)
            if result.returncode != 0:
                raise AdapterError(f"connect command failed: {result.stderr.strip() or result.stdout.strip() or 'unknown error'}")
            return result.stdout.strip()

        raise AdapterError(f"Unsupported action: {action}")

    def execute(self, action: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        payload = payload or {}
        self._validate_action(action)

        if action == "status":
            raw = self._run_bash(action, payload)
            location, speed = (raw.split("|", 1) + ["0"])[:2]
            return {
                "ok": True,
                "action": "status",
                "location": location,
                "speed_mbps": speed,
                "result": f"location={location}; speed={speed} Mbps" if speed != "unavailable" else f"location={location}; speed=unavailable",
            }

        if action == "connect":
            loc = self._validate_location(payload.get("loc"))
            self._run_bash(action, {"loc": loc})
            return {
                "ok": True,
                "action": "connect",
                "result": f"switch:{loc}",
            }

        if action == "speed":
            profile = str(payload.get("profile") or "").strip()
            custom_url = payload.get("url")
            if custom_url:
                custom = self.validate_custom_speed_profile(
                    profile,
                    str(payload.get("name") or profile),
                    str(custom_url),
                    payload.get("connect_timeout", 6),
                    payload.get("max_time", 20),
                )
                name = custom["name"]
            else:
                options = self.speed_options()
                names = {item["id"]: item["name"] for item in options}
                if profile not in names or not SPEED_PROFILE_PATTERN.fullmatch(profile):
                    raise AdapterError("Invalid speed test profile")
                name = names[profile]
            raw_speed = self._run_bash("speed", payload)
            try:
                speed = f"{float(raw_speed):.2f}"
            except ValueError:
                speed = "unavailable"
            return {
                "ok": True,
                "action": "speed",
                "profile": profile,
                "profile_name": name,
                "speed_mbps": speed,
                "result": f"{name}: {speed} Mbps" if speed != "unavailable" else f"{name}: unavailable",
            }

        raise AdapterError(f"Unsupported action: {action}")

    def speed_options(self) -> list[dict[str, str]]:
        raw = self._run_bash("speed_options", {})
        options = []
        for line in raw.splitlines():
            profile, separator, name = line.partition("|")
            if separator and SPEED_PROFILE_PATTERN.fullmatch(profile) and name.strip():
                options.append({"id": profile, "name": name.strip()})
        return options
