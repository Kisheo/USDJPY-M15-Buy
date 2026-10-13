# Forex Factory news protection — both signal EAs v1.20

## Requested behavior

| Calendar event | Symbols affected | Close/cancel starts | Resume entries |
| --- | --- | --- | --- |
| USD Medium | XAUUSD and USDJPY | 15 minutes before | 15 minutes after |
| USD High | XAUUSD and USDJPY | 30 minutes before | 15 minutes after |
| JPY Medium | USDJPY | 15 minutes before | 15 minutes after |
| JPY High | USDJPY | 30 minutes before | 15 minutes after |

Events marked `All` affect both symbols. Low-impact and holiday events do not trigger exits. Currency mapping is a calendar filter, not a prediction of every event that can move gold or yen. Only events provided by the scheduled calendar are covered; unscheduled news cannot be anticipated. Tentative release times can change, and a dated export cannot guarantee the true publication time.

Per the requested scope, **all positions and pending orders on the EA's exact BrokerSymbol are affected, including manual trades and other magic numbers**. Other symbols are untouched. Both buy and sell positions are closed, whether profitable or losing. Positions close by ticket; unclosed positions and undeleted orders retry every five seconds. Broker errors/partial results are logged. Execution is an attempt at the window boundary, not a guarantee of a fill at that exact time.

New bridge signals during the window are consumed with NEWS_BLOCKED receipts and are never replayed after release. Other EAs/manual trading are outside this EA's entry control: any positions they open during the window will be closed on the next news-management pass. Overlapping news windows keep protection active until all relevant windows end.

## Source and timing

The receiver loads Forex Factory's public weekly JSON export:
https://nfs.faireconomy.media/ff_calendar_thisweek.json
linked from https://www.forexfactory.com/calendar (Weekly Export).

One background downloader runs in the existing receiver, hourly, shared by both EAs. No per-EA Internet requests or MT5 WebRequest allowlist are needed. HTTP requests use a 20-second timeout without blocking webhook processing. Attempts are persisted to avoid repeated downloads during restarts. The schedule is written atomically under the configured terminal's `MQL5/Files/CodexNews/calendar.csv`. Dates are converted from their explicit timezone offset to UTC; EAs compare TimeGMT, not broker server time. Keep the Windows clock synchronized.

The EA checks the calendar every second even when no trading signals arrive. MediumNewsLeadMinutes=15, HighNewsLeadMinutes=30, NewsResumeMinutes=15. Protection starts inclusively at the lead time and ends at event time + 15 minutes. Attaching the EA during an active window triggers protection immediately when execution permissions allow it.

## Missing/stale data

EnableNewsProtection=true and BlockEntriesWithoutCalendar=true by default. Missing data, a cache older than six hours, or expired weekly coverage blocks new entries and logs the condition. It does **not** automatically close trades without a known relevant event. The last valid schedule remains usable for known event exits even when stale. Failed refreshes do not reset freshness or replace valid schedules with empty ones. No current-week data is an error, not an empty news week. The public feed may be unavailable, rate-limited, or updated late; the integration cannot guarantee protection against changed/missing events. A feed failure is retried on the next hourly refresh. Weekly rollovers block new entries until current-week coverage is downloaded.

## Installation and activation

Both EAs and NewsProtection.mqh live in this repository's mt5 folder. The XAUUSD bridge EA is based on its existing v1.13 source; the standalone XAUUSDNativeEA branch is not modified. Compile each mq5 with NewsProtection.mqh alongside it. Run bridge/install-update.ps1 with the active runtime directory to install both binaries, shared include, news downloader and updated receiver. It backs up the old receiver and installed EAs. Existing tunnel credentials, URL, SQLite queues and receipts are preserved.

In MT5 reload **XAUUSDSignalEA** on the gold chart and **USDJPYSignalEA** on USDJPY M15. Confirm version **1.20**, BrokerSymbol, lot sizing and existing execution inputs. Keep **EnableNewsProtection=true**. News closures require **EnableTrading=true**, MT5 Algo Trading permission and **AllowRealAccount=true** if using a real account. Dry-run mode never closes positions or cancels orders. Confirm the Experts log says `NEWS: Calendar ready; outside news window` or names the current news window. A stale/missing warning means the schedule is not healthy and new entries are blocked.

No Pine changes or TradingView alert recreation are required for this update. Run only one signal EA consumer per symbol queue. These settings do not modify the Pine backtest: real news exits will therefore differ from its reported trades.

## Verification

Both EAs compile: zero errors, zero warnings. Seventeen Python tests cover existing bridge behavior plus timestamp conversion, DST offsets, currency/impact selection, deduplication, old/invalid feed rejection, cache preservation, and the actual MQL time-window expressions at medium/high boundaries and overlaps. Public JSON access was verified. Automated tests do not place, close or cancel broker trades. Broker-side news liquidation and post-release resumption still require observation in a demo session; compilation and local tests are not a live execution test.

Installation verification: both v1.20 binaries and the shared include were installed in the configured terminal. The active receiver restarted successfully, localhost health passed, and the shared downloader published a current-week CSV containing four relevant scheduled events. No synthetic calendar was installed. Reload both EAs to activate the new code; no live liquidation test was performed.
