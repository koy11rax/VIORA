"""Device login: only trusted Telegram updates can approve an app challenge.

This module never opens the bot's user/payment database. Auth state lives in a
separate SQLite file; only a supplied, read-only account reader accesses the bot.
"""
from __future__ import annotations

import hashlib
import asyncio
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path


class AuthError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class TelegramAuth:
    def __init__(self, path: Path, bot_username: str, owner_id: int, clock=time.time):
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{4,31}', bot_username):
            raise ValueError('Invalid bot username')
        if type(owner_id) is not int or owner_id <= 0:
            raise ValueError('Invalid owner ID')
        self.path, self.username, self.owner_id, self.clock = str(path), bot_username, owner_id, clock
        with self.db() as db:
            existing = db.execute("SELECT 1 FROM sqlite_master WHERE type='table'").fetchone()
            if existing and db.execute('PRAGMA application_id').fetchone()[0] != 0x56494155:
                raise ValueError('Use a dedicated auth database, never the existing bot database')
            db.execute('PRAGMA application_id=0x56494155')
            db.executescript('''
              PRAGMA journal_mode=WAL;
              CREATE TABLE IF NOT EXISTS challenges(
                id TEXT PRIMARY KEY, poll_digest TEXT NOT NULL, code TEXT NOT NULL,
                expires INTEGER NOT NULL, actor INTEGER, approved INTEGER NOT NULL DEFAULT 0,
                consumed INTEGER NOT NULL DEFAULT 0);
              CREATE TABLE IF NOT EXISTS app_sessions(
                digest TEXT PRIMARY KEY, actor INTEGER NOT NULL, expires INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS auth_rate(bucket TEXT PRIMARY KEY, count INTEGER NOT NULL);
            ''')

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def start(self, remote='local'):
        now = int(self.clock())
        challenge, poll = secrets.token_urlsafe(18), secrets.token_urlsafe(32)
        code = f'{secrets.randbelow(1000000):06d}'
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute('DELETE FROM challenges WHERE expires<=?', (now,))
            db.execute('DELETE FROM app_sessions WHERE expires<=?', (now,))
            # All callers are behind the same reverse proxy until explicitly configured.
            # A global cap complements the per-peer cap and the proxy's rate limit.
            bucket = f'{now // 60}:{digest(remote)}'
            db.execute('DELETE FROM auth_rate WHERE bucket NOT LIKE ?', (f'{now // 60}:%',))
            count = db.execute('SELECT count FROM auth_rate WHERE bucket=?', (bucket,)).fetchone()
            if count and count[0] >= 60:
                raise AuthError('Слишком много попыток. Подожди минуту.', 429)
            if db.execute('SELECT COUNT(*) FROM challenges').fetchone()[0] >= 10000:
                raise AuthError('Вход временно недоступен', 503)
            db.execute('INSERT INTO auth_rate VALUES(?,1) ON CONFLICT(bucket) DO UPDATE SET count=count+1', (bucket,))
            db.execute('INSERT INTO challenges(id,poll_digest,code,expires) VALUES(?,?,?,?)',
                       (challenge, digest(poll), code, now + 300))
        return {'id': challenge, 'poll_secret': poll, 'code': code, 'expires_at': now + 300,
                'bot_url': f'https://t.me/{self.username}?start=viora_{challenge}'}

    def _challenge(self, db, challenge):
        if not isinstance(challenge, str) or not re.fullmatch(r'[A-Za-z0-9_-]{24}', challenge):
            raise AuthError('Недействительный запрос входа', 404)
        row = db.execute('SELECT * FROM challenges WHERE id=?', (challenge,)).fetchone()
        if not row or row['expires'] <= self.clock() or row['consumed']:
            raise AuthError('Запрос входа истёк. Начни заново в приложении.', 410)
        return row

    def claim_from_telegram(self, challenge: str, verified_actor: int):
        if type(verified_actor) is not int or verified_actor <= 0:
            raise AuthError('Недействительный пользователь', 403)
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row = self._challenge(db, challenge)
            if row['actor'] is not None and row['actor'] != verified_actor:
                raise AuthError('Запрос уже открыт другим аккаунтом', 409)
            db.execute('UPDATE challenges SET actor=? WHERE id=?', (verified_actor, challenge))
            return row['code']

    def approve_from_telegram(self, challenge: str, verified_actor: int):
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row = self._challenge(db, challenge)
            if type(verified_actor) is not int or row['actor'] != verified_actor:
                raise AuthError('Подтверждение принадлежит другому аккаунту', 403)
            db.execute('UPDATE challenges SET approved=1 WHERE id=?', (challenge,))

    def poll(self, challenge, poll_secret, cancel=False):
        if not isinstance(poll_secret, str) or len(poll_secret) != 43:
            raise AuthError('Недействительный запрос входа', 401)
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row = self._challenge(db, challenge)
            if not secrets.compare_digest(row['poll_digest'], digest(poll_secret)):
                raise AuthError('Недействительный запрос входа', 401)
            if cancel:
                db.execute('DELETE FROM challenges WHERE id=?', (challenge,))
                return {'status': 'cancelled'}
            if not row['approved']:
                return {'status': 'pending'}
            token = secrets.token_urlsafe(32)
            expires = int(self.clock()) + 8 * 3600
            db.execute('INSERT INTO app_sessions VALUES(?,?,?)', (digest(token), row['actor'], expires))
            db.execute('UPDATE challenges SET consumed=1 WHERE id=?', (challenge,))
            return {'status': 'approved', 'session': token, 'expires_at': expires}

    def actor(self, authorization):
        if not isinstance(authorization, str) or not re.fullmatch(r'Bearer [A-Za-z0-9_-]{43}', authorization):
            raise AuthError('Войди через Telegram', 401)
        with self.db() as db:
            row = db.execute('SELECT actor,expires FROM app_sessions WHERE digest=?', (digest(authorization[7:]),)).fetchone()
        if not row or row['expires'] <= self.clock():
            raise AuthError('Сеанс истёк. Войди через Telegram снова.', 401)
        return row['actor']

    def logout(self, authorization):
        self.actor(authorization)
        with self.db() as db:
            db.execute('DELETE FROM app_sessions WHERE digest=?', (digest(authorization[7:]),))


