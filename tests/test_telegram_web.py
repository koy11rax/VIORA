import importlib.util
import tempfile
import unittest
from pathlib import Path

from viora_control.telegram_auth import TelegramAuth, install_web_routes


@unittest.skipUnless(importlib.util.find_spec('aiohttp'), 'Install the bot aiohttp dependency to run HTTP integration checks')
class TelegramWebTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        from aiohttp import web
        from aiohttp.test_utils import TestClient, TestServer
        self.temp = tempfile.TemporaryDirectory()
        self.auth = TelegramAuth(Path(self.temp.name) / 'auth.sqlite', 'ExampleVioraBot', 77)
        app = web.Application()
        install_web_routes(app, self.auth, lambda actor: {'first_name': 'Test', 'id': 999, 'owner': True, 'devices': []})
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        self.temp.cleanup()

    async def test_end_to_end_and_roles_cannot_be_supplied_by_app(self):
        response = await self.client.get('/v1/app/account')
        self.assertEqual(response.status, 401)
        c = await (await self.client.post('/v1/app/auth/start', json={'id': 77, 'owner': True})).json()
        self.assertEqual((await self.client.post('/v1/app/auth/poll', json={'id': c['id'], 'poll_secret': 'x' * 43})).status, 401)
        self.auth.claim_from_telegram(c['id'], 88)
        self.auth.approve_from_telegram(c['id'], 88)
        session = await (await self.client.post('/v1/app/auth/poll', json={**c, 'actor': 77})).json()
        headers = {'Authorization': 'Bearer ' + session['session']}
        response = await self.client.get('/v1/app/account', headers=headers)
        me = await response.json()
        self.assertEqual(me['id'], 88)
        self.assertFalse(me['owner'])
        self.assertEqual(response.headers['Cache-Control'], 'no-store')
        self.assertEqual((await self.client.post('/v1/app/auth/logout', headers=headers, json={})).status, 200)
        self.assertEqual((await self.client.get('/v1/app/account', headers=headers)).status, 401)
        self.assertEqual((await self.client.post('/v1/app/auth/poll', json=c)).status, 410)
        self.assertEqual((await self.client.post('/v1/app/auth/start', data='x' * 4097)).status, 413)
        self.assertEqual((await self.client.post('/v1/app/auth/start', json=[])).status, 400)


if __name__ == '__main__': unittest.main()
