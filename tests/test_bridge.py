import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest
import threading
import http.client

spec = importlib.util.spec_from_file_location('bridge_server', Path(__file__).parents[1] / 'bridge/server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.queue = server.Queue(self.tmp.name, 'xau-m5', 'XAUUSD', 'XAUUSDm')
        self.signal = dict(version=1, event='entry', id='example', route='xau-m5',
                           symbol='XAUUSD', side='BUY', time_ms=int(time.time()*1000),
                           entry=3000, sl=2990, tp=3011)

    def tearDown(self):
        self.queue.db.close()
        self.tmp.cleanup()

    def test_queue_mapping_and_dedup(self):
        result = self.queue.accept(self.signal)
        self.assertEqual(result['status'], 'queued')
        files = list((Path(self.tmp.name)/'inbox').glob('*.csv'))
        self.assertEqual(len(files), 1)
        self.assertIn(',XAUUSDm,BUY,3000,2990,3011', files[0].read_text())
        self.assertEqual(self.queue.accept(self.signal)['status'], 'duplicate')
        self.assertEqual(len(list(files[0].parent.glob('*.csv'))), 1)

    def test_conflicting_id(self):
        self.queue.accept(self.signal)
        with self.assertRaises(ValueError):
            self.queue.accept(self.signal | {'tp': 3012})

    def test_bad_payloads(self):
        for delta in ({'side':'OTHER'}, {'symbol':'EURUSD'}, {'route':'other'},
                      {'sl':3001}, {'tp':float('nan')}, {'entry':True},
                      {'time_ms':self.signal['time_ms']-100000},
                      {'time_ms':self.signal['time_ms']+100000}, {'event':'outcome'}):
            with self.subTest(delta=delta), self.assertRaises(ValueError):
                self.queue.accept(self.signal | delta)

    def test_sell(self):
        self.assertEqual(self.queue.accept(self.signal | {'side':'SELL','sl':3010,'tp':2989})['status'], 'queued')

    def test_http_to_queue_and_authentication(self):
        httpd = server.HTTPServer(('127.0.0.1', 0), server.handler(self.queue, 'x'*32))
        try:
            for path, body, expected in [('/webhook/wrong', self.signal, 403),
                                         ('/webhook/'+'x'*32, self.signal, 200),
                                         ('/webhook/'+'x'*32, self.signal, 200),
                                         ('/webhook/'+'x'*32, {'event':'outcome'}, 400)]:
                responses = []
                def request():
                    conn = http.client.HTTPConnection(*httpd.server_address, timeout=3)
                    conn.request('POST', path, json.dumps(body), {'Content-Type':'application/json'})
                    response = conn.getresponse()
                    responses.append((response.status, response.read()))
                    conn.close()
                thread = threading.Thread(target=request)
                thread.start()
                httpd.handle_request()
                thread.join(timeout=4)
                self.assertEqual(responses[0][0], expected)
            self.assertEqual(len(list((Path(self.tmp.name)/'inbox').glob('*.csv'))), 1)
        finally:
            httpd.server_close()

    def test_recovery_and_receipt_prevents_replay(self):
        result = self.queue.accept(self.signal)
        file = Path(self.tmp.name)/'inbox'/(result['key']+'.csv')
        file.unlink()
        self.queue.recover()
        self.assertTrue(file.exists())
        file.unlink()
        (Path(self.tmp.name)/'receipts'/(result['key']+'.csv')).write_text('CLAIMED')
        self.queue.recover()
        self.assertFalse(file.exists())
        self.queue.accept(self.signal)
        self.assertFalse(file.exists())


if __name__ == '__main__':
    unittest.main()
