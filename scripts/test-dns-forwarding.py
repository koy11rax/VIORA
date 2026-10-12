"""Exercise DNS handler A/AAAA and TCP using a synthetic core config only.

Requires the Dart-generated artifacts/android-dns-validation-fixture.json and
the pinned desktop core. HTTPS DNS uses the host network in this integration
check; it does not substitute for on-device VPN testing.
"""
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
config = json.loads((repo / 'artifacts/android-dns-validation-fixture.json').read_text(encoding='utf-8'))
assert config['outbounds'][0]['settings']['vnext'][0]['address'] == 'example.invalid', 'Synthetic fixture required'
with socket.socket() as reservation:
    reservation.bind(('127.0.0.1', 0))
    port = reservation.getsockname()[1]
config['inbounds'] = [{'tag': 'fixture-dns', 'listen': '127.0.0.1', 'port': port,
                       'protocol': 'dokodemo-door', 'settings': {
                           'address': '26.26.26.2', 'port': 53, 'network': 'udp,tcp'}}]
# Keep real DNS handler and routing, replacing the credential-bearing transport
# with a fixture freedom outbound so this check never touches a VPN account.
config['outbounds'][0] = {'tag': 'proxy', 'protocol': 'freedom', 'settings': {}}

def receive_exact(stream, count):
    result = b''
    while len(result) < count:
        part = stream.recv(count - len(result))
        if not part:
            raise AssertionError('DNS TCP connection closed early')
        result += part
    return result

def query(qtype, tcp=False):
    wire = struct.pack('!HHHHHH', 0x5649, 0x0100, 1, 0, 0, 0)
    wire += b'\x07example\x03org\x00' + struct.pack('!HH', qtype, 1)
    with socket.socket(type=socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as stream:
        stream.settimeout(15)
        stream.connect(('127.0.0.1', port))
        stream.sendall(struct.pack('!H', len(wire)) + wire if tcp else wire)
        response = receive_exact(stream, struct.unpack('!H', receive_exact(stream, 2))[0]) if tcp else stream.recv(4096)
    ident, flags, _, answers, _, _ = struct.unpack('!HHHHHH', response[:12])
    assert ident == 0x5649 and flags & 0x8000 and flags & 15 == 0, 'DNS response failed'
    assert answers > 0 if qtype == 1 else answers == 0, 'Unexpected DNS answer count'

with tempfile.TemporaryDirectory(prefix='viora-dns-fixture-') as directory:
    path = Path(directory) / 'config.json'
    path.write_text(json.dumps(config), encoding='utf-8')
    process = subprocess.Popen([str(repo / 'artifacts/desktop-core/windows/xray.exe'),
                                'run', '-config', str(path)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               creationflags=subprocess.CREATE_NO_WINDOW)
    try:
        for attempt in range(30):
            if process.poll() is not None:
                raise AssertionError('Fixture core stopped')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.1)
        query(1)
        query(28)
        query(1, tcp=True)
        print('DNS handler: UDP A and TCP A resolved via HTTPS; AAAA returned empty. Host-network fixture only.')
    finally:
        process.terminate()
        process.wait(timeout=10)
