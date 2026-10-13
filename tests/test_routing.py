import tempfile
import time
import unittest
from pathlib import Path
from test_bridge import server

class RoutingTests(unittest.TestCase):
    def test_routes_are_isolated_and_recover_independently(self):
        with tempfile.TemporaryDirectory() as temp:
            gold=server.Queue(Path(temp)/'gold','xau-m5','XAUUSD','XAUUSD')
            yen=server.Queue(Path(temp)/'yen','usdjpy-m15','USDJPY','USDJPYm')
            try:
                router=server.Router([gold,yen])
                p=dict(version=1,event='entry',id='same-id',route='usdjpy-m15',symbol='USDJPY',timeframe='15',side='BUY',entry=150,sl=149,tp=151.1,time_ms=int(time.time()*1000))
                router.accept(p)
                self.assertEqual(list((gold.root/'inbox').glob('*.csv')),[])
                f=next((yen.root/'inbox').glob('*.csv'))
                self.assertIn(',USDJPYm,BUY,',f.read_text())
                self.assertEqual(router.accept(p)['status'],'duplicate')
                for updates in [dict(route='unknown'),dict(symbol='XAUUSD'),dict(timeframe='5'),dict(time_ms=0),dict(sl=151)]:
                    with self.assertRaises(ValueError): router.accept(p|updates)
                router.accept(p|dict(route='xau-m5',symbol='XAUUSD',entry=3000,sl=2990,tp=3011))
                self.assertEqual(len(list((gold.root/'inbox').glob('*.csv'))),1)
                f.unlink()
                yen.recover()
                self.assertTrue(f.exists())
                (yen.root/'receipts'/f.name).write_text('CLAIMED')
                f.unlink()
                yen.recover()
                self.assertFalse(f.exists())
            finally:
                gold.db.close()
                yen.db.close()

if __name__=='__main__': unittest.main()
