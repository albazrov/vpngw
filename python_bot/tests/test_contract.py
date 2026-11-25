import asyncio
import os
import socket
from types import SimpleNamespace

import pytest

from vpngw_bot.adapter import SafeAdapter, AdapterError
from vpngw_bot.bot import BotPolicy
from vpngw_bot.config import BotConfig
from vpngw_bot.service import VpnBotService
from vpngw_bot.state import BotState


def _make_fake_functions(tmp_path):
    config = tmp_path / "vpn-gw.conf"
    main_dir = tmp_path / "main"
    main_dir.mkdir()
    switch_script = main_dir / "vpngw-root-switch"
    switch_script.write_text("#!/bin/bash\nexit 0\n")
    switch_script.chmod(0o755)
    config.write_text(f'VPN_IF="tun0"\nVPNGW_SWITCH_BIN="{switch_script}"\n')

    speed_config = tmp_path / "vpn-speed-tests.conf"
    speed_config.write_text(
      'VPN_SPEED_TEST_IDS=(cloudflare backup)\n'
      'VPN_SPEED_TEST_NAMES[cloudflare]="Cloudflare"\n'
      'VPN_SPEED_TEST_URLS[cloudflare]="https://speed.example/cloudflare"\n'
      'VPN_SPEED_TEST_CONNECT_TIMEOUT[cloudflare]=6\n'
      'VPN_SPEED_TEST_MAX_TIME[cloudflare]=20\n'
      'VPN_SPEED_TEST_NAMES[backup]="Backup provider"\n'
      'VPN_SPEED_TEST_URLS[backup]="https://speed.example/backup"\n'
      'VPN_SPEED_TEST_CONNECT_TIMEOUT[backup]=8\n'
      'VPN_SPEED_TEST_MAX_TIME[backup]=30\n'
    )

    lib = tmp_path / "vpn-functions.sh"
    lib.write_text(
        """
check_geo() {
    if [ "${2:-}" = "detail" ]; then
        echo "DE|Frankfurt am Main"
    else
        echo "DE"
    fi
}

list_vpn_speed_tests() {
  local -a VPN_SPEED_TEST_IDS=()
  local -A VPN_SPEED_TEST_NAMES=()
  local -A VPN_SPEED_TEST_URLS=()
  local -A VPN_SPEED_TEST_CONNECT_TIMEOUT=()
  local -A VPN_SPEED_TEST_MAX_TIME=()
  source "$VPNGW_SPEED_CONFIG"
  local profile
  for profile in "${VPN_SPEED_TEST_IDS[@]}"; do
    printf '%s|%s\\n' "$profile" "${VPN_SPEED_TEST_NAMES[$profile]}"
  done
}

get_vpn_download_speed() {
  local profile="${2:-cloudflare}"
  if [ -z "${3:-}" ]; then
    case "$profile" in cloudflare|backup) ;; *) return 1 ;; esac
  fi
  if [ "${VPN_SPEED_FAIL:-0}" = "1" ]; then
    echo "0"
    return 1
  fi
  echo "12.34"
}

run_adguard_connect() {
  echo "connected:$1"
}

""".strip()
    )

    os.environ["VPNGW_CONFIG"] = str(config)
    os.environ["VPNGW_FUNCTIONS"] = str(lib)
    os.environ["VPNGW_SPEED_CONFIG"] = str(speed_config)


