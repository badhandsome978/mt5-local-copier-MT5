#property strict
#property version "2.00"
#property description "Local MT5 copier. Source positions are authoritative. Hedging receiver required."
#include "CopyProtocol.mqh"
#include "CopyDesktop.mqh"

enum LTC_STOPS_MODE { SOURCE_TRIGGERED=0, MIRROR_BROKER_STOPS=1 };
input bool DesktopControl=true;               // Standalone window Start / Stop
input bool EnableCopy=false;                  // Manual mode only
input string Channel="pair1";
input long SourceLogin=0;                     // Required: source account number
input string SourceServer="";                // Required: exact source server name
input long CopierMagic=2601017001;            // Reserve exclusively for this copier
input LTC_LOTS_MODE LotsMode=LTC_EXACT;
input LTC_OPERATION LotsOperation=LTC_MULTIPLY;
input double LotsFactor=1.0;
input double FixedLots=0.01;
input LTC_ROUNDING LotsRounding=LTC_TRUNCATE;
input string SymbolMap="";                    // XAUUSD=XAUUSDm;EURUSD=EURUSD.a
input bool CopyEntryPending=true;
input LTC_STOPS_MODE StopsMode=SOURCE_TRIGGERED;
input int PollMilliseconds=50;
input int MaximumFeedAgeMs=2000;
input int SettleAfterTradeMs=250;
input int RetryAfterRejectMs=1500;
input int DeviationPoints=30;
input int MaximumSpreadPoints=0;              // 0 = no spread gate on entries
input double MaxLotsPerSourcePosition=100.0;
input double MaxTotalManagedLots=1000.0;       // Positions + outstanding entry orders
input int RecoveryToken=0;                    // Increment AFTER manual ambiguity check

struct LTCBackoff { string tag; ulong until_ms; };
LTCBackoff g_backoff[];
string g_map_from[],g_map_to[];
int g_lock=INVALID_HANDLE;
string g_namespace="",g_status="starting",g_log="";
ulong g_next_send=0,g_last_good=0,g_log_ms=0;
ulong g_connection_ready=0;
bool g_confirming=false;
bool g_cycle_issue=false;
MqlTradeRequest g_confirmation;
ulong g_confirm_order=0;
double g_expected_volume=0;
long g_login=0;
string g_server="";
LTCControl g_control;
bool g_enabled=false;
long g_source_login=0;
string g_source_server="",g_code="waiting";
int g_lots_mode=0,g_lots_operation=0,g_lots_rounding=0;
double g_factor=1,g_fixed=0.01;
ulong g_telemetry_after=0;

int ManagedPendingCount()
  {
   int n=0;
   for(int i=0;i<OrdersTotal();i++)
     { ulong t=OrderGetTicket(i),k=0; if(OwnOrder(t,k) && OrderGetInteger(ORDER_TYPE)>=2) n++; }
   return n;
  }
void DesktopSettings()
  {
   if(!DesktopControl)
     {
      g_enabled=EnableCopy; g_source_login=SourceLogin; g_source_server=SourceServer;
      g_lots_mode=LotsMode; g_lots_operation=LotsOperation; g_lots_rounding=LotsRounding;
      g_factor=LotsFactor; g_fixed=FixedLots; return;
     }
   LTCControl next;
   if(LTCReadControl(Channel,next)) g_control=next;
   g_enabled=false;
   if(!LTCFresh((double)GetTickCount64(),(double)g_control.clock_ms,2000) || !g_control.running) return;
   if(g_control.receiver_login!=g_login || g_control.receiver_server!=g_server ||
      StringCompare(g_control.receiver_path,TerminalInfoString(TERMINAL_DATA_PATH),false)!=0 ||
      (g_control.source_login==g_login && g_control.source_server==g_server)) return;
   g_source_login=g_control.source_login; g_source_server=g_control.source_server;
   g_lots_mode=g_control.mode; g_lots_operation=g_control.operation; g_lots_rounding=g_control.rounding;
   g_factor=g_control.factor; g_fixed=g_control.fixed_lots; g_enabled=true;
  }
bool BindSource()
  {
   double binding=(double)LTCHash(Channel+":"+(string)g_source_login+"@"+g_source_server);
   if(GlobalVariableCheck(g_namespace+"BIND") && GlobalVariableGet(g_namespace+"BIND")!=binding)
     { Status("Magic bound to another source. Inspect old trades before choosing a new magic."); return false; }
   if(!GlobalVariableCheck(g_namespace+"BIND"))
     {
      if(GlobalVariableSet(g_namespace+"BIND",binding)==0)
        { Status("Cannot persist source identity binding; refusing to trade"); return false; }
      GlobalVariablesFlush();
     }
   return true;
  }
