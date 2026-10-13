// Shared by XAUUSDSignalEA and USDJPYSignalEA. Calendar timestamps are UTC.
input bool EnableNewsProtection = true;
input int MediumNewsLeadMinutes = 15;
input int HighNewsLeadMinutes = 30;
input int NewsResumeMinutes = 15;
input int NewsMaxCacheAgeMinutes = 720;
input bool BlockEntriesWithoutCalendar = true;

long newsTimes[];
string newsCurrencies[],newsImpacts[];
long newsFetched=0,newsUntil=0;
long newsLastAttempt=0;
string newsLastStatus="";

bool NewsInputsValid()
{
   return MediumNewsLeadMinutes>=0 && HighNewsLeadMinutes>=0 && NewsResumeMinutes>=0 && NewsMaxCacheAgeMinutes>0;
}

void LoadNewsCalendar()
{
   int f=FileOpen("CodexNews\\calendar.csv",FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(f==INVALID_HANDLE) return; // Retain the last good in-memory schedule.
   string fields[];
   int n=StringSplit(FileReadString(f),',',fields);
   if(n!=4 || fields[0]!="FFNEWS1") { FileClose(f); return; }
   long fetched=StringToInteger(fields[1]),until=StringToInteger(fields[2]);
   int count=(int)StringToInteger(fields[3]);
   long now=(long)TimeGMT();
   if(fetched<=0 || fetched>now+60 || until<=fetched || count<0 || count>5000)
   { FileClose(f); return; }
   long times[]; string currencies[],impacts[];
   ArrayResize(times,count); ArrayResize(currencies,count); ArrayResize(impacts,count);
   bool valid=true;
   for(int i=0;i<count;i++)
   {
      if(FileIsEnding(f)) { valid=false; break; }
      n=StringSplit(FileReadString(f),',',fields);
      if(n!=3) { valid=false; break; }
      times[i]=StringToInteger(fields[0]); currencies[i]=fields[1]; impacts[i]=fields[2];
      if(times[i]<=0 || (currencies[i]!="USD" && currencies[i]!="JPY" && currencies[i]!="All") || (impacts[i]!="Medium" && impacts[i]!="High"))
      { valid=false; break; }
   }
   FileClose(f);
   if(!valid) return;
   ArrayCopy(newsTimes,times); ArrayResize(newsTimes,count);
   ArrayCopy(newsCurrencies,currencies); ArrayResize(newsCurrencies,count);
   ArrayCopy(newsImpacts,impacts); ArrayResize(newsImpacts,count);
   newsFetched=fetched; newsUntil=until;
}

bool NewsWindow(string &reason)
{
   long now=(long)TimeGMT();
   for(int i=0;i<ArraySize(newsTimes);i++)
   {
      if(newsCurrencies[i]!="USD" && newsCurrencies[i]!="All" && !(NEWS_INCLUDE_JPY && newsCurrencies[i]=="JPY")) continue;
      int lead=newsImpacts[i]=="High" ? HighNewsLeadMinutes : MediumNewsLeadMinutes;
      if(now>=newsTimes[i]-(long)lead*60 && now<newsTimes[i]+(long)NewsResumeMinutes*60)
      {
         reason=newsCurrencies[i]+" "+newsImpacts[i]+" news at "+TimeToString((datetime)newsTimes[i],TIME_DATE|TIME_MINUTES)+" UTC";
         return true;
      }
   }
   return false;
}

bool NewsEntryBlocked(string &reason)
{
   if(!EnableNewsProtection) return false;
   if(NewsWindow(reason)) return true;
   long now=(long)TimeGMT();
   if(BlockEntriesWithoutCalendar && (newsFetched<=0 || now-newsFetched>(long)NewsMaxCacheAgeMinutes*60 || now<newsFetched-60 || now>=newsUntil))
   { reason="Forex Factory calendar missing, stale, or outside weekly coverage"; return true; }
   return false;
}

void ManageNews()
{
   if(!EnableNewsProtection) return;
   LoadNewsCalendar();
   string reason="";
   bool window=NewsWindow(reason);
   bool blocked=NewsEntryBlocked(reason);
   string status=blocked ? reason : "Calendar ready; outside news window";
   if(status!=newsLastStatus) { Print("NEWS: ",status); newsLastStatus=status; }
   // Missing data blocks entries but must never invent an event or liquidate positions.
   if(!window || !EnableTrading) return;
   if(!AllowRealAccount && AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) return;
   long now=(long)TimeGMT();
   if(now-newsLastAttempt<5) return;
   newsLastAttempt=now;
   trade.SetAsyncMode(false);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(BrokerSymbol);
   // All trades on this exact broker symbol, including manual/other magic numbers.
   // Cancel pending orders first, then close by ticket to cover hedging accounts.
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || OrderGetString(ORDER_SYMBOL)!=BrokerSymbol) continue;
      bool ok=trade.OrderDelete(ticket);
      PrintFormat("NEWS cancel #%I64u requested=%s retcode=%u %s",ticket,ok ? "true" : "false",trade.ResultRetcode(),trade.ResultRetcodeDescription());
   }
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=BrokerSymbol) continue;
      bool ok=trade.PositionClose(ticket,DeviationPoints);
      PrintFormat("NEWS close #%I64u requested=%s retcode=%u %s",ticket,ok ? "true" : "false",trade.ResultRetcode(),trade.ResultRetcodeDescription());
   }
   // Unclosed positions/uncancelled orders remain in the lists and retry in 5 seconds.
}
