import asyncio
import concurrent.futures
import sqlite3
import tempfile
import unittest
from pathlib import Path

from viora_control.telegram_auth import AuthError, TelegramAuth
from viora_control.bot_account import BotAccountReader


class TelegramLoginTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.now = [2000000000]
        self.auth = TelegramAuth(self.path / 'auth.sqlite', 'ExampleVioraBot', 77, clock=lambda: self.now[0])

    def login(self, actor=88):
        challenge = self.auth.start()
        self.assertEqual(self.auth.claim_from_telegram(challenge['id'], actor), challenge['code'])
        self.auth.approve_from_telegram(challenge['id'], actor)
        return self.auth.poll(challenge['id'], challenge['poll_secret'])['session']

    def test_requires_private_poll_secret_and_trusted_confirmation(self):
        c = self.auth.start()
        self.assertLessEqual(len('viora_' + c['id']), 64)
        self.assertNotIn(c['poll_secret'], c['bot_url'])
        self.assertEqual(self.auth.poll(c['id'], c['poll_secret'])['status'], 'pending')
        with self.assertRaises(AuthError): self.auth.poll(c['id'], 'x' * 43)
        with self.assertRaises(AuthError): self.auth.approve_from_telegram(c['id'], 77)
        self.auth.claim_from_telegram(c['id'], 88)
        with self.assertRaises(AuthError): self.auth.claim_from_telegram(c['id'], 77)
        with self.assertRaises(AuthError): self.auth.approve_from_telegram(c['id'], 77)
        self.auth.approve_from_telegram(c['id'], 88)
        session = self.auth.poll(c['id'], c['poll_secret'])['session']
        self.assertEqual(self.auth.actor('Bearer ' + session), 88)
        with self.assertRaises(AuthError): self.auth.poll(c['id'], c['poll_secret'])
        with sqlite3.connect(self.auth.path) as db:
            self.assertNotIn(session, repr(db.execute('SELECT * FROM app_sessions').fetchall()))
            self.assertNotIn(c['poll_secret'], repr(db.execute('SELECT * FROM challenges').fetchall()))
        db.close()
        self.auth.logout('Bearer ' + session)
        with self.assertRaises(AuthError): self.auth.actor('Bearer ' + session)

    def test_expiration_cancel_and_simultaneous_exchange(self):
        c = self.auth.start()
        self.auth.claim_from_telegram(c['id'], 77)
        self.auth.approve_from_telegram(c['id'], 77)
        def poll(_):
            try: return self.auth.poll(c['id'], c['poll_secret'])
            except AuthError: return None
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(poll, range(4)))
        self.assertEqual(sum(r is not None for r in results), 1)
        session = next(r['session'] for r in results if r)
        self.now[0] += 8 * 3600
        with self.assertRaises(AuthError): self.auth.actor('Bearer ' + session)
        c = self.auth.start()
        self.auth.poll(c['id'], c['poll_secret'], cancel=True)
        with self.assertRaises(AuthError): self.auth.claim_from_telegram(c['id'], 77)
        c = self.auth.start()
        self.now[0] += 301
        with self.assertRaises(AuthError): self.auth.poll(c['id'], c['poll_secret'])

    def test_rate_limit_and_database_guard(self):
        for _ in range(60): self.auth.start('peer')
        with self.assertRaises(AuthError): self.auth.start('peer')
        self.now[0] += 61
        self.auth.start('peer')
        existing = self.path / 'bot.sqlite'
        with sqlite3.connect(existing) as db: db.execute('CREATE TABLE users(id INTEGER)')
        db.close()
        with self.assertRaises(ValueError): TelegramAuth(existing, 'ExampleVioraBot', 77)

    def test_account_adapter_is_read_only_and_scoped_to_actor(self):
        users, devices = self.path / 'users.sqlite', self.path / 'devices.sqlite'
        with sqlite3.connect(users) as db:
            db.execute('CREATE TABLE users(tg_id INTEGER,first_name TEXT,username TEXT,uuid TEXT,expires_at TEXT,sub_token TEXT)')
            db.execute('INSERT INTO users VALUES(88,?,NULL,?,?,?)', ('Test', 'test-uuid', '2034-01-01T00:00:00', 'a' * 32))
        db.close()
        with sqlite3.connect(devices) as db:
            db.execute('CREATE TABLE devices(id INTEGER,user_uuid TEXT,model TEXT,platform TEXT,last_seen TEXT,revoked INTEGER)')
            db.execute("INSERT INTO devices VALUES(1,'test-uuid','Android','Android','2033-01-01',0)")
            db.execute("INSERT INTO devices VALUES(2,'other-uuid','Private','Android','2033-01-01',0)")
        db.close()
        before = users.read_bytes(), devices.read_bytes()
        reader = BotAccountReader(users, devices)
        self.assertEqual(reader(88)['devices'][0]['name'], 'Android')
        self.assertEqual(len(reader(88)['devices']), 1)
        self.assertEqual(reader(99)['devices'], [])
        self.assertEqual(before, (users.read_bytes(), devices.read_bytes()))


if __name__ == '__main__': unittest.main()
