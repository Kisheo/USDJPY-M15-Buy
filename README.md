# USDJPY M15 → existing XAUUSD tunnel → separate MT5 EA

`USDJPY_M15.pine` is based on the local `rejection_reversal_v5.pine`. The v5 strategy is retained with the buy-confirmation correction described below; existing input defaults, session and drawings remain. Longs remain enabled and shorts disabled by default.

## TradingView

1. Paste `USDJPY_M15.pine` into Pine Editor and add it to USDJPY, 15 minutes.
2. Enable **7. MT5 bridge → Enable MT5 JSON alerts**. Keep **Next open** and **Move SL to breakeven OFF**. Unsupported bridge modes fail explicitly; they still work with bridge alerts disabled.
3. Create a strategy alert for **alert() function calls only**, excluding order fills. Paste the **exact same webhook URL used by the XAUUSD alert**, including its secret path. No new tunnel or token is needed.
4. Recreate the alert whenever script/input settings change. TradingView retains an alert snapshot. See https://www.tradingview.com/pine-script-docs/concepts/alerts/.

Alerts are emitted only for accepted orders on realtime candle close. They include the original signal entry, SL and TP, route `usdjpy-m15`, symbol `USDJPY`, timeframe `15`, and a stable timestamp/direction ID. Replay, duplicate and stale signals are rejected or deduplicated. No historical orders are sent.

## MT5

Attach `CodexBridge/USDJPYSignalEA` to USDJPY M15. Set BrokerSymbol to your broker's exact symbol. The receiver's `--usdjpy-broker-symbol` must match if a suffix is used (default USDJPY). This EA has magic **20261015** and consumes **MQL5/Files/CodexBridgeUSDJPY** only. Gold keeps its original CodexBridge queue and EA.

`EnableTrading=false` logs and consumes signals without submitting orders. For execution set it true and enable MT5 Algo Trading. `AllowRealAccount` remains false by default; real accounts require an explicit change. Hedging is required by default. Fixed lots default to 0.01; optional USD risk sizing uses the same implementation as the gold bridge. Dry-run signals cannot subsequently be traded by toggling the switch.

Execution options match gold bridge v1.13: spread below 0.10 of original SL distance, optional TP extension off, adverse-move stop entry enabled at 1 pip, USDJPY pip size 0.01. Pending orders are GTC and require manual cancellation if no longer wanted. Disable UseStopEntryOnAdverseMove for market-only attempts. This setting belongs to the EA and differs from Pine limit entries.

The bridge uses signal-close absolute SL/TP; Pine's next-open simulated fill can change its simulated target. Broker fills, spread and timing can therefore differ from the backtest. Pine breakeven updates and virtual exits are not transmitted. Broker SL/TP manage actual exits. Claims are durable before submission, preventing automatic retries after an ambiguous execution result; check broker history for CHECK_BROKER or interrupted CLAIMED receipts.

## Shared receiver

`bridge/server.py` is the installed gold receiver extended with separate route dispatch. Existing command-line arguments, localhost port 8787, webhook secret, gold queue and SQLite records are preserved. It automatically adds the USDJPY queue in the same terminal. Unknown routes, cross-symbol payloads and wrong USDJPY timeframes are rejected. The existing supervisor can launch it without changes. Back up the runtime server before replacement, and restart only its receiver child; the supervisor restarts it automatically. No tunnel restart is necessary.

No secrets are stored in this repository. The receiver and both EAs must run on the same PC/terminal data directory. Keep both EAs attached to their respective charts.

## Validation

MetaEditor: zero errors, zero warnings. Twelve Python tests cover HTTP authentication, validation, duplicates, conflicts, recovery, receipt replay prevention and route isolation, including identical IDs on different routes. Tests use temporary queues and place no trades. Pine compilation in TradingView and an actual TradingView-to-MT5 fill remain unverified.

Installed on this PC: the active receiver in the Codex app-cache runtime was updated and restarted; localhost health and the USDJPY timeframe rejection were verified. The existing tunnel process was left running. USDJPYSignalEA source and compiled binary are installed under the configured terminal's Experts/CodexBridge directory. The EA has not been attached or enabled by this update. The original receiver was backed up in each updated runtime directory.

## Buy confirmation correction

Every buy requires the immediately previous candle to be a red impulse with a lower wick meeting `rejWick`, followed by the current candle closing green. Engulfing, breaking the prior body high and a higher low are not required. Existing impulse criteria (`rejImpATR` and `rejNM`) and the 40% default minimum wick still apply. OB and continuation paths cannot bypass this gate. A red or doji next candle fails confirmation; an older impulse cannot qualify this two-candle pattern. Existing enabled setup families, session, daily limits, position and risk checks still apply. Shorts are unchanged.

The signal and webhook occur at the green close. Default Next open simulation fills on the following candle. Buy SL covers both candles' lows plus the existing ATR buffer (and any lower rejection lookback low already selected). Existing 1.1R target calculation remains. Updated both the repository Pine and local rejection_reversal_v5.pine. Recreate the TradingView alert after replacing the script. Python regression checks pass; TradingView compilation/backtest remain to be run.
