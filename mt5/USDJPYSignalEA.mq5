#property strict
#property version "1.14"
#include <Trade/Trade.mqh>

input bool EnableTrading = false; // Place orders (true = trade, false = log signals only)
input bool AllowRealAccount = false;
input string BrokerSymbol = "USDJPY";
input double FixedLots = 0.01;
enum LotSizingMode { FIXED_LOTS=0, USD_RISK=1 };
input LotSizingMode LotSizing = FIXED_LOTS; // Position sizing: fixed lots or USD risk
input double RiskUSD = 10.0; // Target loss at stop in USD (USD accounts only)
input int MaxSignalAgeSeconds = 90;
input bool UseRiskRelativeSpread = true; // Use spread/R filter instead of fixed spread and drift limits
input double MaxSpreadR = 0.10; // Reject spread at or above this fraction of original SL distance
input int MaxSpreadPoints = 100; // Legacy mode only: maximum spread in points
input int MaxEntryDriftPoints = 200; // Legacy mode only: maximum entry drift in points
input bool ExtendTPForEntryMove = false; // Extend TP when price has moved toward target
input double TPExtensionThresholdPips = 0.8; // Minimum favorable entry movement (pips)
input double PipSize = 0.01; // Price units per pip (0.01 means USDJPY move 150.00 to 150.01)
input bool UseStopEntryOnAdverseMove = true; // Place stop at signal entry when price moves toward SL
input double StopEntryThresholdPips = 1.0; // Minimum movement toward SL for pending entry (pips)
input ulong DeviationPoints = 20;
input ulong MagicNumber = 20261015;
input bool RequireHedgingAccount = true;

CTrade trade;
int lockHandle = INVALID_HANDLE;
string root = "CodexBridgeUSDJPY\\";

bool CalculateLots(string symbol,bool buy,double price,double sl,double &lots,double &risk,string &error)
{
   double minimum=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double maximum=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(minimum<=0 || maximum<minimum || step<=0)
   { error="Invalid broker volume limits"; return false; }
   lots=FixedLots;
   risk=0;
   ENUM_ORDER_TYPE direction=buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(LotSizing==USD_RISK)
   {
      if(AccountInfoString(ACCOUNT_CURRENCY)!="USD")
      { error="USD risk sizing requires a USD account"; return false; }
      double profit=0;
      if(!OrderCalcProfit(direction,symbol,minimum,price,sl,profit) || !MathIsValidNumber(profit) || profit>=0)
      { error="Cannot calculate stop-loss risk from broker prices"; return false; }
      double raw=RiskUSD/(-profit)*minimum;
      // Nearest valid broker step; ties round upward. Broker limits clamp sizing.
      lots=NormalizeDouble(MathMax(minimum,MathMin(MathFloor(maximum/step)*step,MathRound(raw/step)*step)),8);
   }
   if(!MathIsValidNumber(lots) || lots<minimum || lots>maximum || MathAbs(lots/step-MathRound(lots/step))>0.000001)
   { error="Invalid lot size for broker"; return false; }
   double profit=0;
   if(OrderCalcProfit(direction,symbol,lots,price,sl,profit)) risk=MathAbs(profit);
   else if(LotSizing==USD_RISK) { error="Cannot verify sized stop-loss risk"; return false; }
   return true;
}

