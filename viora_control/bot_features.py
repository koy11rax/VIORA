"""Production account operations. Explicit bot DB, authenticated actors, no broadcasts."""
import asyncio
import json
import secrets
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from .store import Store, DomainError, instant, stamp
from .telegram_auth import AuthError


class BotStore(Store):
    """Uses the existing bot's naive UTC timestamps; never creates another user DB."""
    def __init__(self, path, owner_id):
        self.path = str(Path(path).resolve())
        self.owner_id = owner_id
        self.clock = lambda: datetime.now(timezone.utc)
        with self.connection() as db:
            # Fail on a wrong DB, rather than silently creating user/payment tables.
            db.execute('SELECT tg_id,expires_at,uuid FROM users LIMIT 0')
            db.execute('SELECT id,status FROM sbp_payments LIMIT 0')
            db.executescript('''
                CREATE TABLE IF NOT EXISTS app_groups(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE);
                CREATE TABLE IF NOT EXISTS app_group_members(group_id TEXT,user_id INTEGER,PRIMARY KEY(group_id,user_id));
                CREATE TABLE IF NOT EXISTS app_grant_previews(id TEXT PRIMARY KEY,actor INTEGER,days INTEGER,reason TEXT,recipients TEXT,expires TEXT,result TEXT);
                CREATE TABLE IF NOT EXISTS app_grant_audit(id INTEGER PRIMARY KEY,batch TEXT,actor INTEGER,user_id INTEGER,days INTEGER,before_expiry TEXT,after_expiry TEXT,reason TEXT,created_at TEXT);
                CREATE TABLE IF NOT EXISTS app_orders(request_id TEXT PRIMARY KEY,actor INTEGER,payment_id INTEGER UNIQUE,submitted INTEGER NOT NULL DEFAULT 0);
            ''')

    @contextmanager
    def connection(self):
        db = sqlite3.connect(Path(self.path).as_uri()+'?mode=rw',uri=True,timeout=15)
        db.row_factory = sqlite3.Row
        try:
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    def groups(self, actor):
        self.authorize(actor)
        with self.connection() as db:
            return [dict(r) for r in db.execute('SELECT g.id,g.name,COUNT(m.user_id) AS count FROM app_groups g LEFT JOIN app_group_members m ON m.group_id=g.id GROUP BY g.id ORDER BY g.name')]

    def create_group(self, actor, name, user_ids):
        self.authorize(actor)
        if not isinstance(name,str) or not 1<=len(name.strip())<=80:
            raise DomainError('name','Название группы: 1–80 символов')
        ids=self.validate_ids(user_ids)
        if not ids: raise DomainError('empty','Выбери участников')
        gid=secrets.token_urlsafe(16)
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self.require_users(db,ids)
            try: db.execute('INSERT INTO app_groups VALUES(?,?)',(gid,name.strip()))
            except sqlite3.IntegrityError: raise DomainError('duplicate','Группа уже существует',409)
            db.executemany('INSERT INTO app_group_members VALUES(?,?)',[(gid,i) for i in ids])
        return {'id':gid,'name':name.strip(),'count':len(ids)}

    def preview(self, actor, days, reason, user_ids=None, group_ids=None):
        self.authorize(actor)
        if type(days) is not int or not 1<=days<=3650: raise DomainError('days','Укажи 1–3650 дней')
        if not isinstance(reason,str) or not 3<=len(reason.strip())<=500: raise DomainError('reason','Укажи причину: 3–500 символов')
        ids=set(self.validate_ids(user_ids or []))
        groups=group_ids or []
        if not isinstance(groups,list) or len(groups)>100 or any(not isinstance(g,str) for g in groups): raise DomainError('groups','Некорректные группы')
        now=self.clock()
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            for gid in set(groups):
                if gid in ('all','active','expired','recent'):
                    for row in db.execute('SELECT tg_id,expires_at FROM users'):
                        active=bool(instant(row['expires_at']) and instant(row['expires_at'])>now)
                        expiry=instant(row['expires_at'])
                        if gid=='all' or (gid=='recent' and expiry and now-timedelta(days=10)<=expiry<=now) or (gid in ('active','expired') and active==(gid=='active')): ids.add(row['tg_id'])
                else:
                    if not db.execute('SELECT 1 FROM app_groups WHERE id=?',(gid,)).fetchone(): raise DomainError('group','Группа не найдена',404)
                    ids.update(r[0] for r in db.execute('SELECT user_id FROM app_group_members WHERE group_id=?',(gid,)))
            if not ids or len(ids)>10000: raise DomainError('selection','Выбери 1–10000 получателей')
            self.require_users(db,sorted(ids))
            rows=[dict(db.execute('SELECT tg_id,first_name,expires_at FROM users WHERE tg_id=?',(uid,)).fetchone()) for uid in sorted(ids)]
            recipients=[r|{'after_expiry':stamp(max(instant(r['expires_at']) or now,now)+timedelta(days=days))} for r in rows]
            pid=secrets.token_urlsafe(24); expires=stamp(now+timedelta(minutes=5))
            db.execute('DELETE FROM app_grant_previews WHERE expires<? AND result IS NULL',(stamp(now),))
            db.execute('INSERT INTO app_grant_previews VALUES(?,?,?,?,?,?,NULL)',(pid,actor,days,reason.strip(),json.dumps(rows),expires))
        return {'preview_id':pid,'days':days,'reason':reason.strip(),'expires_at':expires,'count':len(rows),'recipients':recipients}

    def commit(self, actor, preview_id):
        self.authorize(actor)
        if not isinstance(preview_id,str) or len(preview_id)>128: raise DomainError('preview','Неверный предпросмотр')
        now=self.clock()
        with self.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            p=db.execute('SELECT * FROM app_grant_previews WHERE id=? AND actor=?',(preview_id,actor)).fetchone()
            if not p: raise DomainError('preview','Предпросмотр не найден',404)
            if p['result']: return json.loads(p['result'])
            if instant(p['expires'])<=now: raise DomainError('expired','Предпросмотр истёк',409)
            rows=json.loads(p['recipients'])
            for r in rows:
                current=db.execute('SELECT expires_at FROM users WHERE tg_id=?',(r['tg_id'],)).fetchone()
                if not current or current[0]!=r['expires_at']: raise DomainError('stale','Подписки изменились. Проверь список заново.',409)
            for r in rows:
                expiry=max(instant(r['expires_at']) or now,now)+timedelta(days=p['days'])
                # Bot handlers use naive UTC datetime.now(); keep their storage convention.
                value=expiry.replace(tzinfo=None).isoformat()
                db.execute('UPDATE users SET expires_at=?,notif_3d=0,notif_1d=0,notif_1h=0,reminder_sent_expiry=NULL WHERE tg_id=?',(value,r['tg_id']))
                db.execute('INSERT INTO app_grant_audit(batch,actor,user_id,days,before_expiry,after_expiry,reason,created_at) VALUES(?,?,?,?,?,?,?,?)',(preview_id,actor,r['tg_id'],p['days'],r['expires_at'],value,p['reason'],stamp(now)))
            result={'count':len(rows),'access_sync':'ожидает фоновой синхронизации (до минуты)','batch_id':preview_id}
            db.execute('UPDATE app_grant_previews SET result=? WHERE id=?',(json.dumps(result),preview_id))
        return result

    def events(self, actor):
        self.authorize(actor)
        with self.connection() as db:
            return [dict(r) for r in db.execute('SELECT * FROM app_grant_audit ORDER BY id DESC LIMIT 200')]


