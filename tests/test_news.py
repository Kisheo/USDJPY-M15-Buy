import importlib.util
from pathlib import Path
import tempfile
import unittest
from datetime import datetime

spec=importlib.util.spec_from_file_location('news',Path(__file__).parents[1]/'bridge/news_calendar.py')
news=importlib.util.module_from_spec(spec);spec.loader.exec_module(news)
NOW=int(datetime.fromisoformat('2026-10-13T10:00:00+00:00').timestamp())

def event(country='USD',impact='High',date='2026-10-13T08:30:00-04:00'):
    return dict(country=country,impact=impact,date=date,title='Example')

class CalendarTests(unittest.TestCase):
    def test_timezone_and_currency_impact_filter(self):
        rows,until=news.parse_calendar([event(),event('JPY','Medium'),event('EUR'),event(impact='Low'),event('All')],NOW)
        self.assertEqual(len(rows),3)
        expected=int(datetime.fromisoformat('2026-10-13T12:30:00+00:00').timestamp())
        self.assertTrue(all(row[0]==expected for row in rows))
        self.assertGreater(until,NOW)

    def test_duplicate_events_deduplicated(self):
        self.assertEqual(len(news.parse_calendar([event(),event()],NOW)[0]),1)

    def test_dst_offsets_respected(self):
        rows,_=news.parse_calendar([event(date='2026-10-13T08:30:00-05:00'),event()],NOW)
        self.assertEqual(rows[1][0]-rows[0][0],3600)

    def test_reject_bad_or_old_calendar(self):
        for payload in [[],{},[event(date='Tentative')],[event(date='2026-10-13T08:30:00')],[event(date='2026-09-13T08:30:00-04:00')]]:
            with self.assertRaises((ValueError,KeyError)):news.parse_calendar(payload,NOW)

    def test_failure_preserves_snapshot_and_timestamp(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/'calendar.csv'
            news.publish(p,[event()],NOW)
            original=p.read_text()
            with self.assertRaises(ValueError):news.publish(p,[],NOW+3600)
            self.assertEqual(p.read_text(),original)
            self.assertEqual(len(original.splitlines()),2)
            self.assertTrue(original.startswith(f'FFNEWS1,{NOW},'))

    def test_valid_week_without_relevant_events_is_distinct_from_failure(self):
        rows,until=news.parse_calendar([event('EUR','Low')],NOW)
        self.assertEqual(rows,[])
        self.assertGreater(until,NOW)

# Evaluate the actual MQL window expression, not a separately copied timing rule.
import re
MQL=(Path(__file__).parents[1]/'mt5/NewsProtection.mqh').read_text()
EXPR=re.search(r'if\((now>=newsTimes\[i\].*)\)',MQL)[1]
EXPR=EXPR.replace('(long)','').replace('newsTimes[i]','at').replace('&&',' and ')

def active(now,at,lead):
    return eval(EXPR,{'__builtins__':{}},dict(now=now,at=at,lead=lead,NewsResumeMinutes=15))

class NewsWindowTests(unittest.TestCase):
    def test_high_boundaries(self):
        self.assertFalse(active(NOW-1801,NOW,30))
        self.assertTrue(active(NOW-1800,NOW,30))
        self.assertTrue(active(NOW,NOW,30))
        self.assertTrue(active(NOW+899,NOW,30))
        self.assertFalse(active(NOW+900,NOW,30))

    def test_medium_boundaries(self):
        self.assertFalse(active(NOW-901,NOW,15))
        self.assertTrue(active(NOW-900,NOW,15))

    def test_overlapping_windows_keep_blocking(self):
        self.assertTrue(any(active(NOW+900,at,30) for at in [NOW,NOW+1800]))

    def test_currency_routing_expression(self):
        expr=re.search(r'if\((newsCurrencies\[i\].*?)\) continue;',MQL)[1]
        expr=expr.replace('newsCurrencies[i]','currency').replace('&&',' and ').replace('!(', 'not (')
        for jpy in [False,True]:
            for currency in ['USD','JPY','All','EUR']:
                skip=eval(expr,{'__builtins__':{}},dict(currency=currency,NEWS_INCLUDE_JPY=jpy))
                self.assertEqual(not skip,currency in ('USD','All') or (jpy and currency=='JPY'))


class RefreshTests(unittest.TestCase):
    def test_restart_uses_success_and_exact_boundary(self):
        import json
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            (root/'calendar.json').write_text(json.dumps(dict(fetched=NOW,events=[event()])))
            (root/'last-attempt.txt').write_text(str(NOW))
            self.assertEqual(news.refresh_delay(root,NOW+43199),1)
            self.assertTrue((root/'calendar.csv').exists())
            self.assertEqual(news.refresh_delay(root,NOW+43200),0)
            self.assertEqual(news.refresh_delay(root,NOW+50000),0)
            self.assertTrue((root/'calendar.csv').read_text().startswith(f'FFNEWS1,{NOW},'))

    def test_failed_attempt_does_not_count_as_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            (root/'last-attempt.txt').write_text(str(NOW))
            self.assertEqual(news.refresh_delay(root,NOW+100),3500)
            self.assertEqual(news.refresh_delay(root,NOW+3600),0)

    def test_missing_cache_and_future_clock(self):
        import json
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            self.assertEqual(news.refresh_delay(root,NOW),0)
            (root/'calendar.json').write_text(json.dumps(dict(fetched=NOW+500,events=[event()])))
            self.assertEqual(news.refresh_delay(root,NOW),0)

if __name__=='__main__':unittest.main()