bool UpdateBaselines(LTCSnapshot &s)
  {
   bool changed=false;
   for(int i=0;i<ArraySize(s.orders);i++)
     {
      if(LTCPositionIndex(s,s.orders[i].key)>=0) continue;
      string name=g_namespace+"V."+LTCKey(s.orders[i].key);
      if(!GlobalVariableCheck(name) || GlobalVariableGet(name)!=s.orders[i].volume)
        {
         if(GlobalVariableSet(name,s.orders[i].volume)==0) return false;
         changed=true;
        }
     }
   for(int i=0;i<ArraySize(s.positions);i++)
     {
      ulong key=s.positions[i].key;
      double total=s.positions[i].volume;
      int oi=LTCOrderIndex(s,key); if(oi>=0) total+=s.orders[oi].volume;
      string name=g_namespace+"V."+LTCKey(key);
      if(!GlobalVariableCheck(name) || GlobalVariableGet(name)<total)
        {
         if(GlobalVariableSet(name,total)==0) return false;
         changed=true;
        }
     }
   if(changed) GlobalVariablesFlush();
   return true;
  }

void Status(string message)
  {
   g_cycle_issue=true;
   g_status=message;
   ulong now=GetTickCount64();
   if(message!=g_log || now-g_log_ms>10000)
     { Print("LTC: ",message); g_log=message; g_log_ms=now; }
  }
string MapSymbol(string source)
  {
   for(int i=0;i<ArraySize(g_map_from);i++) if(g_map_from[i]==source) return g_map_to[i];
   return source;
  }
bool ParseMap()
  {
   if(SymbolMap=="") return true;
   string entries[];
   int n=StringSplit(SymbolMap,';',entries);
   for(int i=0;i<n;i++)
     {
      string entry=entries[i]; StringTrimLeft(entry); StringTrimRight(entry);
      if(entry=="") continue;
      string pair[];
      if(StringSplit(entry,'=',pair)!=2) return false;
      StringTrimLeft(pair[0]); StringTrimRight(pair[0]);
      StringTrimLeft(pair[1]); StringTrimRight(pair[1]);
      if(!LTCFieldValid(pair[0]) || !LTCFieldValid(pair[1])) return false;
      for(int j=0;j<ArraySize(g_map_from);j++) if(g_map_from[j]==pair[0]) return false;
      int size=ArraySize(g_map_from);
      ArrayResize(g_map_from,size+1); ArrayResize(g_map_to,size+1);
      g_map_from[size]=pair[0]; g_map_to[size]=pair[1];
     }
   return true;
  }
string QuarantineName(ulong key) { return g_namespace+"Q."+LTCKey(key); }
bool Quarantined(ulong key) { return GlobalVariableCheck(QuarantineName(key)); }
void Quarantine(ulong key)
  {
   GlobalVariableSet(QuarantineName(key),(double)TimeLocal());
   GlobalVariablesFlush();
   Status("Follower triggered early; virtualize pending source key "+LTCKey(key));
  }
bool Halted() { return GlobalVariableCheck(g_namespace+"HALT"); }
void ClearHalt()
  {
   GlobalVariableDel(g_namespace+"HALT"); GlobalVariablesFlush();
   g_confirming=false;
   g_next_send=GetTickCount64()+(ulong)SettleAfterTradeMs;
  }
bool CanAttempt(string tag)
  {
   for(int i=0;i<ArraySize(g_backoff);i++)
      if(g_backoff[i].tag==tag) return GetTickCount64()>=g_backoff[i].until_ms;
   return true;
  }
void Backoff(string tag)
  {
   int index=-1;
   for(int i=0;i<ArraySize(g_backoff);i++) if(g_backoff[i].tag==tag) { index=i; break; }
   if(index<0)
     {
      index=ArraySize(g_backoff);
      // Bound memory; expired diagnostics are disposable.
      if(index>=4096) { ArrayResize(g_backoff,0); index=0; }
      ArrayResize(g_backoff,index+1); g_backoff[index].tag=tag;
     }
   g_backoff[index].until_ms=GetTickCount64()+(ulong)RetryAfterRejectMs;
  }
bool TradeAllowed()
  {
   return TerminalInfoInteger(TERMINAL_CONNECTED) &&
          TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED) &&
          AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) && AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
  }

