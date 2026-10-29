#!/usr/bin/env python3
"""Destructive networking checks for a disposable VM, never for a workstation."""
import contextlib
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import ssl
import subprocess
import sys
import threading
import time
import traceback
import urllib.request

APP = Path('/usr/lib/viora')
NS = 'viora-fixture-ns'
LINK = 'viora-fixture'
CA_TARGET = Path('/usr/local/share/ca-certificates/viora-isolated-fixture.crt')
UUID = '00000000-0000-4000-8000-000000000001'
WEB = 'viora-fixture-web.test'
PEER = '192.0.2.10'
WEB_IP = '198.51.100.10'
LOCAL_IP = '192.0.2.1'
CHILDREN = []
SESSIONS = []
RESULTS = []
DEFAULT_ROUTES = None
DEFAULT_ROUTES6 = None
EVIDENCE = None
PROBE = 0


def command(*args, check=True, timeout=30, **kw):
    return subprocess.run(args, check=check, timeout=timeout, capture_output=True, **kw)


def record(name, evidence):
    RESULTS.append({'name': name, 'passed': True, 'evidence': evidence})
    print(json.dumps(RESULTS[-1], ensure_ascii=False), flush=True)


def fixture_config(mode='all', strict=False):
    return {
        'log': {'loglevel': 'none'}, 'dns': {'servers': ['9.9.9.9']},
        'inbounds': [{'protocol': 'tun', 'settings': {'MTU': 1420}}],
        'desktop': {'appMode': mode, 'applications': ['linux:/usr/bin/curl'],
                    'strict': strict, 'reconnect': False, 'retries': 1},
        'outbounds': [
            {'tag': 'proxy', 'protocol': 'vless', 'settings': {'vnext': [
                {'address': PEER, 'port': 8443, 'users': [
                    {'id': UUID, 'encryption': 'none', 'level': 8}]}]},
             'streamSettings': {'network': 'ws', 'security': 'tls',
                                'tlsSettings': {'serverName': 'viora-fixture.test', 'fingerprint': 'chrome'},
                                'wsSettings': {'path': '/fixture'}}},
            {'tag': 'direct', 'protocol': 'freedom'}, {'tag': 'block', 'protocol': 'blackhole'}],
        'routing': {'rules': []}}


