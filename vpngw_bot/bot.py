"""Bot policy layer used by the Telegram handlers."""

from __future__ import annotations


class BotPolicy:
    """Access policy for Telegram commands and callbacks."""

    def __init__(self, allowed_chat_ids: set[int] | None = None):
        self.allowed_chat_ids = set(allowed_chat_ids or [])

    def is_allowed_chat(self, chat_id: int) -> bool:
        return chat_id in self.allowed_chat_ids

    def validate_chat(self, chat_id: int) -> bool:
        return self.is_allowed_chat(chat_id)
