import asyncio
import base64
import io
import sqlite3
import struct
import threading
import unittest
import zlib
from contextlib import closing
from types import SimpleNamespace
from unittest.mock import patch
import test_bot_features
from viora_control.bot_admin import BotAdmin
from viora_control.store import DomainError


class AdminToolsTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_bot_features.BotFeaturesTests(); self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.f=self.fixture.features
        self.path=self.fixture.path
        self.calls=[]
        with closing(sqlite3.connect(self.path)) as db,db:
            db.executescript('''
              CREATE TABLE visitors(tg_id INTEGER PRIMARY KEY,blocked INTEGER DEFAULT 0);
              CREATE TABLE action_logs(id INTEGER PRIMARY KEY,tg_id INTEGER,username TEXT,action TEXT,details TEXT,created_at TEXT);
              CREATE TABLE support_messages(id INTEGER PRIMARY KEY,tg_id INTEGER,message_text TEXT,admin_msg_id INTEGER,created_at TEXT);
              INSERT INTO support_messages VALUES(1,2,'Fixture question',9,'2026-01-01');
              INSERT INTO action_logs VALUES(1,2,'fixture','start','fixture','2026-01-01');
            ''')
        async def sender(target,payload,support): self.calls.append(('send',target,support,payload['text']))
        async def activate(uid,username,name,days):
            with closing(sqlite3.connect(self.path)) as db,db:
                db.execute("INSERT INTO users(tg_id,uuid,expires_at) VALUES(?,?,'2027-01-01')",(uid,f'fixture-{uid}'))
            self.calls.append(('give',uid,days))
        def delete(uid):
            with closing(sqlite3.connect(self.path)) as db,db:db.execute('DELETE FROM users WHERE tg_id=?',(uid,))
            self.calls.append(('delete',uid))
        access=SimpleNamespace(list_devices=lambda uuid:[{'id':11,'model':'Fixture phone','platform':'Android'}],
          blocked_devices=lambda uuid:[{'id':22,'model':'Fixture blocked'}],
          revoke_device=lambda uuid,device:self.calls.append(('revoke',uuid,device)) or True,
          allow_device=lambda uuid,device:self.calls.append(('allow',uuid,device)) or True)
        self.g={'get_stats':lambda:{'total':2},'get_funnel_stats':lambda hours:{'start':1},
          'get_user_ids':lambda audience:[1,2],'access':access,'activate_sub':activate,'delete_user':delete}
        self.admin=BotAdmin(self.f,self.g,sender)

    def prepare(self,action,**values):
        return self.admin.prepare(1,{'action':action,'reason':'Fixture reason',**values})

    async def finish(self,job):
        await self.admin.commit(1,job['id'])
        if self.admin.tasks: await asyncio.gather(*list(self.admin.tasks))

    def test_owner_required_every_read_and_preview_and_commit(self):
        for section in ('stats','funnel','logs','support','payments','user','jobs'):
            with self.assertRaises(DomainError): self.admin.read(2,section,{})
        with self.assertRaises(DomainError): self.admin.prepare(2,{'action':'backup','reason':'fixture'})
        with self.assertRaises(DomainError): asyncio.run(self.admin.commit(2,'fixture'))
        self.assertEqual(self.calls,[])

    def test_reads_use_existing_rows_and_parameterized_filters(self):
        self.assertEqual(self.admin.read(1,'logs',{'user_id':2})['rows'][0]['action'],'start')
        self.assertEqual(self.admin.read(1,'support',{})['rows'][0]['tg_id'],2)
        with self.assertRaises(DomainError): self.admin.read(1,'logs',{'user_id':'1 OR 1=1'})
        with self.assertRaises(DomainError): self.admin.read(1,'funnel',{'hours':1})

    def test_preview_sends_nothing_and_commit_once(self):
        job=self.prepare('broadcast',audience='all',text='Fixture announcement')
        self.assertEqual(self.calls,[])
        async def work():
            await self.finish(job); await self.finish(job)
        asyncio.run(work())
        self.assertEqual(len(self.calls),2)
        self.assertEqual(self.admin.read(1,'jobs',{})['rows'][0]['state'],'finished')

    def test_broadcast_snapshot_excludes_added_and_blocked_recipients(self):
        job=self.prepare('broadcast',audience='active',text='Fixture')
        self.g['get_user_ids']=lambda audience:[1,2,3]
        with closing(sqlite3.connect(self.path)) as db,db: db.execute('INSERT INTO visitors VALUES(2,1)')
        asyncio.run(self.finish(job))
        self.assertEqual([r[1] for r in self.calls],[1])

    def test_reply_target_comes_from_ticket_not_body(self):
        job=self.prepare('reply',ticket_id=1,user_id=999,text='Fixture reply')
        asyncio.run(self.finish(job))
        self.assertEqual(self.calls,[('send',2,True,'Fixture reply')])

    def test_deleted_or_modified_target_rejects_stale_preview(self):
        job=self.prepare('delete',user_id=2)
        with closing(sqlite3.connect(self.path)) as db,db: db.execute("UPDATE users SET expires_at='2029-01-01' WHERE tg_id=2")
        asyncio.run(self.finish(job))
        self.assertEqual(self.calls,[])
        self.assertEqual(self.admin.read(1,'jobs',{})['rows'][0]['state'],'failed')
        with self.assertRaises(DomainError): self.prepare('delete',user_id=1)

    def test_devices_are_scoped_and_existing_functions_called(self):
        with self.assertRaises(DomainError): self.prepare('allow',user_id=2,device_id=999)
        job=self.prepare('allow',user_id=2,device_id=22)
        asyncio.run(self.finish(job))
        self.assertEqual(self.calls,[('allow','fixture-2',22)])

    def test_unknown_user_grant_is_previewed_and_not_duplicated(self):
        with self.assertRaises(DomainError): self.prepare('give',user_id=2,days=30)
        job=self.prepare('give',user_id=3,days=30)
        self.assertEqual(self.calls,[])
        async def work(): await self.finish(job);await self.finish(job)
        asyncio.run(work())
        self.assertEqual(self.calls,[('give',3,30)])

    def test_separate_grant_jobs_for_same_user_are_reserved_atomically(self):
        jobs=[self.prepare('give',user_id=3,days=30) for _ in range(2)]
        original=self.g['activate_sub']
        async def work():
            entered=asyncio.Event();release=asyncio.Event()
            async def activate(*args):
                entered.set()
                await release.wait()
                await original(*args)
            self.g['activate_sub']=activate
            try:
                await self.admin.commit(1,jobs[0]['id'])
                await asyncio.wait_for(entered.wait(),2)
                with self.assertRaises(DomainError) as error:
                    await self.admin.commit(1,jobs[1]['id'])
                self.assertEqual(error.exception.code,'grant_reserved')
            finally:
                release.set()
                if self.admin.tasks: await asyncio.gather(*list(self.admin.tasks))
        asyncio.run(work())
        self.assertEqual(self.calls,[('give',3,30)])
        with self.assertRaises(DomainError): asyncio.run(self.admin.commit(1,jobs[1]['id']))

    def test_grant_reservation_survives_independent_adapter_and_restart(self):
        first=self.prepare('give',user_id=3,days=30)
        second=self.prepare('give',user_id=3,days=30)
        other=BotAdmin(self.f,self.g,self.admin.sender)
        self.assertIsNotNone(self.admin.claim(1,first['id']))
        with self.assertRaises(DomainError) as error: other.claim(1,second['id'])
        self.assertEqual(error.exception.code,'grant_reserved')
        restarted=BotAdmin(self.f,self.g,self.admin.sender)
        self.assertEqual(restarted.read(1,'jobs',{})['rows'][0]['state'],'preview')
        with self.assertRaises(DomainError): restarted.claim(1,second['id'])
        self.assertEqual(self.calls,[])

    def test_failed_grant_keeps_reservation_and_successful_deleted_user_can_be_recreated(self):
        first=self.prepare('give',user_id=3,days=30)
        original=self.g['activate_sub']
        async def fail(*args): raise RuntimeError('Fixture ambiguous activation failure')
        self.g['activate_sub']=fail
        asyncio.run(self.finish(first))
        second=self.prepare('give',user_id=3,days=30)
        with self.assertRaises(DomainError): asyncio.run(self.admin.commit(1,second['id']))
        self.g['activate_sub']=original
        successful=self.prepare('give',user_id=4,days=30)
        asyncio.run(self.finish(successful))
        self.g['delete_user'](4)
        replacement=self.prepare('give',user_id=4,days=7)
        asyncio.run(self.finish(replacement))
        self.assertEqual([r for r in self.calls if r[0]=='give'],[('give',4,30),('give',4,7)])

    def test_interrupted_jobs_not_replayed_and_expired_preview_rejected(self):
        job=self.prepare('backup')
        with closing(sqlite3.connect(self.path)) as db,db:db.execute("UPDATE app_admin_jobs SET state='running' WHERE id=?",(job['id'],))
        self.admin=BotAdmin(self.f,self.g,self.admin.sender)
        asyncio.run(self.finish(job))
        self.assertEqual(self.calls,[])
        self.assertEqual(self.admin.read(1,'jobs',{})['rows'][0]['state'],'interrupted')
        expired=self.prepare('backup')
        with closing(sqlite3.connect(self.path)) as db,db:db.execute("UPDATE app_admin_jobs SET expires='2000-01-01' WHERE id=?",(expired['id'],))
        with self.assertRaises(DomainError): asyncio.run(self.finish(expired))

    def test_bad_media_and_empty_message_rejected(self):
        for values in ({'text':''},{'text':'fixture','photo':'c2VjcmV0'},{'text':'a'*3501}):
            with self.assertRaises(DomainError):self.prepare('broadcast',audience='all',**values)

    def test_http_owner_guard_and_confirmation(self):
        async def work():
            from aiohttp import web
            from aiohttp.test_utils import TestClient,TestServer
            app=web.Application();self.admin.install_web(app)
            async with TestClient(TestServer(app)) as client:
                user={'Authorization':'Bearer '+self.fixture.session(2)}
                owner={'Authorization':'Bearer '+self.fixture.session(1)}
                for section in ('stats','funnel','logs','support','payments','user','jobs','prepare','commit','photo'):
                    route='/v1/app/admin/tools/'+section
                    self.assertEqual((await client.post(route,json={})).status,401)
                    self.assertEqual((await client.post(route,headers=user,json={'actor':1})).status,403)
                response=await client.post('/v1/app/admin/tools/prepare',headers=owner,json={'action':'reply','ticket_id':1,'text':'fixture','reason':'fixture'})
                self.assertEqual(response.status,200)
                job=await response.json();self.assertEqual(self.calls,[])
                for _ in range(2):self.assertEqual((await client.post('/v1/app/admin/tools/commit',headers=owner,json={'id':job['id']})).status,200)
                if self.admin.tasks: await asyncio.gather(*list(self.admin.tasks))
                self.assertEqual(len(self.calls),1)
        asyncio.run(work())

    def test_recent_group_matches_bot_ten_day_window(self):
        preview=self.f.store.preview(1,3,'Fixture reason',group_ids=['recent'])
        self.assertEqual([r['tg_id'] for r in preview['recipients']],[2])

    def photo_fixture(self, raw, metadata_size=None):
        with closing(sqlite3.connect(self.path)) as db,db:
            db.execute("INSERT OR REPLACE INTO app_support_photos VALUES(1,'fixture-file-id')")
        loop_thread=threading.get_ident()
        self.photo_calls=[]
        async def get_file(file_id):
            self.assertEqual(threading.get_ident(),loop_thread)
            self.photo_calls.append(('get_file',file_id))
            return SimpleNamespace(file_size=metadata_size,file_path='fixture-private-download-path')
        async def download_file(path,destination):
            self.assertEqual(threading.get_ident(),loop_thread)
            self.photo_calls.append(('download_file',path))
            for offset in range(0,len(raw),64): destination.write(raw[offset:offset+64])
        self.g['bot']=SimpleNamespace(get_file=get_file,download_file=download_file)

    @staticmethod
    def png(width=16,height=16):
        from PIL import Image
        with Image.new('RGB',(width,height),'purple') as image,io.BytesIO() as output:
            image.save(output,format='PNG')
            return output.getvalue()

    def test_photo_preview_is_owner_only_bounded_and_never_returns_download_path(self):
        self.photo_fixture(self.png(1200,32))
        with self.assertRaises(DomainError): asyncio.run(self.admin.photo(2,1))
        self.assertEqual(self.photo_calls,[])
        result=asyncio.run(self.admin.photo(1,1))
        from PIL import Image
        with Image.open(io.BytesIO(base64.b64decode(result['photo']))) as preview:
            self.assertEqual(preview.format,'JPEG')
            self.assertLessEqual(max(preview.size),1000)
        self.assertLessEqual(len(base64.b64decode(result['photo'])),600000)
        self.assertNotIn('fixture-private-download-path',str(result))

    def test_photo_stream_cap_does_not_trust_declared_size(self):
        raw=self.png(16,16)
        self.photo_fixture(raw,metadata_size=1)
        with patch('viora_control.bot_admin.MAX_PHOTO_BYTES',len(raw)-1,create=True):
            with self.assertRaises(DomainError) as error: asyncio.run(self.admin.photo(1,1))
        self.assertEqual(error.exception.status,413)

    def test_photo_pixel_bomb_is_rejected_before_decoding(self):
        # Valid PNG IHDR with a huge raster, without allocating huge image data.
        raw=self.png()
        ihdr=struct.pack('>IIBBBBB',8000,8000,8,2,0,0,0)
        raw=raw[:16]+ihdr+struct.pack('>I',zlib.crc32(b'IHDR'+ihdr))+raw[33:]
        self.photo_fixture(raw)
        with self.assertRaises(DomainError) as error: asyncio.run(self.admin.photo(1,1))
        self.assertEqual(error.exception.status,413)

    def test_photo_rejects_invalid_and_non_whitelisted_rasters(self):
        from PIL import Image
        with Image.new('RGB',(2,2),'purple') as image,io.BytesIO() as output:
            image.save(output,format='GIF')
            gif=output.getvalue()
        for raw in (b'not an image',gif):
            with self.subTest(raw=raw[:8]):
                self.photo_fixture(raw)
                with self.assertRaises(DomainError) as error: asyncio.run(self.admin.photo(1,1))
                self.assertEqual(error.exception.status,400)

    def test_photo_database_and_raster_work_leave_telegram_event_loop(self):
        self.photo_fixture(self.png())
        from PIL import Image
        original_open=Image.open
        original_connection=self.f.store.connection
        loop_thread=threading.get_ident();db_threads=[];image_threads=[]
        def connect():
            db_threads.append(threading.get_ident())
            return original_connection()
        def open_image(*args,**kwargs):
            image_threads.append(threading.get_ident())
            return original_open(*args,**kwargs)
        with patch.object(self.f.store,'connection',connect),patch.object(Image,'open',open_image):
            asyncio.run(self.admin.photo(1,1))
        self.assertTrue(db_threads and image_threads)
        self.assertNotIn(loop_thread,db_threads)
        self.assertNotIn(loop_thread,image_threads)

    def test_support_capture_and_broadcast_database_work_leave_event_loop(self):
        job=self.prepare('broadcast',audience='all',text='Fixture announcement')
        original_connection=self.f.store.connection
        loop_thread=threading.get_ident();db_threads=[]
        def connect():
            db_threads.append(threading.get_ident())
            return original_connection()
        message=SimpleNamespace(photo=[SimpleNamespace(file_id='fixture-photo')],from_user=SimpleNamespace(id=2))
        async def work():
            await self.admin.capture_support(message,SimpleNamespace(message_id=9))
            await self.finish(job)
        with patch.object(self.f.store,'connection',connect): asyncio.run(work())
        self.assertTrue(db_threads)
        self.assertNotIn(loop_thread,db_threads)

    def test_old_or_unknown_pillow_is_rejected_before_parsing_untrusted_photo(self):
        from PIL import Image
        for version in ('12.3.0','11.0.0','13.0.0.dev0','unknown'):
            with self.subTest(version=version),patch('PIL.__version__',version),patch.object(Image,'open') as decoder:
                with self.assertRaises(DomainError) as error: self.admin.photo_preview(b'untrusted fixture')
                self.assertEqual(error.exception.status,503)
                decoder.assert_not_called()