void Receipt(string key, string status, string detail)
{
   int f=FileOpen(root+"receipts\\"+key+".csv",FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(f==INVALID_HANDLE) { Print("Receipt write failed: ",GetLastError()); return; }
   FileWrite(f,key,status,detail,TimeToString(TimeGMT(),TIME_DATE|TIME_SECONDS));
   FileFlush(f); FileClose(f);
   Print("Bridge ",key," ",status," ",detail);
}

bool Claim(string key)
{
   string path=root+"receipts\\"+key+".csv";
   if(FileIsExist(path)) return false;
   int f=FileOpen(path,FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(f==INVALID_HANDLE) return false;
   uint written=FileWrite(f,key,"CLAIMED","Check broker history if terminal stops before final receipt");
   FileFlush(f); FileClose(f);
   return written>0;
}

void Process(string filename)
{
   string key=StringSubstr(filename,0,24);
   if(StringLen(filename)!=28 || StringSubstr(filename,24)!=".csv") return;
   for(int i=0;i<24;i++)
      if(StringFind("0123456789abcdef",StringSubstr(key,i,1))<0) return;
   string path=root+"inbox\\"+filename;
   if(FileIsExist(root+"receipts\\"+key+".csv")) { FileDelete(path); return; }
   int f=FileOpen(path,FILE_READ|FILE_CSV|FILE_ANSI,',');
   if(f==INVALID_HANDLE) return;
   string id=FileReadString(f);
   long sent=(long)StringToInteger(FileReadString(f));
   string symbol=FileReadString(f),side=FileReadString(f);
   double entry=StringToDouble(FileReadString(f)),sl=StringToDouble(FileReadString(f)),tp=StringToDouble(FileReadString(f));
   FileClose(f);
   // Claim on disk BEFORE any broker request. Ambiguous crashes never auto-retry.
   if(!Claim(key)) return;
   FileDelete(path);
   long age=(long)TimeGMT()-sent;
   if(id!=key || symbol!=BrokerSymbol || (side!="BUY" && side!="SELL") || entry<=0 || sl<=0 || tp<=0 || age < -5 || age>MaxSignalAgeSeconds)
   { Receipt(key,"REJECTED","Invalid, stale or mismatched signal"); return; }
   bool buy=side=="BUY";
   if(!(buy ? sl<entry && entry<tp : tp<entry && entry<sl))
   { Receipt(key,"REJECTED","Invalid reference bracket"); return; }
   if(!EnableTrading) { Receipt(key,"DRY_RUN",side+" "+symbol+" entry="+DoubleToString(entry,8)+" sl="+DoubleToString(sl,8)+" tp="+DoubleToString(tp,8)); return; }
   if(!AllowRealAccount && AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
   { Receipt(key,"REJECTED","Only demo accounts allowed"); return; }
   if(RequireHedgingAccount && AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   { Receipt(key,"REJECTED","Hedging account required"); return; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   { Receipt(key,"REJECTED","Algorithmic trading unavailable"); return; }
   MqlTick tick;
   if(!SymbolSelect(symbol,true) || !SymbolInfoTick(symbol,tick))
   { Receipt(key,"REJECTED","No broker quote"); return; }
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT),step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   double tickSize=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   if(point<=0 || step<=0 || tickSize<=0) { Receipt(key,"REJECTED","Invalid symbol properties"); return; }
   double price=buy ? tick.ask : tick.bid;
   if(!MathIsValidNumber(tick.ask) || !MathIsValidNumber(tick.bid) || tick.ask<=0 || tick.bid<=0 || tick.ask<tick.bid)
   { Receipt(key,"REJECTED","Invalid broker quote"); return; }
   double originalRisk=MathAbs(entry-sl);
   if(!MathIsValidNumber(originalRisk) || originalRisk<=0)
   { Receipt(key,"REJECTED","Invalid original SL distance"); return; }
   double spread=tick.ask-tick.bid;
   double spreadR=spread/originalRisk;
   double driftPoints=MathAbs(price-entry)/point;
   string costs=StringFormat("spread=%.8f spread_R=%.6f limit_R=%.6f original_R=%.8f drift_points=%.2f",spread,spreadR,MaxSpreadR,originalRisk,driftPoints);
   if(UseRiskRelativeSpread)
   {
      // Original signal risk is the denominator; entry drift cannot widen the allowance.
      if(spread>=MaxSpreadR*originalRisk)
      { Receipt(key,"REJECTED","Spread reached R limit: "+costs); return; }
   }
   else
   {
      if(spread/point>MaxSpreadPoints)
      { Receipt(key,"REJECTED","Legacy spread limit exceeded: "+costs); return; }
      if(driftPoints>MaxEntryDriftPoints)
      { Receipt(key,"REJECTED","Legacy entry drift limit exceeded: "+costs); return; }
   }
   Print("Bridge spread accepted: ",costs);
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   double adverseMove=buy ? entry-price : price-entry;
   bool pending=UseStopEntryOnAdverseMove && adverseMove>0 && adverseMove+tickSize*1e-8>=StopEntryThresholdPips*PipSize;
   // Round pending entry outward so it remains a stop order on the intended side.
   double orderEntry=pending ? NormalizeDouble((buy ? MathCeil(entry/tickSize) : MathFloor(entry/tickSize))*tickSize,digits) : price;
   double favorableMove=buy ? price-entry : entry-price;
   double originalTP=tp;
   if(!pending && ExtendTPForEntryMove && favorableMove>0 && favorableMove+tickSize*1e-8>=TPExtensionThresholdPips*PipSize)
   {
      // Preserve the original reward distance from the executable entry quote.
      // Apply once before submission, not repeatedly to an open position.
      tp += buy ? favorableMove : -favorableMove;
      PrintFormat("Bridge TP extension: movement=%.4f pips original=%.8f adjusted=%.8f",favorableMove/PipSize,originalTP,tp);
   }
   sl=NormalizeDouble(MathRound(sl/tickSize)*tickSize,digits);
   tp=NormalizeDouble(MathRound(tp/tickSize)*tickSize,digits);
   double stops=(double)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL)*point;
   double quote=buy ? tick.bid : tick.ask;
   bool validBracket=pending
      ? (buy ? orderEntry>tick.ask && orderEntry-tick.ask>=stops && sl<orderEntry && tp>orderEntry && orderEntry-sl>=stops && tp-orderEntry>=stops
             : orderEntry<tick.bid && tick.bid-orderEntry>=stops && sl>orderEntry && tp<orderEntry && sl-orderEntry>=stops && orderEntry-tp>=stops)
      : (buy ? sl<quote && tp>tick.ask && quote-sl>=stops && tp-quote>=stops : sl>quote && tp<tick.bid && sl-quote>=stops && quote-tp>=stops);
   if(!validBracket)
   { Receipt(key,"REJECTED","Bracket crossed or stops too close"); return; }
   double lots=0,estimatedRisk=0;
   string sizingError="";
   if(!CalculateLots(symbol,buy,orderEntry,sl,lots,estimatedRisk,sizingError))
   { Receipt(key,"REJECTED",sizingError); return; }
   PrintFormat("Bridge sizing: lots=%.8f estimated SL loss=%.2f %s target USD=%.2f (before commission/slippage)",lots,estimatedRisk,AccountInfoString(ACCOUNT_CURRENCY),RiskUSD);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(symbol);
   trade.SetAsyncMode(false);
   bool submitted=false;
   if(pending)
   {
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
      submitted=buy ? trade.BuyStop(lots,orderEntry,symbol,sl,tp,ORDER_TIME_GTC,0,"TV-"+key)
                    : trade.SellStop(lots,orderEntry,symbol,sl,tp,ORDER_TIME_GTC,0,"TV-"+key);
   }
   else submitted=buy ? trade.Buy(lots,symbol,0,sl,tp,"TV-"+key) : trade.Sell(lots,symbol,0,sl,tp,"TV-"+key);
   uint code=trade.ResultRetcode();
   string detail=StringFormat("retcode=%u order=%I64u deal=%I64u fill=%.8f %s",code,trade.ResultOrder(),trade.ResultDeal(),trade.ResultPrice(),trade.ResultRetcodeDescription());
   detail+=StringFormat(" tp=%.8f original_tp=%.8f",tp,originalTP);
   detail+=StringFormat(" entry_type=%s requested_entry=%.8f",pending ? (buy ? "BUY_STOP" : "SELL_STOP") : "MARKET",orderEntry);
   detail+=" "+costs;
   string status=submitted && code==TRADE_RETCODE_DONE ? "FILLED" : submitted && code==TRADE_RETCODE_DONE_PARTIAL ? "PARTIAL" : "CHECK_BROKER";
   if(pending && submitted && (code==TRADE_RETCODE_PLACED || code==TRADE_RETCODE_DONE)) status="PENDING_PLACED";
   Receipt(key,status,detail);
}

int OnInit()
{
   if(_Symbol!=BrokerSymbol || _Period!=PERIOD_M15)
   { Print("Attach to the configured USDJPY broker symbol on M15"); return INIT_PARAMETERS_INCORRECT; }
   if(UseRiskRelativeSpread && (!MathIsValidNumber(MaxSpreadR) || MaxSpreadR<=0))
   { Print("Maximum spread R must be positive"); return INIT_PARAMETERS_INCORRECT; }
   if(UseStopEntryOnAdverseMove && (!MathIsValidNumber(PipSize) || PipSize<=0 || !MathIsValidNumber(StopEntryThresholdPips) || StopEntryThresholdPips<=0))
   { Print("Pending entry requires positive pip size and threshold"); return INIT_PARAMETERS_INCORRECT; }
   if(ExtendTPForEntryMove && (!MathIsValidNumber(PipSize) || PipSize<=0 || !MathIsValidNumber(TPExtensionThresholdPips) || TPExtensionThresholdPips<0))
   { Print("TP extension requires a positive pip size and nonnegative threshold"); return INIT_PARAMETERS_INCORRECT; }
   if((LotSizing==FIXED_LOTS && (!MathIsValidNumber(FixedLots) || FixedLots<=0)) || (LotSizing==USD_RISK && (!MathIsValidNumber(RiskUSD) || RiskUSD<=0 || AccountInfoString(ACCOUNT_CURRENCY)!="USD")) || MaxSignalAgeSeconds<1 || MaxSpreadPoints<0 || MaxEntryDriftPoints<0)
   { Print("Invalid inputs: use positive lots/risk; USD risk requires USD account currency"); return INIT_PARAMETERS_INCORRECT; }
   FolderCreate("CodexBridgeUSDJPY"); FolderCreate(root+"inbox"); FolderCreate(root+"receipts");
   // Exclusive file handle prevents two EA instances consuming the same queue.
   lockHandle=FileOpen(root+"consumer.lock",FILE_READ|FILE_WRITE|FILE_BIN);
   if(lockHandle==INVALID_HANDLE) { Print("Another bridge EA may be attached"); return INIT_FAILED; }
   EventSetTimer(1);
   Print("Signal bridge ready; trading=",EnableTrading," data=",TerminalInfoString(TERMINAL_DATA_PATH));
   return INIT_SUCCEEDED;
}
void OnTimer()
{
   string name;
   long find=FileFindFirst(root+"inbox\\*.csv",name);
   if(find==INVALID_HANDLE) return;
   int count=0;
   do { Process(name); count++; } while(count<20 && FileFindNext(find,name));
   FileFindClose(find);
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(lockHandle!=INVALID_HANDLE) FileClose(lockHandle);
}