bool Send(MqlTradeRequest &request,string tag)
  {
   if(!CanAttempt(tag)) return false;
   MqlTradeCheckResult check={};
   if(!OrderCheck(request,check))
     {
      Backoff(tag); Status(tag+" check rejected: "+(string)check.retcode+" "+check.comment);
      return true;
     }
   // Durable intent BEFORE contacting the broker. A crash in this window pauses
   // trading on restart rather than risking an invisible duplicate request.
   if(GlobalVariableSet(g_namespace+"HALT",(double)TimeLocal())==0)
     { Status("Cannot persist trade intent; refusing to trade"); return true; }
   GlobalVariablesFlush();
   double before=0;
   if(request.action==TRADE_ACTION_DEAL)
     {
      if(request.position>0 && PositionSelectByTicket(request.position)) before=PositionGetDouble(POSITION_VOLUME);
      else if(request.position==0) before=KeyVolume(LTCParseComment(request.comment),request.symbol,(int)request.type);
     }
   MqlTradeResult result={};
   ResetLastError();
   bool sent=OrderSend(request,result);
   int local_error=GetLastError();
   bool known=(result.retcode==TRADE_RETCODE_DONE || result.retcode==TRADE_RETCODE_DONE_PARTIAL ||
               result.retcode==TRADE_RETCODE_NO_CHANGES ||
               (request.action==TRADE_ACTION_PENDING && result.retcode==TRADE_RETCODE_PLACED && result.order>0));
   bool uncertain=(!known && (result.retcode==TRADE_RETCODE_TIMEOUT ||
                   result.retcode==TRADE_RETCODE_CONNECTION || result.retcode==TRADE_RETCODE_ERROR ||
                   result.retcode==TRADE_RETCODE_PLACED || result.retcode==0));
   if(uncertain)
     {
      Status("AMBIGUOUS broker response: "+tag+" ret="+(string)result.retcode+
             ". Automatic sends paused; check account, then increment RecoveryToken.");
      return true;
     }
   if(known)
     {
      g_confirmation=request; g_confirm_order=result.order;
      double filled=result.volume;
      if(filled<=0 && result.retcode==TRADE_RETCODE_DONE) filled=request.volume;
      if(request.action==TRADE_ACTION_DEAL && filled<=0)
        { Status("Accepted trade has no confirmed fill size; paused for manual review"); return true; }
      g_expected_volume=(request.position>0?MathMax(0,before-filled):before+filled);
      g_confirming=true;
      g_next_send=GetTickCount64()+(ulong)SettleAfterTradeMs;
      Status(tag+" accepted; waiting for account-state confirmation: "+(string)result.retcode);
      return true;
     }
   ClearHalt();
   Backoff(tag);
   Status(tag+" rejected: "+(string)result.retcode+" "+result.comment+" local="+(string)local_error+
          " sent="+(sent?"true":"false"));
   return true;
  }
bool ResolveUncertainty()
  {
   if(!Halted()) return true;
   if(g_confirming)
     {
      if(GetTickCount64()<g_next_send) return false;
      bool confirmed=false;
      ENUM_TRADE_REQUEST_ACTIONS action=g_confirmation.action;
      if(action==TRADE_ACTION_DEAL)
        {
         double actual=0;
         if(g_confirmation.position>0)
           { if(PositionSelectByTicket(g_confirmation.position)) actual=PositionGetDouble(POSITION_VOLUME); }
         else actual=KeyVolume(LTCParseComment(g_confirmation.comment),g_confirmation.symbol,(int)g_confirmation.type);
         confirmed=MathAbs(actual-g_expected_volume)<=Epsilon(g_confirmation.symbol);
        }
      else if(action==TRADE_ACTION_PENDING)
        {
         confirmed=g_confirm_order>0 && OrderSelect(g_confirm_order);
         if(!confirmed && g_confirm_order>0 && HistoryOrderSelect(g_confirm_order))
            confirmed=HistoryOrderGetInteger(g_confirm_order,ORDER_STATE)==ORDER_STATE_FILLED;
        }
      else if(action==TRADE_ACTION_REMOVE)
         confirmed=!OrderSelect(g_confirmation.order);
      else if(action==TRADE_ACTION_SLTP)
        {
         if(!PositionSelectByTicket(g_confirmation.position)) confirmed=true;
         else
           {
            double eps=SymbolInfoDouble(g_confirmation.symbol,SYMBOL_TRADE_TICK_SIZE)*0.5;
            confirmed=MathAbs(PositionGetDouble(POSITION_SL)-g_confirmation.sl)<=eps &&
                      MathAbs(PositionGetDouble(POSITION_TP)-g_confirmation.tp)<=eps;
           }
        }
      else if(action==TRADE_ACTION_MODIFY)
        {
         if(!OrderSelect(g_confirmation.order)) confirmed=true;
         else
           {
            double eps=SymbolInfoDouble(OrderGetString(ORDER_SYMBOL),SYMBOL_TRADE_TICK_SIZE)*0.5;
            confirmed=MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-g_confirmation.price)<=eps &&
                      MathAbs(OrderGetDouble(ORDER_SL)-g_confirmation.sl)<=eps &&
                      MathAbs(OrderGetDouble(ORDER_TP)-g_confirmation.tp)<=eps &&
                      MathAbs(OrderGetDouble(ORDER_PRICE_STOPLIMIT)-g_confirmation.stoplimit)<=eps &&
                      OrderGetInteger(ORDER_TYPE_TIME)==g_confirmation.type_time &&
                      OrderGetInteger(ORDER_TIME_EXPIRATION)==(long)g_confirmation.expiration;
           }
        }
      if(confirmed) { ClearHalt(); g_next_send=0; Status("Broker effect confirmed; reconciling latest source state"); return true; }
      Status("Waiting for broker account-state confirmation; duplicate requests blocked"); return false;
     }
   Status("PAUSED: ambiguous/crash-pending request. Inspect trades, then increment RecoveryToken.");
   return false;
  }
