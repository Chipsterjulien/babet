#!/usr/bin/env python3
"""Local two-CA trust contracts for HTTPS, downloads, TLS, STARTTLS and WSS."""
from contextlib import ExitStack
from pathlib import Path
import base64
import hashlib
import json
import os
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading


LUA = r'''
local run_source=[==[
return function(kind, cfg, suffix)
    local count=0
    local function check(label, server, policy, expected, wrong_name)
        local port=cfg.ports[server]
        local opts={timeout=5,verify=true}
        if policy=='file' then opts.ca_cert=cfg.ca
        elseif policy=='path' then opts.ca_path=cfg.ca_path
        elseif policy=='empty' then opts.ca_cert='' end
        if kind~='http' and kind~='download' then
            opts.hostname=wrong_name and 'wrong.invalid' or 'localhost'
        end
        -- Leaf certificates have a DNS localhost SAN, never an IP SAN.
        local host=wrong_name and '127.0.0.1' or 'localhost'
        local url='https://'..host..':'..port..'/'
        local value,err
        if kind=='http' then
            value,err=babet.http.get(url,opts)
            if value then assert(value.status==200 and value.body==server) end
        elseif kind=='download' then
            local destination=cfg.output..suffix
            os.remove(destination)
            value,err=babet.http.download(url,destination,opts)
            if value then
                assert(value.status==200 and value.saved)
                local f=assert(io.open(destination,'rb'))
                assert(f:read('*a')==server);f:close();assert(os.remove(destination))
            else
                local f=io.open(destination,'rb')
                if f then f:close();error('rejected download published a file') end
            end
        elseif kind=='wss' then
            value,err=babet.websocket.connect('wss://127.0.0.1:'..port..'/',opts)
            if value then
                local message=assert(value:recv())
                assert(message.type=='text' and message.data==server)
                assert(value:close())
            end
        else
            if kind=='tls' then value,err=babet.socket.connect_tls('127.0.0.1',port,opts)
            else
                local sock=assert(babet.socket.connect('127.0.0.1',port,5))
                value,err=sock:starttls(opts)
                if value then value=sock else sock:close() end
            end
            if value then
                assert(value:send('TLS\n'));assert(value:recv_line()==server);value:close()
            end
        end
        assert((value~=nil)==expected,kind..'/'..label..': '..tostring(err))
        if not expected then
            local lower=tostring(err):lower()
            assert(lower:find('certificate') or lower:find('verification') or lower:find('verify'),
                   kind..'/'..label..': expected verification error, got '..tostring(err))
        end
        count=count+1
    end
    check('default accepts A','A','default',true)
    check('default rejects B','B','default',false)
    check('explicit B accepts B','B','file',true)
    check('explicit B and default A','A','file',kind~='http' and kind~='download')
    check('explicit B does not leak to next call','B','default',false)
    check('second certificate under B','B2','file',true)
    check('hostname still checked','B','file',false,true)
    check('empty ca_cert accepts default A','A','empty',true)
    check('empty ca_cert rejects B','B','empty',false)
    if kind~='http' and kind~='download' then
        check('ca_path accepts B','B','path',true)
        check('ca_path retains A','A','path',true)
        check('ca_path does not leak to next call','B','default',false)
    end
    return count
end
]==]
local run=assert(load(run_source))()
local f=assert(loadfile(arg[1]));local cfg=f()
local kinds={'http','download','tls','starttls','wss'}
local total=0
for _,kind in ipairs(kinds) do total=total+run(kind,cfg,'main') end
assert(total==54)
local jobs={}
for _,kind in ipairs(kinds) do
    jobs[#jobs+1]=assert(babet.workers.spawn(
        'local run=assert(load(worker.args.source))()\nreturn run(worker.args.kind,worker.args.cfg,worker.args.kind)',
        {kind=kind,cfg=cfg,source=run_source}))
end
for _,job in ipairs(jobs) do
    local ok,n=job:join(30);assert(ok,tostring(n));total=total+n
end
assert(total==108)
print('CA trust contracts: 108 PASS / 0 FAIL')
'''


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = False

    def __init__(self, cert, key, label):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(cert, key)
        self.label = label.encode()
        self.failures = []
        self.successes = 0
        super().__init__(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.serve_forever, kwargs={'poll_interval': 0.05})
        self.thread.start()

    def close(self):
        self.shutdown()
        self.thread.join(10)
        self.server_close()
        if self.thread.is_alive() or self.failures:
            raise AssertionError(f'server {self.label!r}: {self.failures}')
        if not self.successes:
            raise AssertionError(f'server {self.label!r} never served a verified client')


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(8)
        try:
            connection = self.server.context.wrap_socket(self.request, server_side=True)
        except ssl.SSLError:
            # Unknown CA / hostname rejection is an expected matrix outcome.
            return
        try:
            with connection:
                request = b''
                while b'\r\n\r\n' not in request and request != b'TLS\n':
                    data = connection.recv(4096)
                    if not data:
                        return  # A client may reject identity after the handshake.
                    request += data
                    if len(request) > 16384:
                        raise AssertionError('oversized request')
                if request == b'TLS\n':
                    connection.sendall(self.server.label+b'\n')
                elif b'sec-websocket-key:' in request.lower():
                    headers = {}
                    for line in request.split(b'\r\n')[1:]:
                        if b':' in line:
                            key, value = line.split(b':',1)
                            headers[key.strip().lower()] = value.strip()
                    key = headers[b'sec-websocket-key']
                    accept = base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
                    connection.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
                    connection.sendall(bytes([0x81,len(self.server.label)])+self.server.label)
                    def exact(size):
                        data = b''
                        while len(data) < size:
                            part = connection.recv(size-len(data))
                            if not part:
                                raise AssertionError('truncated WebSocket close')
                            data += part
                        return data

                    close = exact(2)
                    if close[0] != 0x88 or not close[1] & 0x80 or close[1] & 0x7f > 125:
                        raise AssertionError('missing WebSocket close')
                    exact(4+(close[1] & 0x7f))  # Mask plus bounded close payload.
                    connection.sendall(b'\x88\x02\x03\xe8')
                else:
                    connection.sendall(b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: '+str(len(self.server.label)).encode()+b'\r\n\r\n'+self.server.label)
                self.server.successes += 1
        except (ssl.SSLError, ConnectionResetError, BrokenPipeError):
            # A client can complete the wire handshake, then reject the peer.
            pass
        except Exception as error:
            self.server.failures.append(repr(error))


def command(args, **kwargs):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True,
                            timeout=60, **kwargs)
    if result.returncode:
        raise AssertionError(f'{args}: exit={result.returncode}\n{result.stdout}{result.stderr}')
    return result.stdout


