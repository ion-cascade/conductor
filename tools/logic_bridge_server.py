#!/usr/bin/env python3
"""Owner-only multi-client MCP broker with one serialized upstream Logic session.

A disconnected client never cancels or replays an attempted UI action. Upstream
failure closes clients; reconnect must acquire fresh references in a new session.
"""
import fcntl, json, os, queue, select, signal, socket, stat, subprocess, sys, tempfile, threading, time
from pathlib import Path

MAX_LINE = 2 * 1024 * 1024
MAX_CLIENTS = 16

class Broker:
    def __init__(self, child):
        self.child = child
        self.requests = queue.Queue(maxsize=64)
        self.responses = queue.Queue(maxsize=64)
        self.clients = {}
        self.lock = threading.RLock()
        self.input_lock = threading.Lock()
        self.active = None
        self.initialization = None
        self.stopped = threading.Event()
        threading.Thread(target=self.read_upstream, daemon=True).start()
        threading.Thread(target=self.dispatch, daemon=True).start()

    def drop(self, conn):
        with self.lock:
            self.clients.pop(conn, None)
        try: conn.shutdown(socket.SHUT_RDWR)
        except OSError: pass
        conn.close()

    def emit(self, conn, obj):
        with self.lock: state = self.clients.get(conn)
        if state is None: return
        try:
            with state['write_lock']:
                data = (json.dumps(obj, separators=(',', ':'))+'\n').encode()
                deadline = time.monotonic()+5
                while data:
                    remaining = deadline-time.monotonic()
                    if remaining <= 0 or not select.select([], [conn], [], remaining)[1]:
                        raise OSError('client did not drain its response')
                    try: sent = conn.send(data, socket.MSG_DONTWAIT)
                    except BlockingIOError: continue
                    if sent == 0: raise OSError('client closed')
                    data = data[sent:]
        except OSError: self.drop(conn)

    def error(self, conn, ident, message, code=-32001):
        self.emit(conn, dict(jsonrpc='2.0', id=ident, error=dict(code=code, message=message)))

    def send(self, obj):
        with self.input_lock:
            data = memoryview((json.dumps(obj, separators=(',', ':'))+'\n').encode())
            while data:
                sent = self.child.stdin.write(data)
                if not sent: raise OSError('upstream stdin closed')
                data = data[sent:]
            self.child.stdin.flush()

    def read_upstream(self):
        try:
            while not self.stopped.is_set():
                line = self.child.stdout.readline(8 * MAX_LINE + 1)
                if not line: break
                if len(line) > 8 * MAX_LINE: raise ValueError('upstream response too large')
                if not line.strip(): continue
                obj = json.loads(line)
                if 'method' in obj:
                    if 'id' in obj:
                        self.send(dict(jsonrpc='2.0', id=obj['id'], error=dict(code=-32601, message='bridge advertises no client callbacks')))
                    else:
                        with self.lock: peers = [c for c,s in self.clients.items() if s['initialized']]
                        for peer in peers: self.emit(peer, obj)
                else: self.responses.put(obj, timeout=5)
        except (OSError, ValueError, queue.Full): pass
        finally:
            self.stopped.set()
            with self.lock: peers = list(self.clients)
            for peer in peers: self.drop(peer)

    def dispatch(self):
        sequence = 0
        try:
            while not self.stopped.is_set():
                try: conn, request = self.requests.get(timeout=.25)
                except queue.Empty: continue
                with self.lock:
                    if conn not in self.clients: continue
                if request['method'] == 'initialize' and self.initialization is not None:
                    protocol, result = self.initialization
                    if request.get('params', {}).get('protocolVersion') != protocol:
                        self.error(conn, request['id'], 'bridge protocol differs from active session', -32602)
                    else:
                        with self.lock:
                            if conn in self.clients: self.clients[conn]['initialized'] = True
                        self.emit(conn, dict(result, id=request['id']))
                    continue
                sequence += 1
                upstream_id = 'broker_'+str(sequence)
                forwarded = dict(request, id=upstream_id)
                if request['method'] == 'initialize':
                    forwarded['params'] = dict(request.get('params', {}), capabilities={})
                with self.lock:
                    state = self.clients.get(conn)
                    if state is None: continue
                    if request['id'] in state['cancelled']:
                        state['cancelled'].discard(request['id'])
                        self.error(conn, request['id'], 'request cancelled before dispatch; no action sent', -32800)
                        continue
                    self.active = (conn, request['id'], upstream_id)
                self.send(forwarded)
                while not self.stopped.is_set():
                    try: response = self.responses.get(timeout=.25)
                    except queue.Empty: continue
                    if response.get('id') != upstream_id: continue
                    if request['method'] == 'initialize' and 'result' in response:
                        self.initialization = (request.get('params', {}).get('protocolVersion'), response)
                        with self.lock:
                            if conn in self.clients: self.clients[conn]['initialized'] = True
                        self.send(dict(jsonrpc='2.0', method='notifications/initialized'))
                    self.emit(conn, dict(response, id=request['id']))
                    break
                with self.lock: self.active = None
        except (OSError, ValueError): self.stopped.set()

    def client(self, conn):
        try:
            stream = conn.makefile('rb')
            while not self.stopped.is_set():
                line = stream.readline(MAX_LINE+1)
                if not line or len(line) > MAX_LINE: break
                try:
                    request = json.loads(line)
                    if not isinstance(request, dict) or not isinstance(request.get('method'), str): raise ValueError()
                    if 'id' in request and (isinstance(request['id'], bool) or not isinstance(request['id'], (int, str))): raise ValueError()
                except (ValueError, UnicodeDecodeError):
                    self.error(conn, None, 'invalid JSON-RPC request', -32600)
                    continue
                method = request['method']
                if 'id' not in request:
                    with self.lock: active = self.active
                    if method == 'notifications/cancelled':
                        ident = request.get('params', {}).get('requestId')
                        if not isinstance(ident, (int, str)): continue
                        if active is not None and active[0] is conn and ident == active[1]:
                            self.send(dict(request, params=dict(request['params'], requestId=active[2])))
                        else:
                            with self.lock:
                                state = self.clients.get(conn)
                                if state is not None:
                                    if len(state['cancelled']) < 64: state['cancelled'].add(ident)
                    continue
                with self.lock: initialized = self.clients.get(conn, {}).get('initialized', False)
                if not initialized and method != 'initialize':
                    self.error(conn, request['id'], 'initialize this client before calling the server')
                    continue
                try: self.requests.put_nowait((conn, request))
                except queue.Full: self.error(conn, request['id'], 'bridge queue full; request was not sent')
        except OSError: pass
        finally: self.drop(conn)

    def accept(self, conn):
        with self.lock:
            if len(self.clients) >= MAX_CLIENTS:
                conn.close(); return
            self.clients[conn] = dict(initialized=False, write_lock=threading.Lock(), cancelled=set())
        threading.Thread(target=self.client, args=(conn,), daemon=True).start()

    def close(self):
        self.stopped.set()
        with self.lock: peers = list(self.clients)
        for peer in peers: self.drop(peer)