bool OwnPosition(ulong ticket,ulong &key)
  {
   if(!PositionSelectByTicket(ticket) || PositionGetInteger(POSITION_MAGIC)!=CopierMagic) return false;
   key=LTCParseComment(PositionGetString(POSITION_COMMENT)); return true;
  }
bool OwnOrder(ulong ticket,ulong &key)
  {
   if(!OrderSelect(ticket) || OrderGetInteger(ORDER_MAGIC)!=CopierMagic) return false;
   key=LTCParseComment(OrderGetString(ORDER_COMMENT)); return true;
  }
bool Audit()
  {
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket=PositionGetTicket(i),key=0;
      if(ticket==0) { Status("Position list changed; retrying"); return false; }
      if(OwnPosition(ticket,key) && key==0)
        { Status("PAUSED: managed position has an unrecognized broker comment: "+(string)ticket); return false; }
     }
   for(int i=0;i<OrdersTotal();i++)
     {
      ulong ticket=OrderGetTicket(i),key=0;
      if(ticket==0) { Status("Order list changed; retrying"); return false; }
      if(OwnOrder(ticket,key))
        {
         if(key==0) { Status("PAUSED: managed order has an unrecognized comment"); return false; }
         if(OrderGetInteger(ORDER_TYPE)<2) { Status("Broker market order still in flight"); return false; }
        }
     }
   return true;
  }
bool Remove(ulong ticket,string why)
  {
   g_cycle_issue=true;
   MqlTradeRequest r={}; r.action=TRADE_ACTION_REMOVE; r.order=ticket; r.magic=(ulong)CopierMagic;
   return Send(r,"DELETE:"+(string)ticket+":"+why);
  }
bool CancelAllPending()
  {
   for(int i=0;i<OrdersTotal();i++)
     {
      ulong ticket=OrderGetTicket(i),key=0;
      if(OwnOrder(ticket,key) && OrderGetInteger(ORDER_TYPE)>=2 &&
         Remove(ticket,"feed unavailable")) return true;
     }
   return false;
  }
double Step(string symbol) { return SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP); }
double Epsilon(string symbol) { return MathMax(Step(symbol)*0.25,0.000000001); }
double Target(string symbol,double source_volume,ulong key,bool pending=false)
  {
   if(!SymbolSelect(symbol,true)) return -1;
   double baseline=source_volume;
   string name=g_namespace+"V."+LTCKey(key);
   if(!pending && GlobalVariableCheck(name)) baseline=GlobalVariableGet(name);
   double v=LTCLots(source_volume,g_lots_mode,g_lots_operation,g_factor,g_fixed,
                    g_lots_rounding,baseline,Step(symbol));
   if(v<0) return -1;
   if(v+Epsilon(symbol)<SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN)) return 0;
   return NormalizeDouble(v,8);
  }
double KeyVolume(ulong key,string symbol,int side)
  {
   double total=0;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong t=PositionGetTicket(i),k=0;
      if(OwnPosition(t,k) && k==key && PositionGetString(POSITION_SYMBOL)==symbol &&
         PositionGetInteger(POSITION_TYPE)==side) total+=PositionGetDouble(POSITION_VOLUME);
     }
   return total;
  }
bool HasPending(ulong key)
  {
   for(int i=0;i<OrdersTotal();i++)
     { ulong t=OrderGetTicket(i),k=0; if(OwnOrder(t,k) && k==key) return true; }
   return false;
  }
double CommittedLots()
  {
   double total=0;
   for(int i=0;i<PositionsTotal();i++)
     { ulong t=PositionGetTicket(i),k=0; if(OwnPosition(t,k)) total+=PositionGetDouble(POSITION_VOLUME); }
   for(int i=0;i<OrdersTotal();i++)
     { ulong t=OrderGetTicket(i),k=0; if(OwnOrder(t,k)) total+=OrderGetDouble(ORDER_VOLUME_CURRENT); }
   return total;
  }
bool FillMode(string symbol,ENUM_ORDER_TYPE_FILLING &fill)
  {
   long flags=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   if((flags&SYMBOL_FILLING_IOC)!=0) fill=ORDER_FILLING_IOC;
   else if((flags&SYMBOL_FILLING_FOK)!=0) fill=ORDER_FILLING_FOK;
   else if(SymbolInfoInteger(symbol,SYMBOL_TRADE_EXEMODE)!=SYMBOL_TRADE_EXECUTION_MARKET)
      fill=ORDER_FILLING_RETURN;
   else return false;
   return true;
  }
double Price(string symbol,double value)
  {
   double tick=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   if(value==0 || tick<=0) return value;
   return NormalizeDouble(MathRound(value/tick)*tick,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS));
  }