class Session:
    def __init__(self, mode='all', strict=False):
        self.events = []
        self.queue = queue.Queue()
        self.process = subprocess.Popen([str(APP/'viora_tunnel')], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LANG': 'C'})
        SESSIONS.append(self)

        def read():
            for line in self.process.stdout:
                with contextlib.suppress(ValueError):
                    item = json.loads(line)
                    self.events.append(item)
                    self.queue.put(item)
            self.queue.put({'state': 'EOF'})
        threading.Thread(target=read, daemon=True).start()
        self.process.stdin.write((json.dumps(fixture_config(mode, strict))+'\n').encode())
        self.process.stdin.flush()
        self.wait('CONNECTED', 45)
        self.capture_network()

    def capture_network(self):
        prefix = f'session-{len(SESSIONS):02d}'
        snapshots = [
            ('rules4.json', ['ip', '-4', '-N', '-j', 'rule', 'show']),
            ('rules6.json', ['ip', '-6', '-N', '-j', 'rule', 'show']),
            ('routes4.json', ['ip', '-4', '-N', '-j', 'route', 'show', 'table', 'all']),
            ('routes6.json', ['ip', '-6', '-N', '-j', 'route', 'show', 'table', 'all']),
            ('resolved.txt', ['resolvectl', 'status', 'viora0']),
            ('peer-routes.json', ['ip', '-n', NS, '-N', '-j', 'route', 'show', 'table', 'all']),
        ]
        for name, argv in snapshots:
            result = command(*argv, check=False)
            (EVIDENCE/f'{prefix}-{name}').write_bytes(result.stdout+result.stderr)
        result = command('ss', '-ntup', check=False)
        (EVIDENCE/f'{prefix}-sockets.txt').write_bytes(result.stdout+result.stderr)

    def wait(self, expected, timeout=20):
        deadline = time.monotonic()+timeout
        while time.monotonic() < deadline:
            item = self.queue.get(timeout=max(.1, deadline-time.monotonic()))
            if item['state'] == expected:
                return item
            if item['state'] in ('FAILED', 'EOF'):
                raise RuntimeError(f'Expected {expected}, received {item}')
        raise TimeoutError(expected)

    def wait_traffic(self):
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            event = self.queue.get(timeout=max(.1, deadline-time.monotonic()))
            if event['state'] == 'CONNECTED' and event.get('upload',0) > 0 and event.get('download',0) > 0:
                return event
            if event['state'] in ('FAILED','EOF','DISCONNECTED'):
                raise RuntimeError(f'traffic statistics interrupted: {event}')
        raise TimeoutError('actual upload/download counters did not update within 5s')

    def close(self):
        if self.process.poll() is None:
            with contextlib.suppress(BrokenPipeError):
                self.process.stdin.write(b'stop\n')
                self.process.stdin.flush()
            try:
                self.process.wait(15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(10)
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()
        if EVIDENCE is not None:
            (EVIDENCE/f'helper-{self.process.pid}-events.json').write_text(json.dumps(self.events, indent=2))


def curl_ip(directory, expect=None, literal=False):
    global PROBE
    PROBE += 1
    args = ['/usr/bin/curl', '-4', '--noproxy', '*', '--max-time', '20',
                     '--cacert', str(directory/'ca.crt'), '--silent', '--show-error',
                     '--verbose', '--trace-time', '--write-out', '%{stderr}\nVIORA_TIMING %{json}\n',
                     f'https://{WEB_IP if literal else WEB}/fixture']
    try:
        result = command(*args, check=False, timeout=35)
    except subprocess.TimeoutExpired as error:
        (directory/f'curl-{PROBE:02d}.stdout').write_bytes(error.stdout or b'')
        (directory/f'curl-{PROBE:02d}.stderr').write_bytes(error.stderr or b'')
        raise RuntimeError('curl exceeded outer 35s deadline; partial output preserved') from error
    (directory/f'curl-{PROBE:02d}.stdout').write_bytes(result.stdout)
    (directory/f'curl-{PROBE:02d}.stderr').write_bytes(result.stderr)
    if expect is None:
        assert result.returncode != 0, 'excluded curl unexpectedly escaped strict mode'
        return {'curl_exit': result.returncode}
    assert result.returncode == 0, f'HTTPS failed: {result.returncode} {result.stderr.decode()}'
    body = json.loads(result.stdout)
    assert body['client'] == expect, body
    return body


def python_ip(directory, literal=False):
    context = ssl.create_default_context(cafile=str(directory/'ca.crt'))
    # Ignore any environment proxy inherited from the build environment.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
    with opener.open(f'https://{WEB_IP if literal else WEB}/python-fixture', timeout=10) as response:
        return json.load(response)


def ipv6_probe(directory, expect_blocked):
    result = command('/usr/bin/curl', '-6', '--noproxy', '*', '--max-time', '5',
                     '--resolve', f'{WEB}:443:[2001:db8:2::10]',
                     '--cacert', str(directory/'ca.crt'), '--silent', '--show-error',
                     f'https://{WEB}/ipv6-fixture', check=False, timeout=10)
    if expect_blocked:
        assert result.returncode != 0, f'IPv6 escaped TUN: {result.stdout.decode()}'
        return {'blocked': True, 'curl_exit': result.returncode}
    assert result.returncode == 0, f'IPv6 fixture baseline unavailable: {result.stderr.decode()}'
    return json.loads(result.stdout)


def assert_clean():
    assert command('ip', 'link', 'show', 'viora0', check=False).returncode != 0, 'TUN remains'
    for family in ('-4', '-6'):
        rules = json.loads(command('ip', family, '-N', '-j', 'rule', 'show').stdout)
        assert not any(19000 <= row.get('priority', -1) <= 19020 or row.get('table') == 22089 for row in rules), rules


SERVER = r'''
import http.server,json,socket,ssl,struct,sys,threading
from pathlib import Path
p=Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  data=json.dumps({'client':self.client_address[0],'path':self.path}).encode()
  self.send_response(200);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def log_message(self,*args):pass
def dns():
 s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.bind(('9.9.9.9',53))
 while True:
  data,peer=s.recvfrom(4096)
  try:
   end=12
   while data[end]:end+=data[end]+1
   end+=1;qtype=struct.unpack('!H',data[end:end+2])[0];question=data[12:end+4]
   answer=(b'\xc0\x0c'+struct.pack('!HHIH',1,1,30,4)+socket.inet_aton('198.51.100.10')) if qtype==1 else b''
   packet=data[:2]+struct.pack('!HHHHH',0x8180,1,bool(answer),0,0)+question+answer;s.sendto(packet,peer)
  except (IndexError,struct.error):pass
threading.Thread(target=dns,daemon=True).start()
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(p/'server.crt',p/'server.key')
class IPv6Server(http.server.ThreadingHTTPServer):address_family=socket.AF_INET6
def serve(server):
 server.socket=ctx.wrap_socket(server.socket,server_side=True);server.serve_forever()
threading.Thread(target=serve,args=(IPv6Server(('2001:db8:2::10',443),Handler),),daemon=True).start()
serve(http.server.ThreadingHTTPServer(('198.51.100.10',443),Handler))
'''


def provision(directory):
    global DEFAULT_ROUTES, DEFAULT_ROUTES6
    command('ip', 'netns', 'add', NS)
    command('ip', 'link', 'add', LINK, 'type', 'veth', 'peer', 'name', 'fixture-peer')
    command('ip', 'link', 'set', 'fixture-peer', 'netns', NS)
    command('ip', 'address', 'add', '192.0.2.1/24', 'dev', LINK)
    command('ip', 'link', 'set', LINK, 'up')
    command('ip', '-n', NS, 'address', 'add', '192.0.2.10/24', 'dev', 'fixture-peer')
    command('ip', '-n', NS, 'link', 'set', 'fixture-peer', 'up')
    command('ip', '-n', NS, 'link', 'set', 'lo', 'up')
    command('ip', '-6', 'address', 'add', '2001:db8:1::1/64', 'dev', LINK, 'nodad')
    command('ip', '-n', NS, '-6', 'address', 'add', '2001:db8:1::2/64', 'dev', 'fixture-peer', 'nodad')
    command('ip', '-n', NS, '-6', 'address', 'add', '2001:db8:2::10/128', 'dev', 'lo', 'nodad')
    for address in ('198.51.100.10/32', '9.9.9.9/32'):
        command('ip', '-n', NS, 'address', 'add', address, 'dev', 'lo')
    # Preserve the exact original route attributes in iproute2's binary format.
    # A default (rather than host) route exercises TUN capture, while explicit
    # bind_interface direct sockets can still reach the namespace gateway.
    DEFAULT_ROUTES = command('ip', '-4', 'route', 'save', 'default').stdout
    command('ip', '-4', 'route', 'replace', 'default', 'via', PEER, 'dev', LINK, 'metric', '0')
    DEFAULT_ROUTES6 = command('ip', '-6', 'route', 'save', 'default').stdout
    command('ip', '-6', 'route', 'replace', 'default', 'via', '2001:db8:1::2', 'dev', LINK, 'metric', '1')
    # This CA is intentionally trusted only inside this disposable test VM.
    command('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=VIORA isolated fixture CA', '-keyout', str(directory/'ca.key'), '-out', str(directory/'ca.crt'))
    command('openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=viora-fixture.test',
            '-keyout', str(directory/'server.key'), '-out', str(directory/'server.csr'))
    (directory/'cert.ext').write_text('subjectAltName=DNS:viora-fixture.test,DNS:viora-fixture-web.test,IP:198.51.100.10\nextendedKeyUsage=serverAuth\n')
    command('openssl', 'x509', '-req', '-in', str(directory/'server.csr'), '-CA', str(directory/'ca.crt'),
            '-CAkey', str(directory/'ca.key'), '-CAcreateserial', '-days', '1', '-extfile', str(directory/'cert.ext'), '-out', str(directory/'server.crt'))
    shutil.copyfile(directory/'ca.crt', CA_TARGET)
    command('update-ca-certificates', timeout=60)
    server_config = {
        'log': {'loglevel': 'debug', 'access': str(directory/'xray-access.log')},
        # Sniffed TLS destinations may travel through VLESS as domain names.
        # The isolated namespace has no ambient system DNS, so make the server
        # resolver explicit too instead of accidentally relying on the guest.
        'dns': {'hosts': {WEB: WEB_IP}, 'servers': ['9.9.9.9']},
        'inbounds': [{'listen': PEER, 'port': 8443, 'protocol': 'vless',
                      'settings': {'clients': [{'id': UUID}], 'decryption': 'none'},
                      'streamSettings': {'network': 'ws', 'security': 'tls', 'wsSettings': {'path': '/fixture'},
                                         'tlsSettings': {'certificates': [{'certificateFile': str(directory/'server.crt'), 'keyFile': str(directory/'server.key')}]}}}],
        'outbounds': [{'protocol': 'freedom', 'tag': 'direct', 'settings': {
            'domainStrategy': 'UseIPv4',
            # Preserve upstream SSRF protections; allow only this isolated
            # namespace's exact HTTPS destination, never broad private ranges.
            'finalRules': [{'action': 'allow', 'network': 'tcp', 'port': 443,
                            'ip': [WEB_IP+'/32']}],
        }}]}
    (directory/'server.json').write_text(json.dumps(server_config))
    (directory/'server.py').write_text(SERVER)
    for name, argv in (
        ('https-dns', ['ip', 'netns', 'exec', NS, sys.executable, str(directory/'server.py'), str(directory)]),
        ('xray-server', ['ip', 'netns', 'exec', NS, str(APP/'core/xray'), 'run', '-config', str(directory/'server.json')])):
        log = (directory/f'{name}.log').open('wb')
        child = subprocess.Popen(argv, stdout=log, stderr=log)
        CHILDREN.append((child, log))
    time.sleep(3)
    for child, _ in CHILDREN:
        assert child.poll() is None, 'fixture server failed; see local logs'
    tcpdump = shutil.which('tcpdump')
    if tcpdump:
        log = (directory/'tcpdump.log').open('wb')
        capture = subprocess.Popen([tcpdump, '-U', '-nn', '-i', 'any', '-w', str(directory/'fixture-only.pcap'),
                                    'net 192.0.2.0/24 or host 198.51.100.10 or host 9.9.9.9 or host 172.29.255.2 or net 2001:db8::/32'], stdout=log, stderr=log)
        CHILDREN.append((capture, log))


def run_checks(directory):
    record('IPv6 fixture baseline is reachable before VPN', ipv6_probe(directory, False))
    for mode, expected in [('all', WEB_IP), ('only', WEB_IP), ('except', LOCAL_IP)]:
        session = Session(mode)
        record(f'{mode}: first IP-literal HTTPS works without application DNS', curl_ip(directory, expected, literal=True))
        record(f'{mode}: real DNS/TLS and process routing', curl_ip(directory, expected))
        if mode == 'all':
            record('real upload/download counters update', session.wait_traffic())
        record(f'{mode}: IPv6 cannot bypass configured block', ipv6_probe(directory, True))
        if mode == 'only':
            body = python_ip(directory)
            assert body['client'] == LOCAL_IP, body
            record('only: non-selected Python is direct', body)
        if mode == 'except':
            body = python_ip(directory)
            assert body['client'] == WEB_IP, body
            record('except: non-excluded Python is proxied', body)
        session.close()
        assert_clean()
        record(f'{mode}: disconnect cleanup', {'clean': True})
    session = Session()
    children = set()
    for task in Path(f'/proc/{session.process.pid}/task').iterdir():
        with contextlib.suppress(FileNotFoundError):
            children.update((task/'children').read_text().split())
    frontend = [int(pid) for pid in children if Path(f'/proc/{pid}/exe').resolve() == APP/'core/sing-box']
    assert len(frontend) == 1, 'frontend child identity not unique'
    os.kill(frontend[0], signal.SIGKILL)
    event = session.wait('FAILED', 20)
    assert event['code'] == 'frontend_exited', event
    session.close()
    assert_clean()
    record('frontend SIGKILL cleans owned kernel policy', event)
    session = Session()
    record('reconnect after frontend crash', curl_ip(directory, WEB_IP))
    session.close()
    assert_clean()
    session = Session('except', strict=True)
    record('strict protection blocks excluded IP-literal curl', curl_ip(directory,literal=True))
    body = python_ip(directory,literal=True)
    assert body['client'] == WEB_IP, body
    record('strict protection permits proxied traffic', body)
    session.close()
    assert_clean()
    ruleset = command('nft','-n','-j','list','ruleset',check=False)
    (directory/'strict-after-disconnect-nft.json').write_bytes(ruleset.stdout+ruleset.stderr)
    marker = Path('/var/lib/viora/protection.enabled')
    (directory/'strict-after-disconnect-marker.json').write_text(json.dumps({'exists':marker.exists(),'contents':marker.read_text() if marker.exists() else None}))
    status = command(str(APP/'viora_tunnel'), '--protection', 'status').stdout.decode().strip()
    assert status == 'ON', status
    record('strict protection remains armed after disconnect', {'state': status})
    record('persistent protection blocks IP-literal HTTPS with no TUN', curl_ip(directory,literal=True))
    # The application preference is deliberately false: already armed system
    # protection must still govern the next connection and its disconnection.
    session = Session('all', strict=False)
    record('VPN starts over already armed protection', curl_ip(directory,WEB_IP,literal=True))
    session.close()
    assert_clean()
    status = command(str(APP/'viora_tunnel'), '--protection', 'status').stdout.decode().strip()
    assert status == 'ON', status
    record('persistent protection survives another session', {'state':status})
    command(str(APP/'viora_tunnel'), '--protection', 'recover')
    status = command(str(APP/'viora_tunnel'), '--protection', 'status').stdout.decode().strip()
    assert status == 'OFF', status
    record('explicit recovery removes only test protection', {'state': status})
    record('direct IP-literal HTTPS returns only after explicit recovery', curl_ip(directory,LOCAL_IP,literal=True))


def main():
    global EVIDENCE
    if os.geteuid() != 0 or os.environ.get('VIORA_ISOLATED_VM') != '1' or not Path('/run/viora-isolated-test').is_file():
        raise SystemExit('REFUSED: disposable VM marker, explicit opt-in and root are all required')
    if os.path.lexists('/var/lib/viora/protection.enabled') or os.path.lexists(CA_TARGET):
        raise SystemExit('REFUSED: existing user protection or fixture CA must not be changed')
    namespaces = command('ip', 'netns', 'list').stdout.decode().splitlines()
    if any(line.split() and line.split()[0] == NS for line in namespaces):
        raise SystemExit('REFUSED: an existing namespace must not be changed')
    if command('nft', '-j', 'list', 'table', 'inet', 'viora_lockdown', check=False).returncode == 0:
        raise SystemExit('REFUSED: an existing firewall policy must not be changed')
    if command('ip', 'link', 'show', 'viora0', check=False).returncode == 0 or command('ip', 'link', 'show', LINK, check=False).returncode == 0:
        raise SystemExit('REFUSED: an existing VPN/fixture interface must not be changed')
    directory = Path(sys.argv[1]).resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    EVIDENCE = directory
    passed = False
    try:
        provision(directory)
        run_checks(directory)
        passed = True
    except Exception as error:
        RESULTS.append({'passed': False, 'error': str(error), 'traceback': traceback.format_exc()})
        print(json.dumps(RESULTS[-1]), flush=True)
    finally:
        for session in SESSIONS:
            with contextlib.suppress(Exception): session.close()
        # No pre-existing protection was allowed by the initial gate.
        with contextlib.suppress(Exception): command(str(APP/'viora_tunnel'), '--protection', 'recover')
        for child, log in CHILDREN:
            with contextlib.suppress(Exception): child.terminate(); child.wait(5)
            with contextlib.suppress(Exception): child.kill(); child.wait(5)
            log.close()
        command('ip', '-4', 'route', 'del', 'default', 'via', PEER, 'dev', LINK, 'metric', '0', check=False)
        if DEFAULT_ROUTES is not None:
            command('ip', '-4', 'route', 'restore', input=DEFAULT_ROUTES, check=False)
        command('ip', '-6', 'route', 'del', 'default', 'via', '2001:db8:1::2', 'dev', LINK, 'metric', '1', check=False)
        if DEFAULT_ROUTES6 is not None:
            command('ip', '-6', 'route', 'restore', input=DEFAULT_ROUTES6, check=False)
        command('ip', 'link', 'del', LINK, check=False)
        command('ip', 'netns', 'delete', NS, check=False)
        if CA_TARGET.exists():
            CA_TARGET.unlink()
            command('update-ca-certificates', check=False, timeout=60)
        for name in ('ca.key', 'server.key', 'server.csr', 'server.json'):
            (directory/name).unlink(missing_ok=True)
        (directory/'report.json').write_text(json.dumps({'passed': passed, 'checks': RESULTS}, ensure_ascii=False, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
