"""TradingView webhook -> durable local MT5 file queue. Python standard library only."""
import argparse
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import tempfile
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


class Queue:
    def __init__(self, root, route, source_symbol, broker_symbol, max_age=90):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        (self.root / 'inbox').mkdir(exist_ok=True)
        (self.root / 'receipts').mkdir(exist_ok=True)
        self.route, self.source_symbol, self.broker_symbol = route, source_symbol, broker_symbol
        self.max_age = max_age
        if not re.fullmatch(r'[A-Za-z0-9_.#-]{1,64}', broker_symbol):
            raise ValueError('Invalid broker symbol')
        self.db = sqlite3.connect(self.root / 'queue.sqlite3')
        self.db.execute('CREATE TABLE IF NOT EXISTS signals (id TEXT PRIMARY KEY, payload TEXT NOT NULL, file_key TEXT NOT NULL)')
        self.db.commit()

    def validate(self, p, now):
        if not isinstance(p, dict) or type(p.get('version')) is not int or p.get('version') != 1 or p.get('event') != 'entry':
            raise ValueError('Expected version 1 entry event')
        if p.get('route') != self.route or p.get('symbol') != self.source_symbol:
            raise ValueError('Route or source symbol mismatch')
        if p.get('side') not in ('BUY', 'SELL'):
            raise ValueError('Invalid side')
        if not isinstance(p.get('id'), str) or not 1 <= len(p['id']) <= 250:
            raise ValueError('Invalid signal ID')
        if type(p.get('time_ms')) is not int:
            raise ValueError('Invalid time_ms')
        age = now - p['time_ms'] / 1000
        if age < -5 or age > self.max_age:
            raise ValueError('Stale or future signal')
        for field in ('entry', 'sl', 'tp'):
            value = p.get(field)
            if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                raise ValueError('Invalid price')
        if not (p['sl'] < p['entry'] < p['tp'] if p['side'] == 'BUY' else p['tp'] < p['entry'] < p['sl']):
            raise ValueError('Invalid risk bracket')

    def accept(self, payload, now=None):
        now = time.time() if now is None else now
        self.validate(payload, now)
        canonical = json.dumps(payload, sort_keys=True, separators=(',', ':'))
        key = hashlib.sha256(payload['id'].encode()).hexdigest()[:24]
        existing = self.db.execute('SELECT payload FROM signals WHERE id=?', (payload['id'],)).fetchone()
        if existing and existing[0] != canonical:
            raise ValueError('Conflicting duplicate ID')
        with self.db:
            self.db.execute('INSERT OR IGNORE INTO signals VALUES (?,?,?)', (payload['id'], canonical, key))
        self.deliver(key, payload)
        return {'status': 'duplicate' if existing else 'queued', 'key': key}

    def deliver(self, key, p):
        dest = self.root / 'inbox' / (key + '.csv')
        if dest.exists() or (self.root / 'receipts' / (key + '.csv')).exists():
            return
        # No arbitrary remote paths or broker symbols are accepted.
        line = ','.join([key, str(p['time_ms'] // 1000), self.broker_symbol, p['side'],
                         str(p['entry']), str(p['sl']), str(p['tp'])]) + '\n'
        fd, name = tempfile.mkstemp(prefix='pending-', suffix='.tmp', dir=dest.parent)
        try:
            with os.fdopen(fd, 'w', encoding='ascii', newline='') as f:
                f.write(line)
                f.flush()
                os.fsync(f.fileno())
            os.replace(name, dest)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def recover(self):
        for raw, key in self.db.execute('SELECT payload, file_key FROM signals'):
            p = json.loads(raw)
            if -5 <= time.time() - p['time_ms'] / 1000 <= self.max_age:
                self.deliver(key, p)


class Router:
    def __init__(self, queues):
        self.queues = {q.route: q for q in queues}
        if len(self.queues) != len(queues):
            raise ValueError('Duplicate routes')

    def accept(self, payload, now=None):
        if not isinstance(payload, dict) or not isinstance(payload.get('route'), str):
            raise ValueError('Invalid route')
        queue = self.queues.get(payload['route'])
        if queue is None:
            raise ValueError('Unknown route')
        if queue.route == 'usdjpy-m15' and payload.get('timeframe') != '15':
            raise ValueError('USDJPY requires M15')
        return queue.accept(payload, now)


def handler(queue, token):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(2)

        def log_message(self, *_):
            pass  # Never log the webhook URL secret.

        def reply(self, code, result):
            raw = json.dumps(result).encode()
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_POST(self):
            if not hmac.compare_digest(self.path, '/webhook/' + token):
                self.reply(403, {'error': 'unauthorized'})
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 8192:
                    raise ValueError('Invalid payload size')
                self.connection.settimeout(2)
                payload = json.loads(self.rfile.read(length))
                self.reply(200, queue.accept(payload))
            except (ValueError, UnicodeError) as exc:
                self.reply(400, {'error': str(exc)})
            except Exception:
                self.reply(503, {'error': 'Queue unavailable'})

        def do_GET(self):
            self.reply(200 if self.path == '/health' else 404,
                       {'status': 'ok'} if self.path == '/health' else {'error': 'not found'})

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mt5-data', required=True)
    parser.add_argument('--route', default='xau-m5')
    parser.add_argument('--source-symbol', default='XAUUSD')
    parser.add_argument('--broker-symbol', default='XAUUSD')
    parser.add_argument('--usdjpy-broker-symbol', default='USDJPY')
    parser.add_argument('--port', type=int, default=8787)
    parser.add_argument('--token-file')
    args = parser.parse_args()
    token = Path(args.token_file).read_text().strip() if args.token_file else os.environ.get('MT5_WEBHOOK_TOKEN', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{32,128}', token):
        parser.error('Set MT5_WEBHOOK_TOKEN to a random 32+ character URL-safe secret')
    root = Path(args.mt5_data) / 'MQL5' / 'Files' / 'CodexBridge'
    queue = Queue(root, args.route, args.source_symbol, args.broker_symbol)
    usd = Queue(root.parent / 'CodexBridgeUSDJPY', 'usdjpy-m15', 'USDJPY', args.usdjpy_broker_symbol)
    queue.recover()
    usd.recover()
    queue = Router([queue, usd])
    print(f'Listening on 127.0.0.1:{args.port}; queue: {root}; no trading performed by receiver')
    import news_calendar
    news_stop = news_calendar.start(root.parent / 'CodexNews')
    try:
        HTTPServer(('127.0.0.1', args.port), handler(queue, token)).serve_forever()
    finally:
        news_stop.set()


if __name__ == '__main__':
    main()