bool EntryAllowed(string symbol,int side)
  {
   long mode=SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
   if(mode==SYMBOL_TRADE_MODE_DISABLED || mode==SYMBOL_TRADE_MODE_CLOSEONLY ||
      (mode==SYMBOL_TRADE_MODE_LONGONLY && side==1) ||
      (mode==SYMBOL_TRADE_MODE_SHORTONLY && side==0)) return false;
   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick) || tick.bid<=0 || tick.ask<=0) return false;
   if(MaximumSpreadPoints>0 && tick.ask-tick.bid>
      MaximumSpreadPoints*SymbolInfoDouble(symbol,SYMBOL_POINT)) return false;
   return true;
  }
bool Market(ulong key,string symbol,int side,double volume,ulong position=0)
  {
   string tag=(position>0?"CLOSE:":"OPEN:")+(position>0?(string)position:LTCKey(key));
   if(!CanAttempt(tag)) return false;
   double step=Step(symbol),maximum=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   if(step<=0 || maximum<=0) { Status("Missing lot specification: "+symbol); return false; }
   double lots=NormalizeDouble(LTCTarget(MathMin(volume,maximum),1,step),8);
   double minimum=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   if(position>0 && volume-lots>Epsilon(symbol) && volume-lots<minimum-Epsilon(symbol))
      lots=NormalizeDouble(LTCTarget(volume-minimum,1,step),8);
   if(lots+Epsilon(symbol)<minimum)
     { Status("Volume below broker minimum: "+tag); return false; }
   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick) || tick.bid<=0 || tick.ask<=0) return false;
   MqlTradeRequest r={};
   r.action=TRADE_ACTION_DEAL; r.magic=(ulong)CopierMagic; r.symbol=symbol;
   r.position=position; r.volume=lots; r.type=(side==0?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   r.price=(side==0?tick.ask:tick.bid); r.deviation=(ulong)DeviationPoints;
   r.comment=LTCComment(key);
   if(!FillMode(symbol,r.type_filling)) { Status("Unsupported filling mode: "+symbol); return false; }
   return Send(r,tag);
  }
bool ClosePosition(ulong ticket,double reduce=0)
  {
   ulong key=0;
   if(!OwnPosition(ticket,key)) return false;
   string symbol=PositionGetString(POSITION_SYMBOL);
   int side=(int)PositionGetInteger(POSITION_TYPE);
   double actual=PositionGetDouble(POSITION_VOLUME);
   double amount=(reduce>0?MathMin(actual,reduce):actual);
   // Some brokers prohibit a sub-minimum partial close or residual position.
   // Rebuild this ticket from flat if an exact reduction cannot be submitted.
   double minimum=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN),eps=Epsilon(symbol);
   if(amount<minimum-eps || (actual-amount>eps && actual-amount<minimum-eps)) amount=actual;
   return Market(key,symbol,1-side,amount,ticket);
  }
void Stops(string symbol,int side,double requested_sl,double requested_tp,double &sl,double &tp)
  {
   sl=0; tp=0;
   if(StopsMode!=MIRROR_BROKER_STOPS) return;
   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick)) return;
   double gap=(double)MathMax(SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL),
                             SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL))*
                             SymbolInfoDouble(symbol,SYMBOL_POINT);
   double buffer=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   double ref=(side==0?tick.bid:tick.ask);
   double a=Price(symbol,requested_sl),b=Price(symbol,requested_tp);
   if(a>0 && (side==0?ref-a:a-ref)>gap+buffer) sl=a;
   if(b>0 && (side==0?b-ref:ref-b)>gap+buffer) tp=b;
  }

bool UrgentPending(LTCSnapshot &s,bool &blocked)
  {
   blocked=false;
   // Detect an early fill BEFORE any close; remember it across EA restarts.
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong t=PositionGetTicket(i),key=0;
      if(OwnPosition(t,key) && LTCPositionIndex(s,key)<0 && LTCOrderIndex(s,key)>=0 && !Quarantined(key))
         Quarantine(key);
     }
   for(int i=0;i<OrdersTotal();i++)
     {
      ulong ticket=OrderGetTicket(i),key=0;
      if(!OwnOrder(ticket,key)) continue;
      int oi=LTCOrderIndex(s,key),pi=LTCPositionIndex(s,key);
      if(oi>=0)
        {
         int source_type=s.orders[oi].type,local_type=(int)OrderGetInteger(ORDER_TYPE);
         if(((source_type==ORDER_TYPE_BUY_STOP_LIMIT && local_type==ORDER_TYPE_BUY_LIMIT) ||
             (source_type==ORDER_TYPE_SELL_STOP_LIMIT && local_type==ORDER_TYPE_SELL_LIMIT)) && !Quarantined(key))
            Quarantine(key);
        }
      if(!CopyEntryPending || oi<0 || pi>=0 || Quarantined(key))
        {
         blocked=true;
         if(Remove(ticket,"obsolete or source triggered")) return true;
        }
     }
   return false;
  }
