import json, os, socket, subprocess, sys, tempfile, threading, time, unittest
from pathlib import Path

FAKE = '''import json,sys,time,os
count=0
for line in sys.stdin:
 r=json.loads(line)
 if 'id' not in r: continue
 count+=1
 if r['method']=='crash': sys.exit(3)
 if r['method']=='slow':
  open(os.environ['MARKER'],'a').write('once\\n'); time.sleep(.3)
 if r['method']=='initialize': result={'protocolVersion':'2025-03-26','capabilities':{},'serverInfo':{'name':'fixture','version':'1'}}
 else: result={'count':count,'pid':os.getpid(),'value':r.get('params')}
 print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}),flush=True)
'''
class BrokerTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(prefix='lmp-'); self.root=Path(self.tmp.name)
  fake=self.root/'fake';fake.write_text('#!'+sys.executable+'\n'+FAKE);fake.chmod(0o700)
  self.env=dict(os.environ,LOGIC_MCP_BRIDGE_DIR=str(self.root),LOGIC_MCP_EXECUTABLE=str(fake),MARKER=str(self.root/'marker'))
  self.p=subprocess.Popen([sys.executable,str(Path(__file__).with_name('logic_bridge_server.py'))],env=self.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  self.assertEqual(self.p.stdout.readline().strip(),b'shared bridge ready'); self.connections=[]
 def tearDown(self):
  for c,_ in self.connections:c.close()
  self.p.terminate();self.p.communicate(timeout=8); self.tmp.cleanup()
 def connect(self,init=True):
  c=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);c.settimeout(4);c.connect(str(self.root/'bridge.sock'))
  f=c.makefile('rb');self.connections.append((c,f))
  if init:
   self.send(c,'initialize',1,dict(protocolVersion='2025-03-26',capabilities={},clientInfo=dict(name='test',version='1')))
   self.assertIn('result',self.recv(f))
  return c,f
 def send(self,c,m,i,p=None):c.sendall((json.dumps(dict(jsonrpc='2.0',method=m,id=i,params=p or {}))+'\n').encode())
 def recv(self,f):return json.loads(f.readline())
 def test_duplicate_start_preserves_live_socket_and_pid(self):
  pid_path = self.root / 'bridge.pid'
  socket_path = self.root / 'bridge.sock'
  before = socket_path.stat().st_ino
  self.assertEqual(int(pid_path.read_text()), self.p.pid)
  duplicate = subprocess.run(
   [sys.executable, str(Path(__file__).with_name('logic_bridge_server.py'))],
   env=self.env, capture_output=True, timeout=5)
  self.assertNotEqual(duplicate.returncode, 0)
  self.assertIn(b'another bridge already owns', duplicate.stderr)
  self.assertEqual(socket_path.stat().st_ino, before)
  self.assertEqual(int(pid_path.read_text()), self.p.pid)
  client, replies = self.connect()
  self.send(client, 'echo', 15)
  self.assertEqual(self.recv(replies)['id'], 15)
 def test_two_idle_clients_share_upstream_and_ids(self):
  a,fa=self.connect();b,fb=self.connect()
  self.send(a,'echo',2,{'a':1});self.send(b,'echo',2,{'b':2})
  ra=self.recv(fa);rb=self.recv(fb)
  self.assertEqual(ra['id'],rb['id']);self.assertEqual(ra['result']['pid'],rb['result']['pid'])
  self.assertEqual(ra['result']['value'],{'a':1});self.assertEqual(rb['result']['value'],{'b':2})
  # Client reader threads may enqueue in either order; IDs and payloads must
  # still reach the correct client and each request must execute exactly once.
  self.assertEqual(sorted([ra['result']['count'],rb['result']['count']]),[2,3])
 def test_disconnect_after_write_never_replays_and_next_client_recovers(self):
  a,fa=self.connect();b,fb=self.connect();self.send(a,'slow',2)
  deadline=time.monotonic()+2
  while not (self.root/'marker').exists() and time.monotonic()<deadline:time.sleep(.01)
  self.assertTrue((self.root/'marker').exists());a.shutdown(socket.SHUT_RDWR);fa.close();a.close()
  self.send(b,'echo',9);self.assertEqual(self.recv(fb)['id'],9)
  self.assertEqual((self.root/'marker').read_text(),'once\n')
 def test_idle_disconnect_and_reconnect(self):
  a,fa=self.connect();self.send(a,'echo',2);pid=self.recv(fa)['result']['pid']
  a.shutdown(socket.SHUT_RDWR);fa.close();a.close();b,fb=self.connect();self.send(b,'echo',2)
  self.assertEqual(self.recv(fb)['result']['pid'],pid)
 def test_preinit_and_invalid_requests_are_explicit(self):
  a,fa=self.connect(False);self.send(a,'echo',2);self.assertIn('error',self.recv(fa))
  a.sendall(b'[]\n');self.assertEqual(self.recv(fa)['error']['code'],-32600)
 def test_protocol_mismatch_refuses_without_new_upstream(self):
  a,fa=self.connect();b,fb=self.connect(False);self.send(b,'initialize',1,{'protocolVersion':'wrong'})
  self.assertEqual(self.recv(fb)['error']['code'],-32602)
 def test_queued_cancel_is_never_sent_to_upstream(self):
  a,fa=self.connect();b,fb=self.connect();self.send(a,'slow',2)
  deadline=time.monotonic()+2
  while not (self.root/'marker').exists() and time.monotonic()<deadline:time.sleep(.01)
  self.send(b,'echo',2,{'should_not_run':True})
  b.sendall((json.dumps(dict(jsonrpc='2.0',method='notifications/cancelled',params={'requestId':2}))+'\n').encode())
  self.assertIn('result',self.recv(fa));self.assertEqual(self.recv(fb)['error']['code'],-32800)
  self.send(b,'echo',3);self.assertEqual(self.recv(fb)['result']['count'],3)
 def test_upstream_failure_closes_clients_without_replay(self):
  a,fa=self.connect();self.send(a,'crash',2);self.assertEqual(fa.readline(),b'')
  self.p.wait(timeout=4)
  self.assertFalse((self.root / 'bridge.pid').exists())
  self.assertFalse((self.root / 'bridge.sock').exists())
class RelayTests(unittest.TestCase):
 def test_startup_wait_happens_before_any_protocol_bytes_are_sent(self):
  with tempfile.TemporaryDirectory(prefix='lmr-') as directory:
   seen=[]
   def server():
    time.sleep(.2)
    listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
    listener.bind(str(Path(directory)/'bridge.sock'));listener.listen(1);listener.settimeout(3)
    c,_=listener.accept();c.settimeout(3);data=b''
    while True:
     chunk=c.recv(1024)
     if not chunk:break
     data+=chunk
    seen.append(data);c.sendall(b'world\n');c.close();listener.close()
   thread=threading.Thread(target=server);thread.start()
   p=subprocess.Popen([sys.executable,str(Path(__file__).with_name('logic_bridge_relay.py'))],env=dict(os.environ,LOGIC_MCP_BRIDGE_DIR=directory),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   out,err=p.communicate(b'hello\n',timeout=5);thread.join(4)
   self.assertEqual((p.returncode,out,err),(0,b'world\n',b''));self.assertEqual(seen,[b'hello\n'])
if __name__=='__main__':unittest.main()
