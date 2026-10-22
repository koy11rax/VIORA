"""Read-only adapter for the existing Viora bot schema; no user or payment writes."""
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


class BotAccountReader:
    def __init__(self, users_path, devices_path, origin='https://vpnfn2345.duckdns.org'):
        parsed = urlsplit(origin)
        if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.query or parsed.fragment or parsed.path:
            raise ValueError('Use an HTTPS origin without a path')
        self.users = Path(users_path).resolve()
        self.devices = Path(devices_path).resolve()
        self.origin = origin

    @staticmethod
    @contextmanager
    def connect(path):
        db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        try:
            yield db
        finally:
            db.close()

    def __call__(self, verified_actor):
        with self.connect(self.users) as db:
            row = db.execute('SELECT first_name,username,uuid,expires_at,sub_token FROM users WHERE tg_id=?', (verified_actor,)).fetchone()
        if not row:
            return {'first_name': 'Пользователь', 'expires_at': None, 'subscription_url': None, 'devices': []}
        expires = None
        if row['expires_at']:
            expires = datetime.fromisoformat(row['expires_at'])
            if expires.tzinfo is None:
                expires = expires.replace(tzinfo=timezone.utc)
        token = row['sub_token']
        # Existing bot issues hexadecimal subscription tokens. Never create/rotate one here.
        import re
        url = f'{self.origin}/sub/{token}' if isinstance(token, str) and re.fullmatch(r'[a-fA-F0-9]{32,64}', token) else None
        with self.connect(self.devices) as db:
            devices = db.execute('SELECT id,model,platform,last_seen FROM devices WHERE user_uuid=? AND revoked=0 ORDER BY id', (row['uuid'],)).fetchall()
        return {'first_name': str(row['first_name'] or row['username'] or 'Пользователь')[:200],
                'expires_at': expires.isoformat() if expires else None,
                'subscription_url': url,
                'device_limit': 3,
                'devices': [{'id': d['id'], 'name': str(d['model'] or d['platform'] or 'Устройство')[:200], 'platform': d['platform'], 'last_seen': d['last_seen']} for d in devices]}
