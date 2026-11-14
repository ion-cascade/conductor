#!/usr/bin/env python3
"""Relay an SSH stdio stream to the owner-only Mac Unix socket."""
import os,socket,sys,threading,time
from pathlib import Path
p=Path(os.environ.get("LOGIC_MCP_BRIDGE_DIR",str(Path.home()/"Library/Application Support/Logic MCP Bridge")))/"bridge.sock"
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
# Startup retries happen before sending any MCP bytes, never after an attempted action.
deadline=time.monotonic()+8
while True:
 try:
  s.connect(str(p));break
 except (FileNotFoundError,ConnectionRefusedError):
  if time.monotonic()>=deadline:
   s.close();raise SystemExit("Logic bridge unavailable after 8s; no request was sent. Check the Mac login launcher.")
  time.sleep(.1)
def forward():
 try:
  while True:
   data=os.read(0,65536)
   if not data:break
   s.sendall(data)
 except (BrokenPipeError,OSError):pass
 finally:
  try:s.shutdown(socket.SHUT_WR)
  except OSError:pass
threading.Thread(target=forward,daemon=True).start()
try:
 while True:
  data=s.recv(65536)
  if not data:break
  sys.stdout.buffer.write(data);sys.stdout.buffer.flush()
except (BrokenPipeError,OSError):pass
finally:s.close()