bool CloseAndReduce(LTCSnapshot &s,bool &blocked)
  {
   blocked=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i),key=0;
      if(!OwnPosition(ticket,key)) continue;
      string local_symbol=PositionGetString(POSITION_SYMBOL);
      int local_side=(int)PositionGetInteger(POSITION_TYPE);
      double local_volume=PositionGetDouble(POSITION_VOLUME);
      int pi=LTCPositionIndex(s,key);
      if(pi<0)
        {
         blocked=true;
         if(ClosePosition(ticket)) return true;
         continue;
        }
      LTCPosition p=s.positions[pi];
      string symbol=MapSymbol(p.symbol);
      double target=Target(symbol,p.volume,p.key);
      if(target<0) { blocked=true; Status("Invalid/missing follower symbol: "+symbol); continue; }
      double total=KeyVolume(key,symbol,p.side);
      LTC_ACTION action=LTCDecide(true,local_symbol==symbol,local_side==p.side,
                                  target,local_symbol==symbol && local_side==p.side?total:local_volume,
                                  false,Epsilon(local_symbol));
      if(action==LTC_CLOSE || action==LTC_REDUCE)
        {
         blocked=true;
         if(ClosePosition(ticket,action==LTC_REDUCE?total-target:0)) return true;
        }
     }
   return false;
  }
bool OpenMissing(LTCSnapshot &s)
  {
   for(int i=0;i<ArraySize(s.positions);i++)
     {
      LTCPosition p=s.positions[i]; string symbol=MapSymbol(p.symbol);
      double target=Target(symbol,p.volume,p.key);
      if(target<0) { Status("Invalid/missing follower symbol: "+symbol); continue; }
      double actual=KeyVolume(p.key,symbol,p.side);
      LTC_ACTION action=LTCDecide(true,true,true,target,actual,HasPending(p.key),Epsilon(symbol));
      if(action!=LTC_OPEN) continue; // A pending cancellation must be observed first.
      g_cycle_issue=true;
      if(target>MaxLotsPerSourcePosition+Epsilon(symbol) ||
         CommittedLots()+target-actual>MaxTotalManagedLots+Epsilon(symbol))
        { Status("Entry blocked by configured lot cap, source key "+LTCKey(p.key)); continue; }
      if(!EntryAllowed(symbol,p.side)) { Status("Entry unavailable (quote/spread/trade mode): "+symbol); continue; }
      if(Market(p.key,symbol,p.side,target-actual)) return true;
     }
   return false;
  }
bool SyncStops(LTCSnapshot &s)
  {
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong ticket=PositionGetTicket(i),key=0;
      if(!OwnPosition(ticket,key)) continue;
      int pi=LTCPositionIndex(s,key); if(pi<0) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      double current_sl=PositionGetDouble(POSITION_SL),current_tp=PositionGetDouble(POSITION_TP);
      double sl,tp;
      Stops(symbol,s.positions[pi].side,s.positions[pi].sl,s.positions[pi].tp,sl,tp);
      double eps=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE)*0.5;
      if(MathAbs(current_sl-sl)<=eps && MathAbs(current_tp-tp)<=eps) continue;
      g_cycle_issue=true;
      MqlTradeRequest r={}; r.action=TRADE_ACTION_SLTP; r.position=ticket;
      r.symbol=symbol; r.magic=(ulong)CopierMagic; r.sl=sl; r.tp=tp;
      if(Send(r,"STOPS:"+(string)ticket)) return true;
     }
   return false;
  }
bool PendingSpec(LTCOrder &source,MqlTradeRequest &r)
  {
   string symbol=MapSymbol(source.symbol);
   double volume=Target(symbol,source.volume,source.key,true);
   if(volume<=0 || volume>MaxLotsPerSourcePosition+Epsilon(symbol) ||
      volume>SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX)+Epsilon(symbol)) return false;
   int side=(source.type==ORDER_TYPE_BUY_LIMIT || source.type==ORDER_TYPE_BUY_STOP ||
             source.type==ORDER_TYPE_BUY_STOP_LIMIT)?0:1;
   if(!EntryAllowed(symbol,side)) return false;
   r.action=TRADE_ACTION_PENDING; r.magic=(ulong)CopierMagic; r.symbol=symbol;
   r.volume=volume; r.type=(ENUM_ORDER_TYPE)source.type;
   r.price=Price(symbol,source.price); r.stoplimit=Price(symbol,source.stoplimit);
   r.type_time=(ENUM_ORDER_TYPE_TIME)source.time_type; r.expiration=(datetime)source.expiration;
   r.type_filling=ORDER_FILLING_RETURN; r.comment=LTCComment(source.key);
   // Stops on a pending order are relative to its entry price, not today's quote.
   if(StopsMode==MIRROR_BROKER_STOPS)
     { r.sl=Price(symbol,source.sl); r.tp=Price(symbol,source.tp); }
   return true;
  }
