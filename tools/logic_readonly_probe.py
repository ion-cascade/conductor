#!/usr/bin/env python3
import json,sys
from pathlib import Path
from logic_live_tracks import MCP,live_read
client=MCP(Path(__file__).resolve().parent.parent/"local-bin/LogicProMCP")
try:
 client.request("initialize",{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"logic-readonly-probe","version":"0.1"}},10)
 client.send({"jsonrpc":"2.0","method":"notifications/initialized"})
 tracks=live_read(lambda t:client.request("resources/read",{"uri":"logic://tracks"},min(t,5)),timeout=25)
 print(json.dumps({"uri":"logic://tracks","response":tracks}),flush=True)
 for uri in ["logic://project/info","logic://mixer","logic://markers","logic://transport/state"]:
  try:
   v=client.request("resources/read",{"uri":uri},35);body=json.loads(v["contents"][0]["text"]);print(json.dumps({"uri":uri,"response":body}),flush=True)
  except (TimeoutError,RuntimeError,ValueError,KeyError) as e:
   print(json.dumps({"uri":uri,"error":str(e)}),flush=True);break
finally:client.close()
