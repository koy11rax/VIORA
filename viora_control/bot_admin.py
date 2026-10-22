"""Owner-only adapters for the existing bot. No Telegram sends during preview.

Delivery is at-most-once: an interrupted external send is reported as uncertain,
never automatically replayed. All Telegram I/O stays on the bot event loop.
"""
import asyncio
import base64
import io
import json
import re
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path
from .store import DomainError, instant, stamp


MAX_PHOTO_BYTES = 10_000_000
MAX_PHOTO_PIXELS = 16_000_000


class _BoundedPhoto(io.BytesIO):
    """Bound received bytes even when Telegram metadata omits/misreports size."""
    def write(self, data):
        if self.tell() + len(data) > MAX_PHOTO_BYTES:
            raise DomainError('photo','Фото слишком большое',413)
        return super().write(data)


class BotAdmin:
    def __init__(self, features, bot_globals, sender=None):
        self.features = features
        self.store = features.store
        self.g = bot_globals
        self.sender = sender or self.send
        self.tasks = set()
        self.broadcast_lock = bot_globals.get('broadcast_lock',asyncio.Lock())
        with self.store.connection() as db:
            db.executescript('''
              CREATE TABLE IF NOT EXISTS app_admin_jobs(
                id TEXT PRIMARY KEY, actor INTEGER NOT NULL, action TEXT NOT NULL,
                payload TEXT NOT NULL, created TEXT NOT NULL, expires TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'preview', result TEXT);
              CREATE TABLE IF NOT EXISTS app_admin_deliveries(
                job TEXT NOT NULL, target INTEGER NOT NULL, state TEXT NOT NULL,
                PRIMARY KEY(job,target));
              CREATE TABLE IF NOT EXISTS app_support_photos(
                ticket INTEGER PRIMARY KEY,file_id TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS app_admin_grant_reservations(
                user_id INTEGER PRIMARY KEY,job TEXT NOT NULL UNIQUE);
            ''')
            db.execute("UPDATE app_admin_jobs SET state='interrupted',result=? WHERE state IN ('queued','running')",
                       (json.dumps({'message':'Сервер перезапущен. Выполнение не повторяется автоматически.'}),))

    def owner(self, actor):
        self.store.authorize(actor)

    @staticmethod
    def uid(value):
        if type(value) is not int or not 0 < value < 2**52:
            raise DomainError('user','Укажи корректный Telegram ID')
        return value

    def user(self, uid):
        with self.store.connection() as db:
            row=db.execute('SELECT tg_id,username,first_name,uuid,expires_at FROM users WHERE tg_id=?',(uid,)).fetchone()
        if not row: raise DomainError('user','Пользователь не найден',404)
        return dict(row)

    def read(self, actor, section, data):
        self.owner(actor)
        if section == 'stats': return {'stats':self.g['get_stats']()}
        if section == 'funnel':
            hours=data.get('hours',24)
            if type(hours) is not int or hours not in (24,168,720): raise DomainError('period','Некорректный период')
            return {'hours':hours,'funnel':self.g['get_funnel_stats'](hours)}
        if section in ('logs','support','payments'):
            uid=data.get('user_id')
            if uid is not None: self.uid(uid)
            page=data.get('page',0)
            if type(page) is not int or not 0<=page<=10000: raise DomainError('page','Некорректная страница')
            columns={'logs':'tg_id,username,action,details,created_at',
                     'support':'id,tg_id,message_text,admin_msg_id,created_at',
                     'payments':'id,tg_id,method,tariff,amount,currency,created_at'}
            tables={'logs':'action_logs','support':'support_messages','payments':'payments_log'}
            query=f"SELECT {columns[section]} FROM {tables[section]}"
            params=[]
            if uid is not None: query+=' WHERE tg_id=?';params.append(uid)
            query+=' ORDER BY rowid DESC LIMIT 11 OFFSET ?';params.append(page*10)
            with self.store.connection() as db: rows=[dict(r) for r in db.execute(query,params)]
            if section=='support':
                with self.store.connection() as db:
                    for row in rows:
                        row['photo']=bool(db.execute('SELECT 1 FROM app_support_photos WHERE ticket=?',(row['id'],)).fetchone())
            return {'rows':rows[:10],'page':page,'more':len(rows)>10}
        if section == 'user':
            uid=self.uid(data.get('user_id')); user=self.user(uid)
            account=self.features.account_reader(uid) if self.features.account_reader else {}
            devices=self.g['access'].list_devices(user['uuid'])
            blocked=self.g['access'].blocked_devices(user['uuid'])
            return {'user':{k:v for k,v in user.items() if k!='uuid'},
                    'subscription_url':account.get('subscription_url'),
                    'devices':devices,'blocked':blocked}
        if section == 'jobs':
            with self.store.connection() as db:
                rows=[dict(r) for r in db.execute('SELECT id,action,created,state,result,payload FROM app_admin_jobs WHERE actor=? ORDER BY created DESC LIMIT 50',(actor,))]
            for r in rows:
                r['result']=json.loads(r['result']) if r['result'] else None
                r['reason']=json.loads(r.pop('payload')).get('reason','')
            return {'rows':rows}
        raise DomainError('section','Раздел не найден',404)

    def prepare(self, actor, data):
        self.owner(actor)
        action=data.get('action'); payload={}
        labels={'broadcast':'Рассылка','reply':'Ответ поддержки','delete':'Удаление подписки',
                'revoke':'Отвязка устройства','allow':'Разрешение устройства',
                'give':'Выдача подписки новому пользователю','backup':'Резервная копия'}
        if action not in labels: raise DomainError('action','Неизвестное действие')
        reason=data.get('reason','')
        if not isinstance(reason,str) or not 3<=len(reason.strip())<=500:
            raise DomainError('reason','Укажи причину: 3–500 символов')
        payload['reason']=reason.strip()
        summary=[]
        if action in ('broadcast','reply'):
            text=data.get('text',''); photo=data.get('photo')
            if not isinstance(text,str) or len(text)>3500: raise DomainError('text','Текст: до 3500 символов')
            if photo is not None:
                if not isinstance(photo,str) or len(photo)>800000: raise DomainError('photo','Фото слишком большое')
                try: raw=base64.b64decode(photo,validate=True)
                except ValueError: raise DomainError('photo','Некорректное фото')
                if not (raw.startswith(b'\xff\xd8\xff') or raw.startswith(b'\x89PNG\r\n\x1a\n')):
                    raise DomainError('photo','Выбери JPEG или PNG')
                if len(text)>900: raise DomainError('text','Подпись к фото: до 900 символов')
                payload['photo']=photo
            if not text.strip() and not photo: raise DomainError('text','Добавь текст или фото')
            payload['text']=text
            # Plain text avoids importing untrusted Telegram markup/entities.
            if action=='broadcast':
                audience=data.get('audience')
                if audience not in ('all','active','expired'): raise DomainError('audience','Выбери аудиторию')
                targets=sorted(set(self.g['get_user_ids'](audience)))
                if not targets or len(targets)>10000: raise DomainError('audience','Аудитория пуста или превышает 10000')
                payload.update(audience=audience,targets=targets)
                summary=[f'Получателей: {len(targets)}',text or 'Фото без подписи']
            else:
                ticket=self.uid(data.get('ticket_id'))
                with self.store.connection() as db:
                    row=db.execute('SELECT tg_id,message_text FROM support_messages WHERE id=?',(ticket,)).fetchone()
                if not row: raise DomainError('ticket','Обращение не найдено',404)
                payload.update(ticket_id=ticket,target=row['tg_id'])
                summary=[f"Пользователь: {row['tg_id']}",text or 'Фото без подписи']
        elif action in ('delete','revoke','allow','give'):
            uid=self.uid(data.get('user_id'));payload['user_id']=uid
            if action=='give':
                days=data.get('days')
                if type(days) is not int or not 1<=days<=3650: raise DomainError('days','Укажи 1–3650 дней')
                with self.store.connection() as db:
                    exists=db.execute('SELECT 1 FROM users WHERE tg_id=?',(uid,)).fetchone()
                if exists: raise DomainError('exists','Пользователь уже есть. Используй выдачу дней в списке пользователей.',409)
                payload['days']=days;summary=[f'Telegram ID: {uid}',f'Новая подписка: {days} дней']
            else:
                user=self.user(uid);payload.update(uuid=user['uuid'],expiry=user['expires_at'])
                summary=[f"{user['first_name'] or user['username'] or 'Пользователь'} · {uid}"]
                if action=='delete':
                    if uid==actor: raise DomainError('self','Нельзя удалить подписку владельца')
                    summary+=['Подписка будет удалена, доступ VPN отозван. История оплат и действий сохранится.']
                else:
                    device=self.uid(data.get('device_id'))
                    rows=self.g['access'].blocked_devices(user['uuid']) if action=='allow' else self.g['access'].list_devices(user['uuid'])
                    row=next((r for r in rows if r['id']==device),None)
                    if not row: raise DomainError('device','Устройство не найдено',404)
                    payload['device_id']=device;summary+=[f"Устройство {device}: {row.get('model') or row.get('platform') or 'Без названия'}"]
        else: summary=['Создать согласованную копию базы бота и отправить только владельцу в Telegram.']
        now=self.store.clock();job=secrets.token_urlsafe(24)
        with self.store.connection() as db:
            db.execute("DELETE FROM app_admin_jobs WHERE state='preview' AND expires<?",(stamp(now),))
            db.execute('INSERT INTO app_admin_jobs(id,actor,action,payload,created,expires) VALUES(?,?,?,?,?,?)',
                       (job,actor,action,json.dumps(payload),stamp(now),stamp(now+timedelta(minutes=5))))
        return {'id':job,'title':labels[action],'summary':summary,'reason':reason.strip(),'expires_at':stamp(now+timedelta(minutes=5))}

    def claim(self, actor, job):
        self.owner(actor)
        if not isinstance(job,str) or len(job)>100: raise DomainError('job','Некорректное подтверждение')
        with self.store.connection() as db:
            db.execute('BEGIN IMMEDIATE')
            row=db.execute('SELECT * FROM app_admin_jobs WHERE id=? AND actor=?',(job,actor)).fetchone()
            if not row: raise DomainError('job','Подтверждение не найдено',404)
            if row['state']!='preview': return None
            if instant(row['expires'])<=self.store.clock(): raise DomainError('expired','Подтверждение истекло',409)
            if row['action']=='give':
                user_id=json.loads(row['payload'])['user_id']
                if db.execute('SELECT 1 FROM users WHERE tg_id=?',(user_id,)).fetchone():
                    raise DomainError('stale','Пользователь уже создан. Проверь подписку.',409)
                reservation=db.execute('''SELECT j.state FROM app_admin_grant_reservations r
                    LEFT JOIN app_admin_jobs j ON j.id=r.job WHERE r.user_id=?''',(user_id,)).fetchone()
                if reservation:
                    if reservation['state']!='finished':
                        # A cancelled/crashed callback can have external effects. Keep
                        # its durable reservation until explicitly reconciled; never
                        # automatically repeat a potentially completed grant.
                        raise DomainError('grant_reserved','Выдача этому пользователю уже принята. Проверь журнал и подписку перед повтором.',409)
                    # A previously successful subscription may later be deliberately
                    # deleted. A new preview can then create it again.
                    db.execute('DELETE FROM app_admin_grant_reservations WHERE user_id=?',(user_id,))
                db.execute('INSERT INTO app_admin_grant_reservations VALUES(?,?)',(user_id,job))
            db.execute("UPDATE app_admin_jobs SET state='queued' WHERE id=?",(job,))
        return dict(row)

    async def commit(self, actor, job):
        row=await asyncio.to_thread(self.claim,actor,job)
        if row:
            task=asyncio.create_task(self.execute(row));self.tasks.add(task)
            task.add_done_callback(self.tasks.discard)
        return {'id':job,'message':'Задание принято. Результат — в журнале операций.'}

    def state(self, job, state, result=None):
        with self.store.connection() as db:
            db.execute('UPDATE app_admin_jobs SET state=?,result=? WHERE id=?',(state,json.dumps(result,ensure_ascii=False) if result else None,job))

    def delivery(self, job, target, state=None):
        with self.store.connection() as db:
            if state is None:
                return db.execute("INSERT OR IGNORE INTO app_admin_deliveries VALUES(?,?,'sending')",(job,target)).rowcount==1
            db.execute('UPDATE app_admin_deliveries SET state=? WHERE job=? AND target=?',(state,job,target))

    def blocked(self, target):
        with self.store.connection() as db:
            return bool(db.execute('SELECT 1 FROM visitors WHERE tg_id=? AND blocked=1',(target,)).fetchone())

    async def send(self, target, payload, support=False):
        from aiogram.types import BufferedInputFile
        text=('💬 Ответ поддержки Viora\n\n' if support else '')+payload['text']
        if payload.get('photo'):
            await self.g['bot'].send_photo(target,BufferedInputFile(base64.b64decode(payload['photo']),filename='viora.jpg'),caption=text,parse_mode=None)
        else: await self.g['bot'].send_message(target,text,parse_mode=None)

    async def execute(self, row):
        job=row['id'];action=row['action'];p=json.loads(row['payload'])
        await asyncio.to_thread(self.state,job,'running')
        locked=False
        try:
            result={}
            if action in ('broadcast','reply'):
                if action=='broadcast':
                    if self.broadcast_lock.locked(): raise DomainError('busy','Другая рассылка уже выполняется',409)
                    await self.broadcast_lock.acquire();locked=True
                    eligible=set(await asyncio.to_thread(self.g['get_user_ids'],p['audience']))
                targets=p['targets'] if action=='broadcast' else [p['target']]
                sent=failed=skipped=0
                for target in targets:
                    # Honor a subsequent opt-out/block without expanding preview recipients.
                    if action=='broadcast':
                        blocked=await asyncio.to_thread(self.blocked,target)
                        if target not in eligible or blocked: skipped+=1;continue
                    if not await asyncio.to_thread(self.delivery,job,target): skipped+=1;continue
                    status='uncertain'
                    try:
                        await self.sender(target,p,action=='reply');sent+=1;status='sent'
                    except Exception as error:
                        # No retry after an ambiguous network failure: prevent double sends.
                        failed+=1;status='blocked' if type(error).__name__=='TelegramForbiddenError' else 'uncertain'
                    await asyncio.to_thread(self.delivery,job,target,status)
                    if action=='broadcast': await asyncio.sleep(.08)
                result={'sent':sent,'failed_or_uncertain':failed,'skipped':skipped}
            elif action in ('delete','revoke','allow'):
                user=await asyncio.to_thread(self.user,p['user_id'])
                if user['uuid']!=p['uuid'] or user['expires_at']!=p['expiry']:
                    raise DomainError('stale','Подписка изменилась. Создай подтверждение заново.',409)
                if action=='delete': await asyncio.to_thread(self.g['delete_user'],p['user_id'])
                else:
                    fn=self.g['access'].allow_device if action=='allow' else self.g['access'].revoke_device
                    changed=await asyncio.to_thread(fn,p['uuid'],p['device_id'])
                    if not changed: raise DomainError('stale','Устройство уже изменилось. Обнови список.',409)
                result={'message':'Действие выполнено'}
            elif action=='give':
                if await asyncio.to_thread(self.user_exists,p['user_id']):
                    raise DomainError('stale','Пользователь уже создан. Проверь подписку.',409)
                await self.g['activate_sub'](p['user_id'],None,None,p['days'])
                if self.g.get('gen_subscription_url'):
                    await asyncio.to_thread(self.g['gen_subscription_url'],p['user_id'])
                result={'message':'Подписка создана','access_sync':'pending'}
                try:
                    await asyncio.to_thread(self.features.sync)
                    result['access_sync']='applied'
                except Exception: pass # Existing minute loop retries durable access.
            elif action=='backup':
                from aiogram.types import FSInputFile
                name=f"app_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}_{job[:6]}.db"
                path=Path(self.g['BACKUP_DIR'])/name
                await asyncio.to_thread(self.g['sqlite_backup'],str(path))
                if Path(self.g['access'].DEVICE_DB).exists():
                    bundle=path.with_suffix('.zip')
                    await asyncio.to_thread(self.g['access'].backup_bundle,str(path),str(bundle))
                    path=bundle;name=path.name
                await self.g['bot'].send_document(row['actor'],FSInputFile(path),caption='Резервная копия Viora · запрос из приложения')
                result={'message':'Копия отправлена владельцу в Telegram','name':name}
            await asyncio.to_thread(self.state,job,'finished',result)
        except Exception as error:
            message=str(error) if isinstance(error,DomainError) else 'Не удалось завершить действие. Проверь состояние перед повтором.'
            await asyncio.to_thread(self.state,job,'failed',{'message':message})
        finally:
            if locked: self.broadcast_lock.release()

    def user_exists(self, user_id):
        with self.store.connection() as db:
            return bool(db.execute('SELECT 1 FROM users WHERE tg_id=?',(user_id,)).fetchone())

    def record_support_photo(self, user_id, message_id, file_id):
        with self.store.connection() as db:
            row=db.execute('SELECT id FROM support_messages WHERE tg_id=? AND admin_msg_id=? ORDER BY id DESC LIMIT 1',
                           (user_id,message_id)).fetchone()
            if row: db.execute('INSERT OR REPLACE INTO app_support_photos VALUES(?,?)',(row[0],file_id))

    async def capture_support(self, message, sent):
        if not message.photo: return
        await asyncio.to_thread(self.record_support_photo,message.from_user.id,sent.message_id,message.photo[-1].file_id)

    def support_photo_id(self, ticket):
        with self.store.connection() as db:
            row=db.execute('SELECT file_id FROM app_support_photos WHERE ticket=?',(ticket,)).fetchone()
        if not row: raise DomainError('photo','Фото отсутствует. Старые вложения доступны в Telegram.',404)
        return row[0]

    @staticmethod
    def photo_preview(raw):
        """Run bounded raster decoding off the bot loop, without global PIL settings."""
        from PIL import Image, UnidentifiedImageError, __version__
        # CVE-2026-112403 reaches JPEG draft decoding via thumbnail even for
        # dimensions below our cap. Reject old/unknown decoders before opening
        # untrusted bytes; fixed Pillow preserves the normal JPEG/PNG feature.
        release=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:\.post\d+)?',__version__)
        if not release or tuple(map(int,release.groups()))<(13,0,0):
            raise DomainError('photo_decoder','Для просмотра фото обнови серверный компонент по requirements-control.txt.',503)
        if len(raw)>MAX_PHOTO_BYTES: raise DomainError('photo','Фото слишком большое',413)
        try:
            with io.BytesIO(raw) as source, Image.open(source,formats=('JPEG','PNG')) as image:
                width,height=image.size
                if width>8192 or height>8192 or width*height>MAX_PHOTO_PIXELS:
                    raise DomainError('photo','Разрешение фото слишком большое',413)
                # thumbnail triggers decoding only after the raster dimensions pass.
                image.thumbnail((1000,1000))
                with image.convert('RGB') as rgb, io.BytesIO() as out:
                    rgb.save(out,format='JPEG',quality=65)
                    if out.tell()>600000: raise DomainError('photo','Фото слишком большое',413)
                    return {'photo':base64.b64encode(out.getvalue()).decode()}
        except Image.DecompressionBombError:
            raise DomainError('photo','Разрешение фото слишком большое',413) from None
        except (UnidentifiedImageError,OSError,ValueError):
            raise DomainError('photo','Выбери корректное фото JPEG или PNG',400) from None

    async def photo(self, actor, ticket):
        self.owner(actor);self.uid(ticket)
        file_id=await asyncio.to_thread(self.support_photo_id,ticket)
        file=await asyncio.wait_for(self.g['bot'].get_file(file_id),15)
        if (file.file_size or 0)>MAX_PHOTO_BYTES: raise DomainError('photo','Фото слишком большое',413)
        # Telegram I/O belongs on its event loop. Only SQLite and raster work
        # move to workers; the download destination enforces a streaming cap.
        with _BoundedPhoto() as target:
            await asyncio.wait_for(self.g['bot'].download_file(file.file_path,destination=target),30)
            return await asyncio.to_thread(self.photo_preview,target.getvalue())

    def install_web(self, app):
        from aiohttp import web
        async def endpoint(request):
            try:
                actor=await asyncio.to_thread(self.features.auth.actor,request.headers.get('Authorization',''))
                self.owner(actor)
                raw=bytearray()
                async def read_body():
                    async for chunk in request.content.iter_chunked(8192):
                        raw.extend(chunk)
                        if len(raw)>850000: raise DomainError('body','Запрос слишком большой',413)
                await asyncio.wait_for(read_body(),15)
                data=json.loads(raw or b'{}')
                if not isinstance(data,dict): raise ValueError()
                section=request.match_info['section']
                if section=='photo': result=await self.photo(actor,data.get('ticket_id'))
                elif section=='prepare': result=await asyncio.to_thread(self.prepare,actor,data)
                elif section=='commit': result=await self.commit(actor,data.get('id'))
                else: result=await asyncio.to_thread(self.read,actor,section,data)
                return web.json_response(result,headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})
            except (DomainError,ValueError,TypeError) as error:
                return web.json_response({'message':str(error) if isinstance(error,DomainError) else 'Некорректный запрос'},status=getattr(error,'status',400),headers={'Cache-Control':'no-store'})
            except Exception as error:
                from .telegram_auth import AuthError
                return web.json_response({'message':'Сеанс недействителен' if isinstance(error,AuthError) else 'Сервис временно недоступен'},status=error.status if isinstance(error,AuthError) else 503,headers={'Cache-Control':'no-store'})
        app.router.add_post('/v1/app/admin/tools/{section}',endpoint)
