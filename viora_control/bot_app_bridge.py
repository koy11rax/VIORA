"""Explicit integration hook for the existing aiogram 3 / aiohttp bot."""
import asyncio
import os
from pathlib import Path
from .bot_account import BotAccountReader
from .telegram_auth import TelegramAuth, handle_start, handle_confirmation, install_web_routes


class BotAppBridge:
    def __init__(self, auth, reader):
        self.auth, self.reader = auth, reader

    @classmethod
    async def create(cls, bot, owner_id, users_path, devices_path, auth_path):
        auth_path = Path(auth_path).resolve()
        if auth_path in (Path(users_path).resolve(), Path(devices_path).resolve()):
            raise ValueError('App auth state must use a separate database')
        me = await bot.get_me()
        auth = await asyncio.to_thread(TelegramAuth, auth_path, me.username, owner_id)
        if os.name != 'nt':
            os.chmod(auth_path, 0o600)
        return cls(auth, BotAccountReader(users_path, devices_path))

    def install_web(self, app):
        install_web_routes(app, self.auth, self.reader)

    async def start(self, message):
        return await handle_start(message, self.auth)

    async def confirm(self, callback):
        return await handle_confirmation(callback, self.auth)