def certificate(root, name, ca=None):
    key, cert = root/(name+'.key'), root/(name+'.pem')
    if ca is None:
        command(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','2',
                 '-subj','/CN=Babet Test CA '+name,'-keyout',key,'-out',cert,
                 '-addext','basicConstraints=critical,CA:TRUE',
                 '-addext','keyUsage=critical,keyCertSign,cRLSign'])
    else:
        request, extensions = root/(name+'.csr'), root/(name+'.ext')
        command(['openssl','req','-new','-newkey','rsa:2048','-nodes',
                 '-subj','/CN=localhost','-keyout',key,'-out',request])
        extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n')
        command(['openssl','x509','-req','-in',request,'-CA',root/(ca+'.pem'),
                 '-CAkey',root/(ca+'.key'),'-CAcreateserial','-days','2','-out',cert,
                 '-extfile',extensions])
    return cert, key


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: test_ca_trust.py /path/to/babet')
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='babet-ca-trust-') as tmp, ExitStack() as cleanup:
        root = Path(tmp)
        certificate(root,'CA_A'); certificate(root,'CA_B')
        empty = root/'empty'; empty.mkdir()
        ca_path = root/'ca-directory'; ca_path.mkdir()
        ca_hash = command(['openssl','x509','-in',root/'CA_B.pem','-noout','-hash']).strip()
        (ca_path/(ca_hash+'.0')).write_bytes((root/'CA_B.pem').read_bytes())
        ports = {}
        for label, ca in [('A','CA_A'),('B','CA_B'),('B2','CA_B')]:
            cert,key = certificate(root,label,ca)
            server = Server(cert,key,label); cleanup.callback(server.close)
            ports[label] = server.server_address[1]
        project = root/'project'; project.mkdir()
        (project/'main.lua').write_text(LUA)
        config = root/'config.lua'
        quote = lambda value: json.dumps(str(value),ensure_ascii=False)
        config.write_text('return {ports={'+','.join(k+'='+str(v) for k,v in ports.items())+'},ca='+quote(root/'CA_B.pem')+',ca_path='+quote(ca_path)+',output='+quote(root/'download-')+'}\n')
        # Fresh processes see A as default trust. No host CA store is edited.
        env = dict(os.environ, SSL_CERT_FILE=str(root/'CA_A.pem'), SSL_CERT_DIR=str(empty))
        app = root/'application'; command([binary,'--create-exe',project,app],cwd=root,env=env)
        for mode, args in [('file',[binary,project/'main.lua']),('folder',[binary,project]),('embedded',[app])]:
            output = command([*args,config],cwd=root,env=env)
            if 'CA trust contracts: 108 PASS / 0 FAIL' not in output:
                raise AssertionError(f'{mode}: missing completion marker\n{output}')
            print(f'[PASS] {mode}: 54 main + 54 concurrent-worker CA/identity contracts',flush=True)
    print('CA trust runtime: 324 PASS / 0 FAIL',flush=True)


if __name__ == '__main__':
    try:
        main()
    except (AssertionError,OSError,subprocess.SubprocessError) as error:
        print(f'[FAIL] CA trust: {error}',file=sys.stderr)
        raise SystemExit(1)
