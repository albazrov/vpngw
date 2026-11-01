"""Production-oriented Telegram bot service for vpngw.

The bot validates user/chat access and delegates only a fixed set of operations to
SafeAdapter, which in turn invokes a small, approved bash adapter. Secrets are
read from the environment, never printed, and never embedded in argv.
"""

from __future__ import annotations

import asyncio
import sqlite3

from telegram import BotCommand, InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import ApplicationBuilder, CallbackQueryHandler, CommandHandler, ContextTypes

from .adapter import AdapterError, SafeAdapter
from .bot import BotPolicy
from .config import BotConfig
from .queue import JobQueue
from .state import BotState


class VpnBotService:
    """Thin wrapper around the bot handlers and adapter."""

    def __init__(self, config: BotConfig):
        self.config = config
        self.policy = BotPolicy(set(config.allowed_chat_ids))
        self.admin_chat_ids = set(config.admin_chat_ids)
        self.adapter = SafeAdapter()
        self.state = BotState(config.state_db)
        self.queue = JobQueue(config.queue_db)

    def build_application(self):
        app = ApplicationBuilder().token(self.config.token).post_init(self._set_commands).build()
        app.add_handler(CommandHandler("start", self._start))
        app.add_handler(CommandHandler("menu", self._start))
        app.add_handler(CommandHandler("status", self._status))
        app.add_handler(CommandHandler("speed", self._speed_menu))
        app.add_handler(CommandHandler("speedadd", self._speed_add))
        app.add_handler(CallbackQueryHandler(self._callback))
        return app

    async def _set_commands(self, app) -> None:
        await app.bot.set_my_commands(
            [
                BotCommand("start", "Открыть меню VPN"),
                BotCommand("status", "Проверить VPN и скорость"),
                BotCommand("speed", "Выбрать сервис замера скорости"),
                BotCommand("speedadd", "Добавить сервис замера (администратор)"),
            ]
        )

    async def _start(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if not self.policy.is_allowed_chat(update.effective_chat.id):
            await update.message.reply_text("Access denied")
            return

        keyboard = [
            [InlineKeyboardButton("🇷🇴 RO", callback_data="set_RO"), InlineKeyboardButton("🇩🇪 DE", callback_data="set_DE")],
            [InlineKeyboardButton("🇫🇮 FI", callback_data="set_FI"), InlineKeyboardButton("📊 Status", callback_data="status")],
            [InlineKeyboardButton("Измерить скорость", callback_data="speed_menu")],
        ]
        await update.message.reply_text(
            "Выберите локацию для переключения:",
            reply_markup=InlineKeyboardMarkup(keyboard),
        )

    async def _status(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if not self.policy.is_allowed_chat(update.effective_chat.id):
            await update.message.reply_text("Access denied")
            return

        await self._run_with_progress(
            update.message.reply_text,
            "⏳ Проверяю состояние VPN и измеряю скорость через туннель...",
            "status",
            {},
            "Status: ",
            "Status error",
        )

    async def _run_with_progress(
        self,
        reply_text,
        progress_text: str,
        action: str,
        payload: dict,
        result_prefix: str = "",
        error_prefix: str = "Ошибка",
    ) -> None:
        progress_message = await reply_text(progress_text)
        try:
            result = await asyncio.to_thread(self.adapter.execute, action, payload)
        except AdapterError as exc:
            await progress_message.edit_text(f"{error_prefix}: {exc}")
            return
        await progress_message.edit_text(f"{result_prefix}{result['result']}")

    async def _speed_menu(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if not self.policy.is_allowed_chat(update.effective_chat.id):
            await update.message.reply_text("Access denied")
            return
        await self._send_speed_menu(update.message.reply_text)

    async def _speed_add(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        chat_id = update.effective_chat.id
        if not self.policy.is_allowed_chat(chat_id):
            await update.message.reply_text("Access denied")
            return
        if chat_id not in self.admin_chat_ids:
            await update.message.reply_text("Добавлять сервисы проверки скорости может только администратор.")
            return

        args = context.args or []
        if len(args) != 5:
            await update.message.reply_text(
                "Формат: /speedadd <id> <название> <https-url> <connect-timeout> <max-time>\n"
                "Пример: /speedadd fast FastTest https://speed.example/file.bin 8 30"
            )
            return

        profile_id, name, url, connect_timeout_raw, max_time_raw = args
        try:
            profile = self.adapter.validate_custom_speed_profile(
                profile_id,
                name,
                url,
                connect_timeout_raw,
                max_time_raw,
            )
            existing_ids = {item["id"] for item in self.adapter.speed_options()}
            existing_ids.update(item["id"] for item in self.state.list_speed_profiles())
            if profile["id"] in existing_ids:
                raise ValueError("Профиль с таким id уже существует.")
            await asyncio.to_thread(
                self.state.add_speed_profile,
                profile["id"],
                profile["name"],
                profile["url"],
                profile["connect_timeout"],
                profile["max_time"],
                update.effective_user.id,
            )
        except (AdapterError, ValueError) as exc:
            await update.message.reply_text(f"Не удалось добавить профиль: {exc}")
            return
        except sqlite3.IntegrityError:
            await update.message.reply_text("Профиль с таким id уже существует.")
            return

        await update.message.reply_text(
            f"Добавлен сервис «{profile['name']}». Он доступен в меню /speed."
        )

    async def _send_speed_menu(self, reply_text) -> None:
        try:
            profiles = await asyncio.to_thread(self.adapter.speed_options)
            custom_profiles = await asyncio.to_thread(self.state.list_speed_profiles)
        except AdapterError as exc:
            await reply_text(f"Speed test config error: {exc}")
            return
        profiles.extend(custom_profiles)
        keyboard = [
            [InlineKeyboardButton(profile["name"], callback_data=f"speed_{profile['id']}")]
            for profile in profiles
            if len(profile["id"]) <= 32
        ]
        if not keyboard:
            await reply_text("Нет доступных профилей проверки скорости.")
            return
        await reply_text("Выберите проверку скорости:", reply_markup=InlineKeyboardMarkup(keyboard))

    async def _callback(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        if not self.policy.is_allowed_chat(update.effective_chat.id):
            await update.callback_query.answer("Access denied")
            return

        data = update.callback_query.data or ""

        if data == "speed_menu":
            await update.callback_query.answer()
            await self._send_speed_menu(update.callback_query.message.reply_text)
            return

        if data.startswith("speed_"):
            profile = data.removeprefix("speed_")
            await update.callback_query.answer("Замер запущен")
            custom_profile = await asyncio.to_thread(self.state.get_speed_profile, profile)
            payload = {"profile": profile}
            if custom_profile:
                payload.update(custom_profile)
            await self._run_with_progress(
                update.callback_query.message.reply_text,
                f"⏳ Замер скорости запущен через профиль «{profile}». Проверяю сервер и измеряю загрузку через VPN-туннель...",
                "speed",
                payload,
                error_prefix="Ошибка замера скорости",
            )
            return

        if data == "status":
            await update.callback_query.answer("Проверка запущена")
            await self._run_with_progress(
                update.callback_query.message.reply_text,
                "⏳ Проверяю состояние VPN и измеряю скорость через туннель...",
                "status",
                {},
                "Status: ",
                "Status error",
            )
            return

        if data.startswith("set_"):
            loc = data.replace("set_", "").upper()
            await update.callback_query.answer(f"Переключаю на {loc}")
            await self._run_with_progress(
                update.callback_query.message.reply_text,
                f"⏳ Выполняю переключение VPN на {loc}...",
                "connect",
                {"loc": loc},
                "Переключение: ",
                "Ошибка переключения",
            )
            return

        await update.callback_query.answer("Unsupported action")


def main() -> None:
    config = BotConfig.from_env()
    service = VpnBotService(config)
    service.build_application().run_polling()


if __name__ == "__main__":
    main()