class BotFeatures:
    def __init__(self, auth, users_path, tariffs, requisites, settle, sync, account_reader=None, revoke_device=None, notify_payment=None):
        self.auth=auth
        self.store=BotStore(users_path,auth.owner_id)
        self.tariffs=tariffs
        self.requisites=requisites
        self.settle=settle
        self.sync=sync
        self.account_reader=account_reader
        self.revoke_device=revoke_device
        self.notify_payment=notify_payment

    def devices(self, actor):
        if self.account_reader is None: raise DomainError('unavailable','Управление устройствами временно недоступно',503)
        account=self.account_reader(actor)
        return {'devices':account.get('devices',[]),'limit':account.get('device_limit',3)}

    def revoke(self, actor, data):
        device_id=data.get('id')
        if type(device_id) is not int or device_id<=0: raise DomainError('id','Неверное устройство')
        if self.revoke_device is None: raise DomainError('unavailable','Управление устройствами временно недоступно',503)
        # Derive the subscription from the verified actor, never from the body.
        with self.store.connection() as db:
            user=db.execute('SELECT uuid FROM users WHERE tg_id=?',(actor,)).fetchone()
        if not user or not user['uuid']: raise DomainError('user','Подписка не найдена',404)
        own=self.devices(actor)
        if not any(d['id']==device_id for d in own['devices']): raise DomainError('device','Устройство не найдено',404)
        sync='applied'
        try: self.revoke_device(user['uuid'],device_id)
        except Exception:
            # Existing access layer durably revokes before syncing Xray. Only
            # report pending when the read confirms that revocation was saved.
            if any(d['id']==device_id for d in self.devices(actor)['devices']): raise
            sync='pending'
        return self.devices(actor)|{'access_sync':sync}

    def renewals(self, actor):
        with self.store.connection() as db:
            orders=[dict(r) for r in db.execute('SELECT p.id,p.tariff,p.amount,p.status,p.created_at,COALESCE(a.submitted,0) AS submitted FROM sbp_payments p LEFT JOIN app_orders a ON a.payment_id=p.id WHERE p.tg_id=? ORDER BY p.id DESC LIMIT 20',(actor,))]
        return {'tariffs':[{'id':k,'name':v['name'],'days':v['days'],'rub':v['rub']} for k,v in self.tariffs.items()], 'orders':orders,'requisites':self.requisites}

    def order(self, actor, data):
        tariff=data.get('tariff'); request=data.get('request_id')
        if tariff not in self.tariffs or not isinstance(request,str) or not 16<=len(request)<=80: raise DomainError('order','Некорректная заявка')
        with self.store.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            self.store.require_users(db,[actor])
            old=db.execute('SELECT actor,payment_id FROM app_orders WHERE request_id=?',(request,)).fetchone()
            if old:
                if old['actor']!=actor: raise DomainError('order','Заявка недоступна',403)
                return {'id':old['payment_id']}
            pending=db.execute("SELECT id FROM sbp_payments WHERE tg_id=? AND tariff=? AND status='pending' ORDER BY id DESC LIMIT 1",(actor,tariff)).fetchone()
            if pending: pid=pending['id']
            else:
                pid=db.execute("INSERT INTO sbp_payments(tg_id,tariff,amount,status,created_at) VALUES(?,?,?,'pending',?)",(actor,tariff,self.tariffs[tariff]['rub'],datetime.utcnow().isoformat())).lastrowid
            # One durable request ID per existing bot payment.
            db.execute('INSERT OR IGNORE INTO app_orders(request_id,actor,payment_id) VALUES(?,?,?)',(request,actor,pid))
        return {'id':pid}

    def submit(self, actor, pid):
        if type(pid) is not int: raise DomainError('id','Неверная заявка')
        with self.store.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row=db.execute('SELECT tg_id,status FROM sbp_payments WHERE id=?',(pid,)).fetchone()
            if not row or row['tg_id']!=actor: raise DomainError('order','Заявка не найдена',404)
            if row['status']!='pending': raise DomainError('processed','Заявка уже обработана',409)
            db.execute('INSERT OR IGNORE INTO app_orders(request_id,actor,payment_id,submitted) VALUES(?,?,?,1)',(secrets.token_urlsafe(24),actor,pid))
            db.execute('UPDATE app_orders SET submitted=1 WHERE payment_id=? AND actor=?',(pid,actor))
        return {'status':'submitted'}

    def overview(self, actor):
        self.store.authorize(actor)
        with self.store.connection() as db:
            pending=[dict(r) for r in db.execute("SELECT p.id,p.tg_id,p.tariff,p.amount,p.status,u.first_name,COALESCE(a.submitted,0) AS submitted FROM sbp_payments p LEFT JOIN users u ON u.tg_id=p.tg_id LEFT JOIN app_orders a ON a.payment_id=p.id WHERE p.status='pending' ORDER BY p.id DESC LIMIT 100")]
            totals=[dict(r) for r in db.execute('SELECT currency,SUM(amount) AS amount,COUNT(*) AS count FROM payments_log GROUP BY currency')]
        users=self.store.users(actor)
        return {'users':len(users),'active':sum(u['active'] for u in users),'pending':pending,'totals':totals}

    def reject(self, actor, pid):
        self.store.authorize(actor)
        if type(pid) is not int: raise DomainError('id','Неверная заявка')
        with self.store.connection() as db:
            db.execute("UPDATE sbp_payments SET status='rejected' WHERE id=? AND status='pending'",(pid,))
        return {'status':'processed'}

    def install_web(self, app):
        from aiohttp import web
        async def endpoint(request):
            try:
                actor=await asyncio.to_thread(self.auth.actor,request.headers.get('Authorization',''))
                path=request.path.removeprefix('/v1/app/')
                if path.startswith('admin/') or path=='me': self.store.authorize(actor)
                data={}
                if request.method=='POST':
                    async def bounded():
                        raw=bytearray()
                        async for chunk in request.content.iter_chunked(4096):
                            raw.extend(chunk)
                            if len(raw)>4096: raise DomainError('body','Запрос слишком большой',413)
                        return raw
                    raw=await asyncio.wait_for(bounded(),15)
                    data=json.loads(raw)
                    if not isinstance(data,dict): raise ValueError()
                async def call(fn,*args): return await asyncio.to_thread(fn,*args)
                if path=='me': result={'owner':True}
                elif path=='renewal': result=await call(self.renewals,actor)
                elif path=='devices': result=await call(self.devices,actor)
                elif path=='devices/revoke': result=await call(self.revoke,actor,data)
                elif path=='orders': result=await call(self.order,actor,data)
                elif path=='orders/submit':
                    result=await call(self.submit,actor,data.get('id'))
                    if self.notify_payment is not None:
                        result['admin_notification']=await self.notify_payment(data.get('id'),actor)
                elif path=='admin/overview': result=await call(self.overview,actor)
                elif path=='admin/users': result=await call(self.store.users,actor)
                elif path=='admin/groups': result=await call(self.store.groups,actor) if request.method=='GET' else await call(self.store.create_group,actor,data.get('name'),data.get('user_ids'))
                elif path=='admin/audit': result=await call(self.store.events,actor)
                elif path=='admin/grants/preview': result=await call(self.store.preview,actor,data.get('days'),data.get('reason'),data.get('user_ids'),data.get('group_ids'))
                elif path=='admin/grants/commit':
                    result=await call(self.store.commit,actor,data.get('preview_id'))
                    try:
                        await call(self.sync)
                        result=result|{'access_sync':'применено'}
                    except Exception: pass # Durable expiry remains; existing bot retries every minute.
                elif path=='admin/orders/reject': result=await call(self.reject,actor,data.get('id'))
                elif path=='admin/orders/approve':
                    pid=data.get('id')
                    if type(pid) is not int: raise ValueError()
                    paid=await call(self.settle,pid) # Existing bot transaction, duplicate-payment protection and ledger.
                    result={'status':'approved' if paid else 'already_processed','access_sync':'ожидает синхронизации'}
                    try:
                        await call(self.sync)
                        result['access_sync']='применено'
                    except Exception: pass
                else: raise DomainError('route','Раздел не найден',404)
                return web.json_response(result,headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})
            except (DomainError,AuthError) as error:
                return web.json_response({'message':str(error)},status=error.status,headers={'Cache-Control':'no-store'})
            except (ValueError,TypeError): return web.json_response({'message':'Некорректный запрос'},status=400)
            except Exception: return web.json_response({'message':'Сервис временно недоступен'},status=503)
        for path in ('me','renewal','devices','admin/overview','admin/users','admin/groups','admin/audit'):
            app.router.add_get('/v1/app/'+path,endpoint)
        for path in ('orders','orders/submit','devices/revoke','admin/groups','admin/grants/preview','admin/grants/commit','admin/orders/approve','admin/orders/reject'):
            app.router.add_post('/v1/app/'+path,endpoint)