bool SyncPending(LTCSnapshot &s)
  {
   if(!CopyEntryPending) return false;
   for(int i=0;i<ArraySize(s.orders);i++)
     {
      LTCOrder source=s.orders[i];
      // Partially filled source orders are virtualized; its actual filled volume
      // is reconciled first, without a second autonomous trigger on the follower.
      if(LTCPositionIndex(s,source.key)>=0 || Quarantined(source.key)) continue;
      MqlTradeRequest r={};
      if(!PendingSpec(source,r))
        {
         // A formerly valid order must not keep its old volume/risk when the
         // current source spec can no longer be represented on this broker.
         for(int j=0;j<OrdersTotal();j++)
           {
            ulong ticket=OrderGetTicket(j),key=0;
            if(OwnOrder(ticket,key) && key==source.key && Remove(ticket,"spec unavailable")) return true;
           }
         Status("Pending unavailable; will market-follow if source fills: "+LTCKey(source.key)); continue;
        }
      ulong existing=0;
      for(int j=0;j<OrdersTotal();j++)
        {
         ulong ticket=OrderGetTicket(j),key=0;
         if(OwnOrder(ticket,key) && key==source.key)
           {
            if(existing!=0) { if(Remove(ticket,"duplicate")) return true; }
            else existing=ticket;
           }
        }
      if(existing>0 && OrderSelect(existing))
        {
         if(OrderGetString(ORDER_SYMBOL)!=r.symbol || OrderGetInteger(ORDER_TYPE)!=r.type ||
            MathAbs(OrderGetDouble(ORDER_VOLUME_CURRENT)-r.volume)>Epsilon(r.symbol))
           { if(Remove(existing,"type, symbol or size changed")) return true; continue; }
         double eps=SymbolInfoDouble(r.symbol,SYMBOL_TRADE_TICK_SIZE)*0.5;
         if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-r.price)<=eps &&
            MathAbs(OrderGetDouble(ORDER_PRICE_STOPLIMIT)-r.stoplimit)<=eps &&
            MathAbs(OrderGetDouble(ORDER_SL)-r.sl)<=eps && MathAbs(OrderGetDouble(ORDER_TP)-r.tp)<=eps &&
            OrderGetInteger(ORDER_TYPE_TIME)==r.type_time &&
            OrderGetInteger(ORDER_TIME_EXPIRATION)==(long)r.expiration) continue;
         r.action=TRADE_ACTION_MODIFY; r.order=existing;
         g_cycle_issue=true;
         if(Send(r,"MODIFY:"+(string)existing)) return true;
        }
      else
        {
         g_cycle_issue=true;
         if(CommittedLots()+r.volume>MaxTotalManagedLots+Epsilon(r.symbol))
           { Status("Pending blocked by total lot cap: "+LTCKey(source.key)); continue; }
         if(Send(r,"PENDING:"+LTCKey(source.key))) return true;
        }
     }
   return false;
  }
void Panel()
  {
   Comment("LOCAL COPIER / RECEIVER ",LTC_VERSION,
           "\n",(g_enabled?"ENABLED":"STOPPED / waiting for desktop"),"  Channel: ",Channel,
           "\nSource: ",g_source_login," @ ",g_source_server,
           "\nFollower: ",g_login," @ ",g_server,"  Magic: ",CopierMagic,
           "\nStops: ",(StopsMode==SOURCE_TRIGGERED?"SOURCE TRIGGERED (no local SL/TP)":"MIRROR BROKER STOPS"),
           "\nLots mode: ",g_lots_mode,"  Factor: ",DoubleToString(g_factor,4),
           "\nStatus: ",g_status,
           "\nPriority: cancel obsolete orders > close/reduce > open > stops/pending");
  }