def install_web_routes(app, auth: TelegramAuth, account_reader):
    """Mount on the existing loopback aiohttp app, behind its trusted HTTPS proxy."""
    from aiohttp import web
    import inspect

    def response(data, status=200):
        return web.json_response(data, status=status, headers={
            'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'})

    async def endpoint(request):
        try:
            data = {}
            if request.method == 'POST':
                # Bounded streaming read also handles chunked HTTP bodies.
                async def bounded_body():
                    body = bytearray()
                    async for chunk in request.content.iter_chunked(4096):
                        body.extend(chunk)
                        if len(body) > 4096:
                            raise AuthError('Запрос слишком большой', 413)
                    return body
                raw = await asyncio.wait_for(bounded_body(), timeout=15)
                import json
                data = json.loads(raw)
                if not isinstance(data, dict):
                    raise AuthError('Ожидается объект JSON')
            route = request.path
            if route == '/v1/app/auth/start':
                result = await asyncio.to_thread(auth.start, request.remote or 'local')
            elif route in ('/v1/app/auth/poll', '/v1/app/auth/cancel'):
                result = await asyncio.to_thread(auth.poll, data.get('id'), data.get('poll_secret'), cancel=route.endswith('/cancel'))
            else:
                header = request.headers.get('Authorization', '')
                actor = await asyncio.to_thread(auth.actor, header)
                if route == '/v1/app/auth/logout':
                    await asyncio.to_thread(auth.logout, header)
                    result = {'status': 'logged_out'}
                else:
                    result = await asyncio.to_thread(account_reader, actor)
                    if inspect.isawaitable(result):
                        result = await result
                    result = dict(result)
                    result['id'], result['owner'] = actor, actor == auth.owner_id
                    result['bot_url'] = f'https://t.me/{auth.username}'
            return response(result)
        except AuthError as error:
            return response({'message': str(error)}, error.status)
        except (ValueError, TypeError, UnicodeError):
            return response({'message': 'Некорректный запрос'}, 400)
        except Exception:
            # Do not include session secrets, account URLs or database errors.
            return response({'message': 'Сервис аккаунта временно недоступен'}, 503)

    for path in ('start', 'poll', 'cancel', 'logout'):
        app.router.add_post('/v1/app/auth/' + path, endpoint)
    app.router.add_get('/v1/app/account', endpoint)


async def handle_start(message, auth: TelegramAuth):
    """Call first in the existing /start handler. Only replies to user-initiated login."""
    parts = (message.text or '').split(maxsplit=1)
    if len(parts) != 2 or not parts[1].startswith('viora_'):
        return False
    if message.chat.type != 'private' or not message.from_user or message.from_user.is_bot:
        return True
    from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup
    challenge = parts[1][6:]
    try:
        code = await asyncio.to_thread(auth.claim_from_telegram, challenge, message.from_user.id)
        await message.answer(
            f'Вход в Viora\n\nКод: <b>{code}</b>\n'
            'Сравни его с кодом в приложении. Подтверждай только вход, который начал сам.',
            reply_markup=InlineKeyboardMarkup(inline_keyboard=[[
                InlineKeyboardButton(text='Подтвердить вход', callback_data=f'viora_auth:{challenge}')]]))
    except AuthError as error:
        await message.answer(str(error))
    return True


async def handle_confirmation(callback, auth: TelegramAuth):
    if not (callback.data or '').startswith('viora_auth:'):
        return False
    if not callback.message or callback.message.chat.type != 'private' or callback.from_user.is_bot:
        await callback.answer('Открой вход в личном чате с ботом', show_alert=True)
        return True
    try:
        await asyncio.to_thread(auth.approve_from_telegram, callback.data.split(':', 1)[1], callback.from_user.id)
        await callback.answer('Вход подтверждён')
        await callback.message.edit_text('Вход в Viora подтверждён. Вернись в приложение и нажми «Проверить подтверждение».')
    except AuthError as error:
        await callback.answer(str(error), show_alert=True)
    return True
