#property strict
#property version "1.00"
#property description "Offline file protocol checks only. NEVER sends any trade."
#include "../Experts/LocalCopier/CopyProtocol.mqh"

int passed=0,failed=0;
void Check(bool ok,string label)
  {
   if(ok) passed++; else failed++;
   Print((ok?"PASS ":"FAIL "),label);
  }
bool Raw(string channel,string content)
  {
   int f=FileOpen(LTCFile(channel),FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON,0,CP_UTF8);
   if(f==INVALID_HANDLE) return false;
   FileWriteString(f,content); FileClose(f); return true;
  }
string Framed(string body,ulong seq)
  {
   string text=body+"END\t"+(string)seq+"\t"+(string)LTCHash(body)+"\n";
   StringReplace(text,"\n","\r\n"); return text;
  }
void OnStart()
  {
   string channel="selftest_"+(string)GetTickCount64();
   FolderCreate("LocalCopier",FILE_COMMON);
   LTCSnapshot s,t;
   s.sequence=123; s.clock_ms=GetTickCount64(); s.login=987654321;
   s.server="DEMO-服务器"; s.ready=true;
   ArrayResize(s.positions,1); ArrayResize(s.orders,1);
   s.positions[0].key=1234567890123456;
   s.positions[0].symbol="XAUUSDm"; s.positions[0].side=0;
   s.positions[0].volume=.03; s.positions[0].sl=2300; s.positions[0].tp=2600;
   s.orders[0].key=1234567890123457; s.orders[0].symbol="EURUSD";
   s.orders[0].type=ORDER_TYPE_BUY_STOP_LIMIT; s.orders[0].volume=.04;
   s.orders[0].price=1.15; s.orders[0].stoplimit=1.149;
   s.orders[0].sl=1.14; s.orders[0].tp=1.17;
   s.orders[0].time_type=ORDER_TIME_SPECIFIED; s.orders[0].expiration=1900000000;
   string reason="";
   Check(LTCWrite(channel,s),"write UTF-8 snapshot");
   bool ok=LTCRead(channel,t,reason);
   Check(ok,"read back snapshot: "+reason);
   if(ok)
     {
      Check(LTCBody(s)==LTCBody(t),"all values and Unicode round trip");
      Check(t.positions[0].key==1234567890123456,"64-bit identifiers preserved");
     }
   int lock=FileOpen(LTCFile(channel),FILE_READ|FILE_BIN|FILE_COMMON);
   Check(lock!=INVALID_HANDLE,"acquire exclusive reader lock");
   if(lock!=INVALID_HANDLE)
     {
      Check(!LTCWrite(channel,s),"writer blocked while reader owns file");
      FileClose(lock);
     }
   Check(LTCRead(channel,t,reason),"failed write lock does not truncate existing snapshot");
   Check(Raw(channel,"LTC1\t123\t456\t789\tDemo\t1\t0\t0\r\n"),"write truncated fixture");
   Check(!LTCRead(channel,t,reason),"reject truncated snapshot (never infer flat)");
   string body=LTCBody(s),bad=body;
   StringReplace(bad,"XAUUSDm","XAUUSDx");
   string packet=bad+"END\t123\t"+(string)LTCHash(body)+"\n";
   StringReplace(packet,"\n","\r\n"); Raw(channel,packet);
   Check(!LTCRead(channel,t,reason),"reject changed row / checksum mismatch");
   string duplicate="LTC1\t123\t456\t789\tDemo\t1\t2\t0\n"+
                    "P\t99\tEURUSD\t0\t1\t0\t0\nP\t99\tEURUSD\t0\t1\t0\t0\n";
   Raw(channel,Framed(duplicate,123));
   Check(!LTCRead(channel,t,reason),"reject duplicate source identifiers");
   ArrayResize(s.positions,0); ArrayResize(s.orders,0);
   LTCWrite(channel,s);
   Check(LTCRead(channel,t,reason) && ArraySize(t.positions)==0 && ArraySize(t.orders)==0,
         "valid authoritative flat account accepted");
   Check(LTCParseComment(LTCComment(1234567890123456))==1234567890123456,"comment key round trip");
   Check(LTCParseComment("LTC:123 garbage")==0,"unrecognized broker comment rejected");
   Check(!LTCChannelValid("../escape"),"path traversal channel rejected");
   Check(!LTCFresh(100,200,2000),"pre-reboot/future clock rejected");
   FileDelete(LTCFile(channel),FILE_COMMON);
   string summary="Protocol self-test: "+(string)passed+" passed, "+(string)failed+" failed";
   Print(summary);
   int report=FileOpen("LocalCopier\\selftest-result.txt",FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(report!=INVALID_HANDLE) { FileWriteString(report,summary); FileClose(report); }
  }
