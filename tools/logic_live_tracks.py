#!/usr/bin/env python3
"""Bounded MCP live track read: never treat startup placeholders as observations."""
import argparse,json,os,queue,subprocess,sys,threading,time
from pathlib import Path

class MCP:
 def __init__(self,binary):
  env=dict(os.environ,LOGIC_PRO_BUNDLE_ID="com.apple.logic10")
  self.process=subprocess.Popen([str(binary)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1,env=env)
  self.messages=queue.Queue();self.next_id=0
  def read():
   for line in self.process.stdout:
    try:self.messages.put(json.loads(line))
    except json.JSONDecodeError:pass
   self.messages.put(None)
  threading.Thread(target=read,daemon=True).start()
 def send(self,payload):
  self.process.stdin.write(json.dumps(payload)+"\n");self.process.stdin.flush()
 def request(self,method,params,timeout):
  self.next_id+=1;request_id=self.next_id;self.send({"jsonrpc":"2.0","id":request_id,"method":method,"params":params});end=time.monotonic()+timeout
  while True:
   left=end-time.monotonic()
   if left<=0:raise TimeoutError(method)
   try:msg=self.messages.get(timeout=left)
   except queue.Empty:raise TimeoutError(method)
   if msg is None:raise RuntimeError("MCP server exited")
   if msg.get("id")==request_id:
    if "error" in msg:raise RuntimeError(str(msg["error"]))
    return msg["result"]
 def close(self):
  self.process.terminate()
  try:self.process.wait(timeout=4)
  except subprocess.TimeoutExpired:self.process.kill();self.process.wait()

def live_read(request,timeout=15,interval=.5,clock=time.monotonic,sleep=time.sleep):
 deadline=clock()+timeout;last=None
 while clock()<deadline:
  result=request(max(.01,deadline-clock()))
  last=json.loads(result["contents"][0]["text"])
  if last.get("source")=="ax_live" and last.get("readable") is True and isinstance(last.get("data"),list) and (last["data"] or last.get("verified_empty") is True) and all(not r.get("placeholder",False) for r in last["data"]):
   return last
  left=deadline-clock()
  if left>0:sleep(min(interval,left))
 raise TimeoutError("No live track read before deadline; last source="+str((last or {}).get("source")))

def main():
 ap=argparse.ArgumentParser();ap.add_argument("--binary",type=Path,default=Path(__file__).resolve().parent.parent/"local-bin/LogicProMCP");ap.add_argument("--timeout",type=float,default=15);args=ap.parse_args()
 client=MCP(args.binary)
 try:
  client.request("initialize",{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"logic-live-tracks","version":"0.1"}},10)
  client.send({"jsonrpc":"2.0","method":"notifications/initialized"})
  result=live_read(lambda t:client.request("resources/read",{"uri":"logic://tracks"},min(t,5)),timeout=args.timeout)
  print(json.dumps(result,ensure_ascii=False))
 except (TimeoutError,RuntimeError,KeyError,ValueError) as exc:
  print(json.dumps({"error":str(exc),"verified":False}),file=sys.stderr);return 2
 finally:client.close()
 return 0
if __name__=="__main__":raise SystemExit(main())
