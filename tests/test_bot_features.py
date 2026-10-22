import asyncio
from contextlib import closing
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from datetime import datetime, timedelta
from viora_control.bot_features import BotFeatures
from viora_control.telegram_auth import TelegramAuth
from viora_control.store import DomainError
from viora_control.bot_account import BotAccountReader


class BotFeaturesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)/'bot-fixture.db'
        with closing(sqlite3.connect(self.path)) as db, db:
            db.executescript('''
              CREATE TABLE users(tg_id INTEGER PRIMARY KEY,first_name TEXT,username TEXT,uuid TEXT,expires_at TEXT,notif_3d INTEGER DEFAULT 0,notif_1d INTEGER DEFAULT 0,notif_1h INTEGER DEFAULT 0,reminder_sent_expiry TEXT);
              CREATE TABLE sbp_payments(id INTEGER PRIMARY KEY,tg_id INTEGER,tariff TEXT,amount INTEGER,status TEXT DEFAULT 'pending',created_at TEXT);
              CREATE TABLE payments_log(id INTEGER PRIMARY KEY,tg_id INTEGER,amount INTEGER,currency TEXT);
            ''')
            db.executemany('INSERT INTO users(tg_id,first_name,uuid,expires_at) VALUES(?,?,?,?)',[(1,'Owner fixture','fixture-1',(datetime.utcnow()+timedelta(days=10)).isoformat()),(2,'User fixture','fixture-2',(datetime.utcnow()-timedelta(days=1)).isoformat())])
        self.auth=TelegramAuth(Path(self.temp.name)/'auth.db','VioraFixtureBot',1)
        self.features=BotFeatures(self.auth,self.path,{'test':{'name':'Тестовый тариф','days':30,'rub':100}}, {'phone':'fixture','name':'fixture','bank':'fixture'},self.settle,lambda:None)

    def settle(self, pid):
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute('BEGIN IMMEDIATE')
            row=db.execute("SELECT tg_id,amount FROM sbp_payments WHERE id=? AND status='pending'",(pid,)).fetchone()
            if not row: return None
            db.execute("UPDATE sbp_payments SET status='approved' WHERE id=?",(pid,))
            db.execute('INSERT INTO payments_log(tg_id,amount,currency) VALUES(?,?,?)',(*row,'RUB'))
            return True

    def session(self, actor):
        challenge=self.auth.start('fixture')
        self.auth.claim_from_telegram(challenge['id'],actor)
        self.auth.approve_from_telegram(challenge['id'],actor)
        return self.auth.poll(challenge['id'],challenge['poll_secret'])['session']

    def test_ownership_and_no_user_migration(self):
        with closing(sqlite3.connect(self.path)) as db, db:
            self.assertNotIn('version',[r[1] for r in db.execute('PRAGMA table_info(users)')])
            self.assertEqual(db.execute('SELECT COUNT(*) FROM users').fetchone()[0],2)
        for method in (self.features.store.users,self.features.store.groups,self.features.overview):
            with self.assertRaises(DomainError): method(2)

    def device_fixture(self, fail_sync=False):
        device_path=Path(self.temp.name)/'device-fixture.db'
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute('ALTER TABLE users ADD COLUMN sub_token TEXT')
        with closing(sqlite3.connect(device_path)) as db, db:
            db.executescript('''CREATE TABLE devices(id INTEGER PRIMARY KEY,user_uuid TEXT,model TEXT,platform TEXT,last_seen TEXT,revoked INTEGER DEFAULT 0);
              INSERT INTO devices VALUES(11,'fixture-1','Owner phone','Android','2026-01-01',0);
              INSERT INTO devices VALUES(22,'fixture-2','User laptop','Windows','2026-01-01',0);''')
        self.features.account_reader=BotAccountReader(self.path,device_path)
        def revoke(uuid, device_id):
            with closing(sqlite3.connect(device_path)) as db, db:
                changed=db.execute('UPDATE devices SET revoked=1 WHERE user_uuid=? AND id=? AND revoked=0',(uuid,device_id)).rowcount
            if fail_sync: raise RuntimeError('fixture Xray temporarily offline')
            return changed>0
        self.features.revoke_device=revoke
        return device_path

    def test_device_revocation_scoped_to_session_and_opaque_id(self):
        path=self.device_fixture()
        self.assertEqual(self.features.devices(2)['devices'][0]['id'],22)
        with self.assertRaises(DomainError): self.features.revoke(2,{'id':11,'actor':1,'user_uuid':'fixture-1'})
        with self.assertRaises(DomainError): self.features.revoke(2,{'id':True})
        result=self.features.revoke(2,{'id':22,'actor':1,'user_uuid':'fixture-1'})
        self.assertEqual(result['access_sync'],'applied')
        self.assertEqual(result['devices'],[])
        with self.assertRaises(DomainError): self.features.revoke(2,{'id':22})
        with closing(sqlite3.connect(path)) as db:
            self.assertEqual(db.execute('SELECT id,revoked FROM devices ORDER BY id').fetchall(),[(11,0),(22,1)])

    def test_saved_device_revocation_reports_pending_access_sync(self):
        self.device_fixture(fail_sync=True)
        result=self.features.revoke(2,{'id':22})
        self.assertEqual(result['devices'],[])
        self.assertEqual(result['access_sync'],'pending')

    def test_orders_are_scoped_reusable_and_server_priced(self):
        first=self.features.order(2,{'tariff':'test','request_id':'fixture-request-0001','amount':1,'tg_id':1})
        again=self.features.order(2,{'tariff':'test','request_id':'fixture-request-0002'})
        self.assertEqual(first,again)
        orders=self.features.renewals(2)['orders']
        self.assertEqual(len(orders),1)
        self.assertEqual(orders[0]['amount'],100)
        self.assertEqual(self.features.renewals(1)['orders'],[])
        with self.assertRaises(DomainError): self.features.submit(1,first['id'])
        self.features.submit(2,first['id'])
        self.features.submit(2,first['id'])
        self.assertEqual(self.features.renewals(2)['orders'][0]['submitted'],1)
        with closing(sqlite3.connect(self.path)) as db, db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM payments_log').fetchone()[0],0)

    def test_atomic_group_grant_idempotence_and_bot_time_compatibility(self):
        group=self.features.store.create_group(1,'Fixture group',[1,2])
        p=self.features.store.preview(1,7,'Fixture reason',[1],[group['id'],'all'])
        self.assertEqual(len(p['recipients']),2)
        result=self.features.store.commit(1,p['preview_id'])
        self.assertEqual(result,self.features.store.commit(1,p['preview_id']))
        self.assertEqual(len(self.features.store.events(1)),2)
        with closing(sqlite3.connect(self.path)) as db, db:
            for expiry, in db.execute('SELECT expires_at FROM users'):
                self.assertIsNone(datetime.fromisoformat(expiry).tzinfo)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM payments_log').fetchone()[0],0)

    def test_stale_preview_rolls_back_every_recipient(self):
        p=self.features.store.preview(1,7,'Fixture reason',[1,2],[])
        with closing(sqlite3.connect(self.path)) as db, db:
            before=db.execute('SELECT expires_at FROM users WHERE tg_id=1').fetchone()[0]
            db.execute("UPDATE users SET expires_at='2026-01-01T00:00:00' WHERE tg_id=2")
        with self.assertRaises(DomainError): self.features.store.commit(1,p['preview_id'])
        with closing(sqlite3.connect(self.path)) as db, db:
            self.assertEqual(db.execute('SELECT expires_at FROM users WHERE tg_id=1').fetchone()[0],before)
        self.assertEqual(self.features.store.events(1),[])

    def test_http_roles_and_payment_ledger_duplicate_protection(self):
        self.device_fixture()
        asyncio.run(self.http_check())

    async def http_check(self):
        from aiohttp import web
        from aiohttp.test_utils import TestClient,TestServer
        app=web.Application(); self.features.install_web(app)
        async with TestClient(TestServer(app)) as client:
            self.assertEqual((await client.get('/v1/app/admin/overview')).status,401)
            user={'Authorization':'Bearer '+self.session(2)}
            owner={'Authorization':'Bearer '+self.session(1)}
            self.assertEqual((await client.get('/v1/app/devices')).status,401)
            devices=await client.get('/v1/app/devices',headers=user)
            self.assertEqual((await devices.json())['devices'][0]['id'],22)
            self.assertEqual((await client.post('/v1/app/devices/revoke',headers=user,json={'id':11,'actor':1})).status,404)
            self.assertEqual((await client.post('/v1/app/devices/revoke',headers=user,json={'id':22,'actor':1})).status,200)
            self.assertEqual((await client.get('/v1/app/admin/users',headers=user)).status,403)
            created=await client.post('/v1/app/orders',headers=user,json={'tariff':'test','request_id':'fixture-request-0001'})
            pid=(await created.json())['id']
            self.assertEqual((await client.post('/v1/app/admin/orders/approve',headers=user,json={'id':pid,'actor':1})).status,403)
            for _ in range(2):
                approved=await client.post('/v1/app/admin/orders/approve',headers=owner,json={'id':pid})
                self.assertEqual(approved.status,200)
            with closing(sqlite3.connect(self.path)) as db, db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM payments_log').fetchone()[0],1)
            self.assertEqual((await client.post('/v1/app/orders',headers=user,data='x'*4097)).status,413)

if __name__=='__main__': unittest.main()
