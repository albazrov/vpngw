"""Minimal Python Telegram bot for the vpngw project."""

__all__ = ["SafeAdapter", "AdapterError", "BotPolicy", "BotConfig", "VpnBotService"]

from .adapter import AdapterError, SafeAdapter
from .bot import BotPolicy
from .config import BotConfig
from .service import VpnBotService

__version__ = "0.2.0"