def main():
    root = Path(os.environ.get('LOGIC_MCP_BRIDGE_DIR', str(Path.home()/'Library/Application Support/Logic MCP Bridge')))
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink() or root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o077:
        raise SystemExit('bridge directory must be owned by user and inaccessible to others')
    with (root / 'bridge.lock').open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('another bridge already owns this directory')
        serve_locked(root)


def serve_locked(root):
    path = root / 'bridge.sock'
    pid_path = root / 'bridge.pid'
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise SystemExit('refusing to replace non-owned socket path')
        path.unlink()
    pid_path.unlink(missing_ok=True)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        old = os.umask(0o177)
        try:
            server.bind(str(path))
        finally:
            os.umask(old)
        process = None
        broker = None
        try:
            os.chmod(path, 0o600)
            server.listen(MAX_CLIENTS)
            server.settimeout(.25)
            executable = Path(os.environ.get(
                'LOGIC_MCP_EXECUTABLE', str(Path.home() / 'Projects/logic-pro-mcp/local-bin/LogicProMCP')))
            process = subprocess.Popen(
                [str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=sys.stderr, bufsize=0, env=dict(os.environ, LOGIC_PRO_BUNDLE_ID='com.apple.logic10'))
            broker = Broker(process)
            signal.signal(signal.SIGTERM, lambda *_: broker.stopped.set())
            signal.signal(signal.SIGINT, lambda *_: broker.stopped.set())
            with tempfile.NamedTemporaryFile(mode='w', dir=root, prefix='bridge-pid-', delete=False) as receipt:
                temporary_path = Path(receipt.name)
                receipt.write(f'{os.getpid()}\n')
            try:
                temporary_path.replace(pid_path)
            finally:
                temporary_path.unlink(missing_ok=True)
            print('shared bridge ready', flush=True)
            while not broker.stopped.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                broker.accept(connection)
        finally:
            if broker is not None:
                broker.close()
            if process is not None:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            pid_path.unlink(missing_ok=True)
            path.unlink(missing_ok=True)


if __name__ == '__main__': main()
