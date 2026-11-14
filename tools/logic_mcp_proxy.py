#!/usr/bin/env python3
"""Experimental serial MCP stdio proxy: waits for observed track headers.

Server-initiated requests/notifications and concurrent in-flight requests are
not supported. Use only for explicit testing, not as a production transport.
"""
import json,sys
from pathlib import Path
from logic_live_tracks import MCP,live_read

def respond(out,client,message,timeout=15):
 method=message.get("method");params=message.get("params",{});request_id=message.get("id")
 if request_id is None:
  client.send(message);return
 try:
  if method=="resources/read" and params.get("uri")=="logic://tracks":
   data=live_read(lambda t:client.request(method,params,min(5,t)),timeout=timeout)
   result={"contents":[{"uri":"logic://tracks","mimeType":"application/json","text":json.dumps(data,ensure_ascii=False)}]}
  else:result=client.request(method,params,35)
  response={"jsonrpc":"2.0","id":request_id,"result":result}
 except (TimeoutError,RuntimeError,KeyError,ValueError) as e:
  response={"jsonrpc":"2.0","id":request_id,"error":{"code":-32000,"message":str(e)}}
 out.write(json.dumps(response,ensure_ascii=False)+"\n");out.flush()

def main():
 client=MCP(Path(__file__).resolve().parent.parent/"local-bin/LogicProMCP")
 try:
  for line in sys.stdin:
   try:msg=json.loads(line)
   except ValueError:continue
   respond(sys.stdout,client,msg)
 finally:client.close()
if __name__=="__main__":main()
