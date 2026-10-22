"""Loopback development API; production authentication is deliberately absent.

Opaque sessions are issued by a trusted server-side integration, never by a
client-supplied Telegram ID or role. CLI-issued owner sessions require an
explicit --development flag and are not a Telegram authentication flow.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import secrets
import sqlite3
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .store import DomainError, Store, instant, stamp


class Sessions:
    def __init__(self, store: Store):
        self.store = store
        with store.connection() as db:
            db.execute('CREATE TABLE IF NOT EXISTS sessions(digest TEXT PRIMARY KEY, actor INTEGER NOT NULL, expires TEXT NOT NULL)')

    def issue_trusted(self, verified_actor: int):
        token = secrets.token_urlsafe(32)
        with self.store.connection() as db:
            db.execute('INSERT INTO sessions VALUES(?,?,?)', (hashlib.sha256(token.encode()).hexdigest(), verified_actor,
                       stamp(self.store.clock() + timedelta(hours=8))))
        return token

    def actor(self, header: str):
        if not header.startswith('Bearer ') or len(header) > 256:
            raise DomainError('unauthorized', 'Войди в аккаунт', 401)
        digest = hashlib.sha256(header[7:].encode()).hexdigest()
        with self.store.connection() as db:
            session = db.execute('SELECT actor,expires FROM sessions WHERE digest=?', (digest,)).fetchone()
        if not session or instant(session['expires']) <= self.store.clock():
            raise DomainError('unauthorized', 'Сеанс истёк', 401)
        return session['actor']


def handler_for(store: Store):
    sessions = Sessions(store)

    class Handler(BaseHTTPRequestHandler):
        server_version = 'VioraDevelopment/0.1'

        def log_message(self, *args):
            pass  # Do not log authorization headers, user payloads or URLs.

        def respond(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)

        def dispatch(self, method):
            try:
                if self.path == '/health' and method == 'GET':
                    return self.respond(200, {'status': 'development', 'production_ready': False})
                actor = sessions.actor(self.headers.get('Authorization', ''))
                if self.path == '/v1/me' and method == 'GET':
                    return self.respond(200, {'id': actor, 'owner': actor == store.owner_id})
                store.authorize(actor)
                data = {}
                if method == 'POST':
                    size = int(self.headers.get('Content-Length', '0'))
                    if not 0 < size <= 65536:
                        raise DomainError('invalid_body', 'Размер запроса вне допустимых границ', 413)
                    data = json.loads(self.rfile.read(size))
                    if not isinstance(data, dict):
                        raise DomainError('invalid_body', 'Ожидается объект JSON')
                route = (method, self.path)
                if route == ('GET', '/v1/admin/users'):
                    result = store.users(actor)
                elif route == ('GET', '/v1/admin/groups'):
                    result = store.groups(actor)
                elif route == ('GET', '/v1/admin/audit'):
                    result = store.events(actor)
                elif route == ('POST', '/v1/admin/groups'):
                    result = store.create_group(actor, data.get('name'), data.get('user_ids'))
                elif route == ('POST', '/v1/admin/grants/preview'):
                    result = store.preview(actor, data.get('days'), data.get('reason'), data.get('user_ids'), data.get('group_ids'))
                elif route == ('POST', '/v1/admin/grants/commit'):
                    result = store.commit(actor, data.get('preview_id'))
                else:
                    raise DomainError('not_found', 'Метод не найден', 404)
                self.respond(200, result)
            except DomainError as exc:
                self.respond(exc.status, {'error': exc.code, 'message': str(exc)})
            except (ValueError, TypeError, UnicodeError):
                self.respond(400, {'error': 'invalid_request', 'message': 'Некорректный запрос'})
            except sqlite3.Error:
                self.respond(503, {'error': 'storage_unavailable', 'message': 'Хранилище недоступно. Повтори запрос с тем же предпросмотром'})

        def do_GET(self):
            self.dispatch('GET')

        def do_POST(self):
            self.dispatch('POST')

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--development', action='store_true', required=True)
    parser.add_argument('--database', type=Path, required=True)
    parser.add_argument('--owner-id', type=int, required=True)
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--seed', action='store_true')
    parser.add_argument('--session-file', type=Path)
    args = parser.parse_args()
    args.database.parent.mkdir(parents=True, exist_ok=True)
    store = Store(args.database, args.owner_id)
    if args.seed:
        store.seed_development()
    if args.session_file:
        # Caller chooses a private location; no session is printed or committed.
        args.session_file.write_text(Sessions(store).issue_trusted(args.owner_id), encoding='utf-8')
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler_for(store))
    print(f'Viora development API: 127.0.0.1:{args.port}; no production access sync')
    server.serve_forever()


if __name__ == '__main__':
    main()
