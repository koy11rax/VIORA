import json
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from viora_control.api import Sessions, handler_for
from viora_control.store import Store


class ApiTest(unittest.TestCase):
    def test_http_auth_and_group_grant(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(Path(tmp) / 'api.sqlite', 77)
            store.seed_development()
            sessions = Sessions(store)
            owner, user = sessions.issue_trusted(77), sessions.issue_trusted(88)
            server = ThreadingHTTPServer(('127.0.0.1', 0), handler_for(store))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f'http://127.0.0.1:{server.server_port}'

            def request(path, token='', data=None):
                req = Request(base + path, headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'},
                              data=None if data is None else json.dumps(data).encode())
                try:
                    with urlopen(req) as response:
                        return response.status, json.load(response)
                except HTTPError as error:
                    return error.code, json.load(error)

            try:
                self.assertEqual(request('/v1/admin/users')[0], 401)
                self.assertEqual(request('/v1/admin/users', user)[0], 403)
                self.assertEqual(request('/v1/me', user)[1]['owner'], False)
                group = request('/v1/admin/groups', owner, {'name': 'Друзья', 'user_ids': [1001, 1002]})[1]
                status, preview = request('/v1/admin/grants/preview', owner,
                                          {'days': 7, 'reason': 'Подарок', 'group_ids': [group['id']], 'user_ids': [1001]})
                self.assertEqual(status, 200)
                self.assertEqual(preview['count'], 2)
                for _ in range(2):
                    status, result = request('/v1/admin/grants/commit', owner, {'preview_id': preview['preview_id']})
                    self.assertEqual(status, 200)
                    self.assertEqual(result['access_sync'], 'pending')
                self.assertEqual(len(request('/v1/admin/audit', owner)[1]), 2)
                self.assertEqual(request('/v1/admin/grants/commit', owner, {})[0], 400)
                self.assertEqual(request('/v1/admin/groups', owner, [77])[0], 400)
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == '__main__':
    unittest.main()
