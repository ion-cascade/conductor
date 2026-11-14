import json,unittest
from logic_live_tracks import live_read
class Clock:
 def __init__(self):self.now=0
 def clock(self):return self.now
 def sleep(self,n):self.now+=n
def reply(v):return {"contents":[{"text":json.dumps(v)}]}
class Tests(unittest.TestCase):
 def test_waits_for_observed_rows_and_preserves_incomplete(self):
  c=Clock();seq=iter([reply({"source":"project_file","readable":False,"data":[{"name":"Track 1","placeholder":True}]}),reply({"source":"ax_live","readable":True,"complete":False,"data":[{"name":"Bass"}]})]);r=live_read(lambda _:next(seq),clock=c.clock,sleep=c.sleep);self.assertEqual(r["data"][0]["name"],"Bass");self.assertFalse(r["complete"]);self.assertGreater(c.now,0)
 def test_times_out_instead_of_trusting_placeholders(self):
  c=Clock();fake=reply({"source":"project_file","readable":False,"data":[{"placeholder":True}]})
  with self.assertRaises(TimeoutError):live_read(lambda _:fake,timeout=1,clock=c.clock,sleep=c.sleep)
 def test_rejects_unverified_empty(self):
  c=Clock();fake=reply({"source":"ax_live","readable":True,"verified_empty":False,"data":[]})
  with self.assertRaises(TimeoutError):live_read(lambda _:fake,timeout=1,clock=c.clock,sleep=c.sleep)
 def test_rejects_placeholder_even_if_marked_live(self):
  c=Clock();fake=reply({"source":"ax_live","readable":True,"data":[{"placeholder":True}]})
  with self.assertRaises(TimeoutError):live_read(lambda _:fake,timeout=1,clock=c.clock,sleep=c.sleep)
if __name__=="__main__":unittest.main()
