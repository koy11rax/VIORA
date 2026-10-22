"""Transactional group grants and durable access-sync outbox.

No production database is opened implicitly. This is the standalone development
schema; integration with the bot's existing database requires a reviewed adapter.
"""
from __future__ import annotations

import json
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path

UTC = timezone.utc


class DomainError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.status = code, status


def instant(value: str | None) -> datetime | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def stamp(value: datetime) -> str:
    return value.astimezone(UTC).isoformat()


class Store:
    def __init__(self, path: str | Path, owner_id: int, clock=None):
        if type(owner_id) is not int or owner_id <= 0:
            raise ValueError('owner_id must be a positive verified Telegram ID')
        self.path, self.owner_id = str(path), owner_id
        self.clock = clock or (lambda: datetime.now(UTC))
        with self.connection() as db:
            application_id = db.execute('PRAGMA application_id').fetchone()[0]
            existing = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchone()
            if existing and application_id != 0x56494F52:
                raise ValueError('Refusing a non-Viora development database; production requires an integration adapter')
            db.execute(f'PRAGMA application_id={0x56494F52}')
            db.executescript('''
              PRAGMA journal_mode=WAL;
              CREATE TABLE IF NOT EXISTS users(
                tg_id INTEGER PRIMARY KEY, username TEXT, first_name TEXT,
                expires_at TEXT, version INTEGER NOT NULL DEFAULT 0);
              CREATE TABLE IF NOT EXISTS groups(
                id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE);
              CREATE TABLE IF NOT EXISTS group_members(
                group_id TEXT REFERENCES groups(id) ON DELETE CASCADE,
                user_id INTEGER REFERENCES users(tg_id) ON DELETE CASCADE,
                PRIMARY KEY(group_id,user_id));
              CREATE TABLE IF NOT EXISTS grant_previews(
                id TEXT PRIMARY KEY, actor INTEGER NOT NULL, days INTEGER NOT NULL,
                reason TEXT NOT NULL, recipients TEXT NOT NULL, expires TEXT NOT NULL,
                result TEXT);
              CREATE TABLE IF NOT EXISTS audit(
                id INTEGER PRIMARY KEY AUTOINCREMENT, batch TEXT NOT NULL,
                actor INTEGER NOT NULL, user_id INTEGER NOT NULL, days INTEGER NOT NULL,
                before_expiry TEXT, after_expiry TEXT NOT NULL, reason TEXT NOT NULL,
                created_at TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS access_outbox(
                id INTEGER PRIMARY KEY AUTOINCREMENT, batch TEXT NOT NULL,
                user_id INTEGER NOT NULL, expires_at TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending', UNIQUE(batch,user_id));
            ''')

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def authorize(self, actor: int):
        if type(actor) is not int or actor != self.owner_id:
            raise DomainError('forbidden', 'Доступ только для владельца', 403)

    def users(self, actor: int):
        self.authorize(actor)
        now = self.clock()
        with self.connection() as db:
            return [dict(r) | {'active': bool(instant(r['expires_at']) and instant(r['expires_at']) > now)}
                    for r in db.execute('SELECT tg_id,username,first_name,expires_at FROM users ORDER BY tg_id')]

    def groups(self, actor: int):
        self.authorize(actor)
        with self.connection() as db:
            return [dict(r) for r in db.execute('''SELECT g.id,g.name,COUNT(m.user_id) AS count
                FROM groups g LEFT JOIN group_members m ON m.group_id=g.id GROUP BY g.id ORDER BY g.name''')]

    def create_group(self, actor: int, name: str, user_ids: list[int]):
        self.authorize(actor)
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80:
            raise DomainError('invalid_name', 'Название группы: от 1 до 80 символов')
        ids = self.validate_ids(user_ids)
        group_id = secrets.token_urlsafe(16)
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self.require_users(db, ids)
            try:
                db.execute('INSERT INTO groups VALUES(?,?)', (group_id, name.strip()))
            except sqlite3.IntegrityError:
                raise DomainError('duplicate_group', 'Группа с таким названием уже существует', 409)
            db.executemany('INSERT INTO group_members VALUES(?,?)', [(group_id, i) for i in ids])
        return {'id': group_id, 'name': name.strip(), 'count': len(ids)}

    @staticmethod
    def validate_ids(ids):
        if not isinstance(ids, list) or len(ids) > 10000 or any(type(i) is not int or i <= 0 for i in ids):
            raise DomainError('invalid_recipients', 'Некорректный список получателей')
        return sorted(set(ids))

    @staticmethod
    def require_users(db, ids):
        for uid in ids:
            if db.execute('SELECT 1 FROM users WHERE tg_id=?', (uid,)).fetchone() is None:
                raise DomainError('unknown_user', 'Получатель больше не существует', 409)

    def preview(self, actor: int, days: int, reason: str, user_ids=None, group_ids=None):
        self.authorize(actor)
        if type(days) is not int or not 1 <= days <= 3650:
            raise DomainError('invalid_days', 'Укажи от 1 до 3650 целых дней')
        if not isinstance(reason, str) or not 3 <= len(reason.strip()) <= 500:
            raise DomainError('invalid_reason', 'Укажи причину: от 3 до 500 символов')
        ids = set(self.validate_ids(user_ids if user_ids is not None else []))
        if group_ids is None:
            group_ids = []
        if not isinstance(group_ids, list) or len(group_ids) > 100 or any(not isinstance(g, str) for g in group_ids):
            raise DomainError('invalid_groups', 'Некорректный список групп')
        now = self.clock()
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            for gid in set(group_ids):
                if gid in ('all', 'active', 'expired', 'recent'):
                    for row in db.execute('SELECT tg_id,expires_at FROM users'):
                        active = bool(instant(row['expires_at']) and instant(row['expires_at']) > now)
                        expiry = instant(row['expires_at'])
                        if gid == 'all' or (gid == 'recent' and expiry and now-timedelta(days=10) <= expiry <= now) or (gid in ('active','expired') and active == (gid == 'active')):
                            ids.add(row['tg_id'])
                else:
                    if db.execute('SELECT 1 FROM groups WHERE id=?', (gid,)).fetchone() is None:
                        raise DomainError('unknown_group', 'Группа не найдена', 404)
                    ids.update(r[0] for r in db.execute('SELECT user_id FROM group_members WHERE group_id=?', (gid,)))
            if not ids or len(ids) > 10000:
                raise DomainError('empty_or_large_selection', 'Выбери от 1 до 10000 получателей')
            self.require_users(db, ids)
            rows = [dict(db.execute('SELECT tg_id,first_name,expires_at,version FROM users WHERE tg_id=?', (uid,)).fetchone()) for uid in sorted(ids)]
            recipients = [r | {'after_expiry': stamp(max(instant(r['expires_at']) or now, now) + timedelta(days=days))} for r in rows]
            pid, expires = secrets.token_urlsafe(24), stamp(now + timedelta(minutes=5))
            db.execute('INSERT INTO grant_previews VALUES(?,?,?,?,?,?,NULL)',
                       (pid, actor, days, reason.strip(), json.dumps(rows), expires))
        return {'preview_id': pid, 'days': days, 'reason': reason.strip(), 'expires_at': expires,
                'count': len(recipients), 'recipients': recipients, 'access_sync': 'not_started'}

    def commit(self, actor: int, preview_id: str):
        self.authorize(actor)
        if not isinstance(preview_id, str) or len(preview_id) > 128:
            raise DomainError('invalid_preview', 'Некорректный предпросмотр')
        now = self.clock()
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            preview = db.execute('SELECT * FROM grant_previews WHERE id=? AND actor=?', (preview_id, actor)).fetchone()
            if not preview:
                raise DomainError('preview_not_found', 'Предпросмотр не найден', 404)
            if preview['result']:
                return json.loads(preview['result'])
            if instant(preview['expires']) <= now:
                raise DomainError('preview_expired', 'Предпросмотр истёк. Проверь список заново', 409)
            recipients = json.loads(preview['recipients'])
            for r in recipients:
                current = db.execute('SELECT expires_at,version FROM users WHERE tg_id=?', (r['tg_id'],)).fetchone()
                if not current or current['version'] != r['version'] or current['expires_at'] != r['expires_at']:
                    raise DomainError('stale_preview', 'Подписки изменились. Проверь получателей заново', 409)
            results = []
            for r in recipients:
                expires = stamp(max(instant(r['expires_at']) or now, now) + timedelta(days=preview['days']))
                db.execute('UPDATE users SET expires_at=?,version=version+1 WHERE tg_id=?', (expires, r['tg_id']))
                db.execute('INSERT INTO audit(batch,actor,user_id,days,before_expiry,after_expiry,reason,created_at) VALUES(?,?,?,?,?,?,?,?)',
                           (preview_id, actor, r['tg_id'], preview['days'], r['expires_at'], expires, preview['reason'], stamp(now)))
                db.execute('INSERT INTO access_outbox(batch,user_id,expires_at) VALUES(?,?,?)', (preview_id, r['tg_id'], expires))
                results.append({'tg_id': r['tg_id'], 'expires_at': expires})
            result = {'batch_id': preview_id, 'count': len(results), 'days': preview['days'],
                      'recipients': results, 'access_sync': 'pending'}
            db.execute('UPDATE grant_previews SET result=? WHERE id=?', (json.dumps(result), preview_id))
        return result

    def events(self, actor: int):
        self.authorize(actor)
        with self.connection() as db:
            return [dict(r) for r in db.execute('SELECT * FROM audit ORDER BY id DESC LIMIT 200')]

    def seed_development(self):
        """Explicit, isolated fixtures; never import the bot's user data."""
        now = self.clock()
        with self.connection() as db:
            db.executemany('INSERT OR IGNORE INTO users(tg_id,username,first_name,expires_at) VALUES(?,?,?,?)',
                           [(1001, 'alex_demo', 'Алексей', stamp(now + timedelta(days=30))),
                            (1002, 'maria_demo', 'Мария', stamp(now + timedelta(days=12))),
                            (1003, 'ilya_demo', 'Илья', stamp(now - timedelta(days=2)))])