def test_status_contract_accepts_allowed_values(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    adapter = SafeAdapter()
    result = adapter.execute("status", {})
    assert result["ok"] is True
    assert result["action"] == "status"
    assert result["speed_mbps"] == "12.34"
    assert result["location"] == "Frankfurt am Main (DE)"
    assert result["result"] == "location=Frankfurt am Main (DE); speed=12.34 Mbps"


def test_status_contract_does_not_duplicate_speed_fallback(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    monkeypatch.setenv("VPN_SPEED_FAIL", "1")
    result = SafeAdapter().execute("status", {})
    assert result["speed_mbps"] == "unavailable"
    assert result["location"] == "Frankfurt am Main (DE)"
    assert result["result"] == "location=Frankfurt am Main (DE); speed=unavailable"


def test_speed_profiles_are_configurable_and_selectable(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    adapter = SafeAdapter()

    assert adapter.speed_options() == [
        {"id": "cloudflare", "name": "Cloudflare"},
        {"id": "backup", "name": "Backup provider"},
    ]
    result = adapter.execute("speed", {"profile": "backup"})
    assert result["profile_name"] == "Backup provider"
    assert result["speed_mbps"] == "12.34"
    assert result["result"] == "Backup provider: 12.34 Mbps"


def test_speed_rejects_profile_not_in_config(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    with pytest.raises(AdapterError, match="Invalid speed test profile"):
        SafeAdapter().execute("speed", {"profile": "untrusted"})


def test_custom_speed_profile_requires_https_and_valid_timeouts():
    adapter = SafeAdapter()
    with pytest.raises(AdapterError, match="HTTPS"):
        adapter.validate_custom_speed_profile("fast", "Fast", "http://speed.example/file", 5, 20)
    with pytest.raises(AdapterError, match="connect-timeout"):
        adapter.validate_custom_speed_profile("fast", "Fast", "https://speed.example/file", 5, 121)


def test_custom_speed_profile_rejects_private_dns(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda *args, **kwargs: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.168.1.10", 443))],
    )
    profile = {
        "profile": "private",
        "name": "Private test",
        "url": "https://speed.example/file",
        "connect_timeout": 5,
        "max_time": 20,
    }
    with pytest.raises(AdapterError, match="публичные IP"):
        SafeAdapter().execute("speed", profile)


def test_custom_speed_profile_rejects_ipv6_only_endpoint(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda *args, **kwargs: [
            (socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("2001:4860:4860::8888", 443, 0, 0))
        ],
    )
    profile = {
        "profile": "ipv6",
        "name": "IPv6 Test",
        "url": "https://speed.example/file",
        "connect_timeout": 5,
        "max_time": 20,
    }
    with pytest.raises(AdapterError, match="публичный IPv4"):
        SafeAdapter().execute("speed", profile)


def test_custom_speed_profile_rejects_ipv6_only_endpoint_on_add(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda *args, **kwargs: [
            (socket.AF_INET6, socket.SOCK_STREAM, 6, "", ("2001:4860:4860::8888", 443, 0, 0))
        ],
    )

    with pytest.raises(AdapterError, match="публичный IPv4"):
        SafeAdapter().verify_custom_speed_endpoint("https://speed.example/file")


def test_custom_speed_profile_runs_through_public_pinned_endpoint(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda *args, **kwargs: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443))],
    )
    profile = {
        "profile": "provider",
        "name": "Provider Test",
        "url": "https://speed.example/file",
        "connect_timeout": 5,
        "max_time": 20,
    }

    result = SafeAdapter().execute("speed", profile)

    assert result["profile_name"] == "Provider Test"
    assert result["speed_mbps"] == "12.34"


def test_speed_profiles_persist_in_sqlite(tmp_path):
    state = BotState(str(tmp_path / "state.db"))
    state.add_speed_profile("fast", "Fast", "https://speed.example/file", 5, 20, 123)

    assert state.get_speed_profile("fast") == {
        "id": "fast",
        "name": "Fast",
        "url": "https://speed.example/file",
        "connect_timeout": 5,
        "max_time": 20,
    }
    assert state.list_speed_profiles()[0]["id"] == "fast"


def test_bot_config_defaults_allowed_chats_to_admins(monkeypatch):
    monkeypatch.setenv("TG_TOKEN", "test-token")
    monkeypatch.setenv("TG_ALLOWED_CHAT_IDS", "123,456")
    monkeypatch.delenv("TG_ADMIN_CHAT_IDS", raising=False)

    config = BotConfig.from_env()

    assert config.admin_chat_ids == (123, 456)


def test_speed_add_rejects_non_admin_chat():
    class FakeMessage:
        def __init__(self):
            self.reply = None

        async def reply_text(self, text):
            self.reply = text

    service = object.__new__(VpnBotService)
    service.policy = BotPolicy({42})
    service.admin_chat_ids = {123}
    message = FakeMessage()
    update = SimpleNamespace(effective_chat=SimpleNamespace(id=42), message=message)

    asyncio.run(service._speed_add(update, SimpleNamespace(args=[])))

    assert "только администратор" in message.reply


def test_admin_can_add_speed_profile():
    class FakeMessage:
        def __init__(self):
            self.reply = None

        async def reply_text(self, text):
            self.reply = text

    class FakeAdapter:
        def validate_custom_speed_profile(self, profile_id, name, url, connect_timeout, max_time):
            return {
                "id": profile_id,
                "name": name,
                "url": url,
                "connect_timeout": int(connect_timeout),
                "max_time": int(max_time),
            }

        def speed_options(self):
            return []

        def verify_custom_speed_endpoint(self, url):
            return None

    class FakeState:
        def __init__(self):
            self.added = None

        def list_speed_profiles(self):
            return []

        def add_speed_profile(self, *args):
            self.added = args

    service = object.__new__(VpnBotService)
    service.policy = BotPolicy({123})
    service.admin_chat_ids = {123}
    service.adapter = FakeAdapter()
    service.state = FakeState()
    message = FakeMessage()
    update = SimpleNamespace(
        effective_chat=SimpleNamespace(id=123),
        effective_user=SimpleNamespace(id=456),
        message=message,
    )
    context = SimpleNamespace(args=["fast", "Fast", "https://speed.example/file", "8", "30"])

    asyncio.run(service._speed_add(update, context))

    assert "Добавлен сервис" in message.reply
    assert service.state.added == ("fast", "Fast", "https://speed.example/file", 8, 30, 456)


def test_service_reports_progress_then_edits_result():
  class FakeAdapter:
    def execute(self, action, payload):
      return {"result": f"{action}:{payload['profile']}"}

  class FakeMessage:
    def __init__(self):
      self.edited_text = None

    async def edit_text(self, text):
      self.edited_text = text

  service = object.__new__(VpnBotService)
  service.adapter = FakeAdapter()
  message = FakeMessage()
  sent_text = []

  async def reply_text(text):
    sent_text.append(text)
    return message

  asyncio.run(
    service._run_with_progress(
      reply_text,
      "Measuring speed",
      "speed",
      {"profile": "cloudflare"},
    )
  )

  assert sent_text == ["Measuring speed"]
  assert message.edited_text == "speed:cloudflare"


def test_connect_contract_rejects_unknown_location():
    adapter = SafeAdapter()
    with pytest.raises(AdapterError):
        adapter.execute("connect", {"loc": "XX"})


def test_connect_contract_runs_real_shell_wrapper(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    adapter = SafeAdapter()
    result = adapter.execute("connect", {"loc": "RO"})
    assert result["ok"] is True
    assert result["result"] == "switch:RO"


def test_connect_contract_requires_privileged_switch_helper(tmp_path, monkeypatch):
    _make_fake_functions(tmp_path)
    config = tmp_path / "vpn-gw.conf"
    config.write_text('VPN_IF="tun0"\nVPNGW_SWITCH_BIN="/missing/helper"\n')
    adapter = SafeAdapter()
    with pytest.raises(AdapterError, match="privileged switch helper"):
        adapter.execute("connect", {"loc": "RO"})


def test_bot_policy_allows_only_expected_chat_id():
    policy = BotPolicy(allowed_chat_ids={123456789})
    assert policy.is_allowed_chat(123456789) is True
    assert policy.is_allowed_chat(42) is False
