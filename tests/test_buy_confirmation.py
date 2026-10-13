import re
import unittest
from pathlib import Path

PINE = (Path(__file__).parents[1] / 'USDJPY_M15.pine').read_text()

def confirms(impulse=True, wick=45, opening=150, closing=150.01):
    expression = re.search(r'^buyConfirmation = (.+)$', PINE, re.M)[1]
    expression = expression.replace('impBear[1]', 'impulse')
    return eval(expression, {'__builtins__': {}}, dict(impulse=impulse, pLowW=wick, rejWick=40, close=closing, open=opening))

class BuyConfirmationTests(unittest.TestCase):
    def test_small_green_without_engulf_confirms(self):
        self.assertTrue(confirms())

    def test_red_and_doji_do_not_confirm(self):
        self.assertFalse(confirms(closing=149.99))
        self.assertFalse(confirms(closing=150))

    def test_immediate_impulse_and_wick_required(self):
        self.assertFalse(confirms(impulse=False))
        self.assertFalse(confirms(wick=39.9))
        self.assertTrue(confirms(wick=40))

    def test_other_buy_paths_cannot_bypass_confirmation(self):
        expression = re.search(r'^buySig  = (.+)$', PINE, re.M)[1]
        for ob, cont, rej in [(True,False,False),(False,True,False),(False,False,True),(True,True,True)]:
            env=dict(baseOk=True,allowLong=True,buyConfirmation=False,obBuy=ob,contBuy=cont,rejBuy=rej)
            self.assertFalse(eval(expression, {'__builtins__': {}}, env))

    def test_both_candle_lows_protected(self):
        self.assertIn('math.min(slBase ? rejLowSL : low, math.min(low, low[1]))',PINE)
        self.assertIn('baseOk  = inSess and limitOk and barstate.isconfirmed',PINE)

if __name__ == '__main__': unittest.main()
