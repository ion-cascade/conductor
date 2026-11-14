import io,json,unittest
from logic_mcp_proxy import respond
class Fake:
 def __init__(self,tracks):self.tracks=iter(tracks);self.calls=[]
 def request(self,method,params,timeout):
  self.calls.append(method)
  if method=="resources/read":return {"contents":[{"text":json.dumps(next(self.tracks))}]}
  return {"tools":[{"name":"test"}]}
 def send(self,msg):self.calls.append(msg["method"])
class Tests(unittest.TestCase):
 def test_waits_and_preserves_client_id(self):
  f=Fake([{"source":"project_file","readable":False,"data":[]},{"source":"ax_live","readable":True,"complete":False,"data":[{"name":"Bass"}]}]);o=io.StringIO();respond(o,f,{"id":99,"method":"resources/read","params":{"uri":"logic://tracks"}});r=json.loads(o.getvalue());self.assertEqual(r["id"],99);self.assertEqual(json.loads(r["result"]["contents"][0]["text"])["data"][0]["name"],"Bass")
 def test_forwards_other_methods(self):
  f=Fake([]);o=io.StringIO();respond(o,f,{"id":7,"method":"tools/list"});self.assertEqual(json.loads(o.getvalue())["result"]["tools"][0]["name"],"test")
 def test_forwards_notification_without_response(self):
  f=Fake([]);o=io.StringIO();respond(o,f,{"method":"notifications/initialized"});self.assertEqual(o.getvalue(),"");self.assertEqual(f.calls,["notifications/initialized"])
if __name__=="__main__":unittest.main()