void Cycle()
  {
   g_cycle_issue=false;
   g_code="issue";
   DesktopSettings();
   if(AccountInfoInteger(ACCOUNT_LOGIN)!=g_login || AccountInfoString(ACCOUNT_SERVER)!=g_server)
     { Status("Account changed; remove and reattach EA"); return; }
   if(!TradeAllowed())
     {
      g_connection_ready=GetTickCount64()+2000;
      Status("Waiting for connection / Algo Trading / account permissions"); return;
     }
   if(GetTickCount64()<g_connection_ready)
     { Status("Connection warm-up: waiting for account state to synchronize"); return; }
   if(!ResolveUncertainty() || GetTickCount64()<g_next_send) return;
   if(!Audit()) return;
   if(!g_enabled)
     {
      if(DesktopControl && ManagedPendingCount()>0)
        { g_code="stopping"; Status("Stopped: cancelling managed entry pending orders"); CancelAllPending(); return; }
      g_code="stopped"; Status("Stopped; existing positions retained"); return;
     }
   if(!BindSource()) return;
   LTCSnapshot s; string reason;
   if(!LTCRead(Channel,s,reason))
     {
      Status("No verified feed: "+reason);
      if(!LTCFresh((double)GetTickCount64(),(double)g_last_good,MaximumFeedAgeMs)) CancelAllPending();
      return;
     }
   if(s.login!=g_source_login || s.server!=g_source_server)
     {
      Status("Source identity mismatch; holding positions and cancelling managed entry orders");
      CancelAllPending(); return;
     }
   if(!s.ready || !LTCFresh((double)GetTickCount64(),(double)s.clock_ms,MaximumFeedAgeMs))
     {
      Status("Source disconnected/stale: holding positions, cancelling managed entry orders");
      CancelAllPending(); return;
     }
   g_last_good=s.clock_ms;
   if(!UpdateBaselines(s)) { Status("Cannot persist source volume baseline; refusing to trade"); return; }
   // Broker effects are handled one request at a time, followed by a fresh read.
   bool pending_risk=false;
   if(UrgentPending(s,pending_risk)) return;
   bool risk_block=false;
   if(CloseAndReduce(s,risk_block)) return;
   // Never increase exposure while an obsolete/excess position remains unclosed.
   if(risk_block || pending_risk) { Status("Close/reduction/order cancellation unresolved; all new exposure paused"); return; }
   if(OpenMissing(s)) return;
   if(SyncStops(s)) return;
   if(SyncPending(s)) return;
   if(!g_cycle_issue) { g_code="ready"; Status("In sync with fresh source state; virtualized orders wait for source fills"); }
  }
int OnInit()
  {
   if(!LTCChannelValid(Channel) || (!DesktopControl && (SourceLogin<=0 || !LTCFieldValid(SourceServer))) || CopierMagic<=0 ||
      !LTCFinitePositive(LotsFactor) || !LTCFinitePositive(FixedLots) || PollMilliseconds<20 || PollMilliseconds>1000 ||
      MaximumFeedAgeMs<500 || MaximumFeedAgeMs>30000 || SettleAfterTradeMs<100 || SettleAfterTradeMs>10000 ||
      RetryAfterRejectMs<250 || DeviationPoints<0 || MaximumSpreadPoints<0 || RecoveryToken<0 ||
      !LTCFinitePositive(MaxLotsPerSourcePosition) || !LTCFinitePositive(MaxTotalManagedLots) || !ParseMap())
     { Print("Invalid inputs. SourceLogin and exact SourceServer are REQUIRED."); return INIT_PARAMETERS_INCORRECT; }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     { Print("Receiver must be a HEDGING account; netting would merge manual and copied positions."); return INIT_FAILED; }
   g_login=AccountInfoInteger(ACCOUNT_LOGIN); g_server=AccountInfoString(ACCOUNT_SERVER);
   g_connection_ready=GetTickCount64()+2000;
   if(g_login<=0 || (SourceLogin==g_login && SourceServer==g_server))
     { Print("Source and receiver must be different accounts."); return INIT_FAILED; }
   string identity=(string)g_login+"@"+g_server+":"+(string)CopierMagic;
   g_namespace="LTC."+(string)LTCHash(identity)+".";
   FolderCreate("LocalCopier",FILE_COMMON);
   g_lock=FileOpen("LocalCopier\\receiver_"+(string)LTCHash(identity)+".lock",FILE_WRITE|FILE_BIN|FILE_COMMON);
   if(g_lock==INVALID_HANDLE)
     { Print("Another receiver owns this account + magic."); return INIT_FAILED; }
   if(RecoveryToken>0 && (!GlobalVariableCheck(g_namespace+"RECOVERY") ||
      GlobalVariableGet(g_namespace+"RECOVERY")!=(double)RecoveryToken))
     { ClearHalt(); GlobalVariableSet(g_namespace+"RECOVERY",RecoveryToken); }
   GlobalVariablesFlush();
   if(!EventSetMillisecondTimer(PollMilliseconds)) return INIT_FAILED;
   Status("Waiting for a fresh source snapshot"); Panel(); return INIT_SUCCEEDED;
  }
void OnTimer()
  {
   Cycle(); Panel();
   if(GetTickCount64()>=g_telemetry_after)
     {
      string code=(!DesktopControl?"manual":(Halted() && !g_confirming?"halted":g_code));
      LTCWriteStatus(Channel,"receiver",g_login,g_server,g_enabled,ManagedPendingCount(),code,g_status,TradeAllowed());
      g_telemetry_after=GetTickCount64()+250;
     }
  }
void OnDeinit(const int reason)
  {
   EventKillTimer(); if(g_lock!=INVALID_HANDLE) FileClose(g_lock);
   LTCWriteStatus(Channel,"receiver",g_login,g_server,false,ManagedPendingCount(),"offline","Receiver removed",false);
   // Detaching an EA never liquidates positions or silently deletes orders.
   Comment("");
  }
