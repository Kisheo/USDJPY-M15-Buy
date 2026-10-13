"""Shared Forex Factory calendar cache. All exported timestamps are UTC epoch seconds."""
from datetime import datetime, timedelta, timezone
import json
import logging
import os
from pathlib import Path
import tempfile
import threading
import time
import urllib.request

URL = 'https://nfs.faireconomy.media/ff_calendar_thisweek.json'
REFRESH = 3600


def parse_calendar(payload, now):
    if not isinstance(payload, list) or not payload or len(payload) > 5000:
        raise ValueError('Invalid or empty calendar')
    events = set()
    weeks = []
    for row in payload:
        if not isinstance(row, dict):
            raise ValueError('Invalid calendar row')
        # Require offset-aware dates: never infer the PC or broker timezone.
        dt = datetime.fromisoformat(row['date'])
        if dt.tzinfo is None:
            raise ValueError('Calendar date has no timezone')
        start = (dt - timedelta(days=(dt.weekday()+1)%7)).replace(hour=0, minute=0, second=0, microsecond=0)
        weeks.append((int(start.timestamp()), int((start+timedelta(days=7)).timestamp())))
        currency, impact = row['country'], row['impact']
        if currency in ('USD', 'JPY', 'All') and impact in ('Medium', 'High'):
            events.add((int(dt.timestamp()), currency, impact))
    # Require current-week coverage, not merely a successful HTTP response.
    coverage = [w for w in weeks if w[0] <= now < w[1]]
    if not coverage:
        raise ValueError('Calendar does not cover the current week')
    return sorted(events), max(w[1] for w in coverage)


def atomic_write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='ascii', newline='') as out:
            out.write(text)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def publish(path, payload, fetched):
    events, until = parse_calendar(payload, fetched)
    # Header + exact record count lets the EA reject partial/corrupt snapshots.
    text = f'FFNEWS1,{int(fetched)},{until},{len(events)}\n'
    text += ''.join(f'{at},{currency},{impact}\n' for at,currency,impact in events)
    atomic_write(path, text)
    return len(events)


def run(root, stop):
    root = Path(root)
    cache = root / 'calendar.json'
    last_attempt = root / 'last-attempt.txt'
    while not stop.is_set():
        now = time.time()
        try:
            attempted = float(last_attempt.read_text())
        except (OSError, ValueError):
            attempted = 0
        # Persist attempts to avoid rate-limit bursts on receiver restarts.
        if -REFRESH < now-attempted < REFRESH:
            stop.wait(min(60, max(1, REFRESH-(now-attempted))))
            continue
        try:
            atomic_write(last_attempt, str(now))
            request = urllib.request.Request(URL, headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'application/json'})
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read(2_000_001)
            if len(raw) > 2_000_000:
                raise ValueError('Calendar too large')
            payload = json.loads(raw)
            count = publish(root/'calendar.csv', payload, now)
            atomic_write(cache, json.dumps({'fetched': now, 'events': payload}, ensure_ascii=True))
            logging.warning('Forex Factory calendar updated: %d relevant events', count)
        except Exception as exc:
            # Leave the last valid CSV untouched, including its original timestamp.
            logging.warning('Forex Factory calendar refresh failed: %s', type(exc).__name__)
        stop.wait(60)


def start(root):
    stop = threading.Event()
    threading.Thread(target=run, args=(root,stop), daemon=True, name='forex-factory-calendar').start()
    return stop
