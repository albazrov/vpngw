"""Configuration loaded from environment without exposing secrets in argv."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class BotConfig:
    token: str
    allowed_chat_ids: tuple[int, ...]
    admin_chat_ids: tuple[int, ...]
    config_path: str = "/etc/vpn-gw.conf"
    functions_path: str = "/usr/local/bin/vpngw/vpn-functions.sh"
    state_db: str = "/var/lib/vpngw/bot_state.db"
    queue_db: str = "/var/lib/vpngw/bot_queue.db"

    @classmethod
    def from_env(cls) -> "BotConfig":
        token = os.environ.get("TG_TOKEN", "").strip()
        if not token:
            raise ValueError("TG_TOKEN is required and must not be logged or embedded in argv.")

        raw_ids = os.environ.get("TG_ALLOWED_CHAT_IDS", "").strip()
        def parse_ids(raw_value: str, variable: str) -> tuple[int, ...]:
            parsed: list[int] = []
            for part in raw_value.split(","):
                value = part.strip()
                if not value:
                    continue
                try:
                    parsed.append(int(value))
                except ValueError as exc:
                    raise ValueError(f"Invalid {variable} value: {value!r}") from exc
            return tuple(parsed)

        chat_ids = parse_ids(raw_ids, "TG_ALLOWED_CHAT_IDS")
        admin_ids = parse_ids(os.environ.get("TG_ADMIN_CHAT_IDS", raw_ids).strip(), "TG_ADMIN_CHAT_IDS")
        if not set(admin_ids).issubset(chat_ids):
            raise ValueError("TG_ADMIN_CHAT_IDS must be a subset of TG_ALLOWED_CHAT_IDS")

        return cls(
            token=token,
            allowed_chat_ids=chat_ids,
            admin_chat_ids=admin_ids,
            config_path=os.environ.get("VPNGW_CONFIG", "/etc/vpngw-bot.conf"),
            functions_path=os.environ.get("VPNGW_FUNCTIONS", "/usr/local/bin/vpngw/vpn-functions.sh"),
            state_db=os.environ.get("VPNGW_STATE_DB", "/var/lib/vpngw/bot_state.db"),
            queue_db=os.environ.get("VPNGW_QUEUE_DB", "/var/lib/vpngw/bot_queue.db"),
        )
