#property strict
#property version "2.00"
#property description "Local MT5 copier: publish authoritative account snapshots. No trading."
#include "CopyProtocol.mqh"
#include "CopyDesktop.mqh"

input string Channel="pair1"; // Same channel on both terminals
input int PollMilliseconds=50;
input int TransactionSettleMilliseconds=50;

int g_lock=INVALID_HANDLE;
ulong g_sequence=0,g_last_trade=0;
ulong g_connected_after=0;
ulong g_status_after=0;
long g_login=0;
string g_server="";

bool Capture(LTCSnapshot &s)
  {
   s.login=AccountInfoInteger(ACCOUNT_LOGIN);
   s.server=AccountInfoString(ACCOUNT_SERVER);
   s.ready=(bool)TerminalInfoInteger(TERMINAL_CONNECTED) &&
           s.login==g_login && s.server==g_server && GetTickCount64()>=g_connected_after;
   int np=PositionsTotal(),no=OrdersTotal();
   if(np+no>LTC_MAX_ROWS) return false;
   ArrayResize(s.positions,np); ArrayResize(s.orders,0);
   for(int i=0;i<np;i++)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) return false;
      LTCPosition p;
      p.key=(ulong)PositionGetInteger(POSITION_IDENTIFIER);
      p.symbol=PositionGetString(POSITION_SYMBOL);
      p.side=(int)PositionGetInteger(POSITION_TYPE);
      p.volume=PositionGetDouble(POSITION_VOLUME);
      p.sl=PositionGetDouble(POSITION_SL); p.tp=PositionGetDouble(POSITION_TP);
      if(p.key==0 || !LTCFieldValid(p.symbol)) return false;
      s.positions[i]=p;
     }
   for(int i=0;i<no;i++)
     {
      if(OrderGetTicket(i)==0) return false;
      int type=(int)OrderGetInteger(ORDER_TYPE);
      if(type<2 || type>7) return false; // A market order is still in flight.
      LTCOrder o;
      o.key=(ulong)OrderGetInteger(ORDER_TICKET); o.symbol=OrderGetString(ORDER_SYMBOL);
      o.type=type; o.volume=OrderGetDouble(ORDER_VOLUME_CURRENT);
      o.price=OrderGetDouble(ORDER_PRICE_OPEN); o.stoplimit=OrderGetDouble(ORDER_PRICE_STOPLIMIT);
      o.sl=OrderGetDouble(ORDER_SL); o.tp=OrderGetDouble(ORDER_TP);
      o.time_type=(int)OrderGetInteger(ORDER_TYPE_TIME);
      o.expiration=OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(o.volume<=0 || !LTCFieldValid(o.symbol)) return false;
      int n=ArraySize(s.orders); ArrayResize(s.orders,n+1); s.orders[n]=o;
     }
   return np==PositionsTotal() && no==OrdersTotal();
  }

void Publish()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) g_connected_after=GetTickCount64()+2000;
   if(GetTickCount64()-g_last_trade<(ulong)TransactionSettleMilliseconds) return;
   LTCSnapshot a,b;
   if(!Capture(a) || !Capture(b)) return;
   // Compare two complete reads; an incomplete/unstable view must not look flat.
   a.sequence=1; b.sequence=1; a.clock_ms=1; b.clock_ms=1;
   if(LTCBody(a)!=LTCBody(b)) return;
   a.sequence=++g_sequence; a.clock_ms=GetTickCount64();
   bool ok=LTCWrite(Channel,a);
   if(GetTickCount64()>=g_status_after)
     {
      LTCWriteStatus(Channel,"source",g_login,g_server,a.ready,ArraySize(a.orders),
                     a.ready?"ready":"waiting","Source snapshot",a.ready);
      g_status_after=GetTickCount64()+250;
     }
   Comment("LOCAL COPIER / SOURCE ",LTC_VERSION,"\nChannel: ",Channel,
           "\nAccount: ",g_login," @ ",g_server,
           "\nPositions: ",ArraySize(a.positions),"  Pending: ",ArraySize(a.orders),
           "\nFeed: ",(ok && a.ready ? "READY" : "NOT READY / receiver must pause"),
           "\nSequence: ",g_sequence,"\nNo trades are sent by this EA.");
  }
int OnInit()
  {
   if(!LTCChannelValid(Channel) || PollMilliseconds<20 || PollMilliseconds>1000 ||
      TransactionSettleMilliseconds<0 || TransactionSettleMilliseconds>500)
      return INIT_PARAMETERS_INCORRECT;
   g_login=AccountInfoInteger(ACCOUNT_LOGIN); g_server=AccountInfoString(ACCOUNT_SERVER);
   g_connected_after=GetTickCount64()+2000;
   if(g_login<=0 || !LTCFieldValid(g_server)) return INIT_FAILED;
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     { Print("Source must be HEDGING. Netting pending orders can reduce/reverse instead of opening a separate position."); return INIT_FAILED; }
   FolderCreate("LocalCopier",FILE_COMMON);
   g_lock=FileOpen("LocalCopier\\"+Channel+".source.lock",FILE_WRITE|FILE_BIN|FILE_COMMON);
   if(g_lock==INVALID_HANDLE)
     { Print("Another source already owns channel ",Channel); return INIT_FAILED; }
   if(!EventSetMillisecondTimer(PollMilliseconds)) return INIT_FAILED;
   Publish(); return INIT_SUCCEEDED;
  }
void OnTimer() { Publish(); }
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,
                        const MqlTradeResult &result) { g_last_trade=GetTickCount64(); }
void OnDeinit(const int reason)
  {
   EventKillTimer();
   // Leave an explicit invalid heartbeat instead of a seemingly live empty account.
   if(g_lock!=INVALID_HANDLE)
     {
      LTCSnapshot s; s.sequence=++g_sequence; s.clock_ms=GetTickCount64();
      s.login=g_login; s.server=g_server; s.ready=false;
      LTCWrite(Channel,s); FileClose(g_lock);
      LTCWriteStatus(Channel,"source",g_login,g_server,false,0,"stopped","Source removed",false);
     }
   Comment("");
  }
