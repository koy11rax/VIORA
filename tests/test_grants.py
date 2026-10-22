import concurrent.futures
import tempfile
import sqlite3
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from viora_control.store import DomainError, Store, instant


class GrantsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.now = datetime(2026, 10, 11, 12, tzinfo=timezone.utc)
        self.store = Store(Path(self.tmp.name) / 'test.sqlite', 77, lambda: self.now)
        self.store.seed_development()

    def tearDown(self):
        self.tmp.cleanup()

    def test_group_and_explicit_selection_are_deduplicated(self):
        group = self.store.create_group(77, 'Друзья', [1001, 1001, 1003])
        p = self.store.preview(77, 7, 'Компенсация', [1001, 1002], [group['id'], 'active'])
        self.assertEqual([r['tg_id'] for r in p['recipients']], [1001, 1002, 1003])
        result = self.store.commit(77, p['preview_id'])
        self.assertEqual(result['count'], 3)
        rows = {u['tg_id']: u for u in self.store.users(77)}
        self.assertEqual(instant(rows[1001]['expires_at']), self.now + timedelta(days=37))
        self.assertEqual(instant(rows[1003]['expires_at']), self.now + timedelta(days=7))
        self.assertEqual(len(self.store.events(77)), 3)

    def test_concurrent_retries_credit_once(self):
        p = self.store.preview(77, 5, 'Подарок', [1001])
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.store.commit(77, p['preview_id']), range(8)))
        self.assertTrue(all(r == results[0] for r in results))
        self.assertEqual(len(self.store.events(77)), 1)
        with self.store.connection() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM access_outbox').fetchone()[0], 1)

    def test_stale_preview_rolls_back_entire_batch(self):
        p = self.store.preview(77, 7, 'Компенсация', [1001, 1002])
        second = self.store.preview(77, 1, 'Подарок', [1002])
        self.store.commit(77, second['preview_id'])
        with self.assertRaisesRegex(DomainError, 'изменились'):
            self.store.commit(77, p['preview_id'])
        first = next(u for u in self.store.users(77) if u['tg_id'] == 1001)
        self.assertEqual(instant(first['expires_at']), self.now + timedelta(days=30))

    def test_expired_preview(self):
        p = self.store.preview(77, 1, 'Подарок', [1001])
        self.now += timedelta(minutes=6)
        with self.assertRaisesRegex(DomainError, 'истёк'):
            self.store.commit(77, p['preview_id'])

    def test_owner_enforced_on_every_domain_operation(self):
        for call in [lambda: self.store.users(99), lambda: self.store.groups(99),
                     lambda: self.store.preview(99, 1, 'Подарок', [1001]),
                     lambda: self.store.commit(99, 'anything'),
                     lambda: self.store.create_group(99, 'test', [1001]), lambda: self.store.events(99)]:
            with self.assertRaises(DomainError) as ctx:
                call()
            self.assertEqual(ctx.exception.status, 403)

    def test_invalid_inputs(self):
        for days in [0, -1, True, 1.5, 3651, '7']:
            with self.assertRaises(DomainError):
                self.store.preview(77, days, 'Подарок', [1001])
        for ids in [[True], ['1001'], [-1], [9999], []]:
            with self.assertRaises(DomainError):
                self.store.preview(77, 1, 'Подарок', ids)

    def test_membership_is_frozen_after_preview(self):
        group = self.store.create_group(77, 'Друзья', [1001])
        p = self.store.preview(77, 3, 'Подарок', group_ids=[group['id']])
        with self.store.connection() as db:
            db.execute('INSERT INTO group_members VALUES(?,?)', (group['id'], 1002))
        self.assertEqual(self.store.commit(77, p['preview_id'])['count'], 1)

    def test_existing_bot_database_is_refused_without_mutation(self):
        target = Path(self.tmp.name) / 'existing.sqlite'
        with sqlite3.connect(target) as db:
            db.execute('CREATE TABLE users(tg_id INTEGER PRIMARY KEY, expires_at TEXT)')
            db.execute('INSERT INTO users VALUES(1,?)', ('2026-12-01',))
        db.close()
        with self.assertRaisesRegex(ValueError, 'Refusing'):
            Store(target, 77)
        with sqlite3.connect(target) as db:
            self.assertEqual(db.execute('SELECT * FROM users').fetchall(), [(1, '2026-12-01')])
            self.assertEqual(db.execute('PRAGMA application_id').fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table'").fetchone()[0], 1)
        db.close()


if __name__ == '__main__':
    unittest.main()
