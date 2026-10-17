#ifndef LOCAL_COPIER_PROTOCOL
#define LOCAL_COPIER_PROTOCOL
#include "CopyCore.mqh"

#define LTC_VERSION "2.00"
#define LTC_MAX_ROWS 4000
#define LTC_MAX_BYTES 2097152

struct LTCPosition
  {
   ulong key;
   string symbol;
   int side;
   double volume;
   double sl;
   double tp;
  };
struct LTCOrder
  {
   ulong key;
   string symbol;
   int type;
   double volume;
   double price;
   double stoplimit;
   double sl;
   double tp;
   int time_type;
   long expiration;
  };
struct LTCSnapshot
  {
   ulong sequence;
   ulong clock_ms;
   long login;
   string server;
   bool ready;
   LTCPosition positions[];
   LTCOrder orders[];
  };

bool LTCChannelValid(string channel)
  {
   if(StringLen(channel)<1 || StringLen(channel)>32) return false;
   for(int i=0;i<StringLen(channel);i++)
     {
      ushort c=StringGetCharacter(channel,i);
      if(!((c>='a' && c<='z') || (c>='A' && c<='Z') ||
           (c>='0' && c<='9') || c=='_' || c=='-')) return false;
     }
   return true;
  }
bool LTCFieldValid(string value)
  {
   return StringLen(value)>0 && StringFind(value,"\t")<0 &&
          StringFind(value,"\n")<0 && StringFind(value,"\r")<0;
  }
uint LTCHash(string data)
  {
   uint h=2166136261;
   for(int i=0;i<StringLen(data);i++)
      h=(h^(uint)StringGetCharacter(data,i))*16777619;
   return h;
  }
string LTCKey(ulong key) { return (string)key; }
string LTCNumber(double value) { return DoubleToString(value,10); }
string LTCFile(string channel) { return "LocalCopier\\"+channel+".snapshot"; }
string LTCComment(ulong key) { return "LTC:"+LTCKey(key); }
ulong LTCParseComment(string comment)
  {
   if(StringSubstr(comment,0,4)!="LTC:") return 0;
   string digits=StringSubstr(comment,4);
   if(StringLen(digits)<1 || StringLen(digits)>19) return 0;
   for(int i=0;i<StringLen(digits);i++)
     {
      ushort c=StringGetCharacter(digits,i);
      if(c<'0' || c>'9') return 0;
     }
   long key=StringToInteger(digits);
   return key>0 ? (ulong)key : 0;
  }
string LTCBody(LTCSnapshot &s)
  {
   string text="LTC1\t"+(string)s.sequence+"\t"+(string)s.clock_ms+"\t"+
               (string)s.login+"\t"+s.server+"\t"+(s.ready?"1":"0")+"\t"+
               (string)ArraySize(s.positions)+"\t"+(string)ArraySize(s.orders)+"\n";
   for(int i=0;i<ArraySize(s.positions);i++)
     {
      LTCPosition p=s.positions[i];
      text+="P\t"+LTCKey(p.key)+"\t"+p.symbol+"\t"+(string)p.side+"\t"+
            LTCNumber(p.volume)+"\t"+LTCNumber(p.sl)+"\t"+LTCNumber(p.tp)+"\n";
     }
   for(int i=0;i<ArraySize(s.orders);i++)
     {
      LTCOrder o=s.orders[i];
      text+="O\t"+LTCKey(o.key)+"\t"+o.symbol+"\t"+(string)o.type+"\t"+
            LTCNumber(o.volume)+"\t"+LTCNumber(o.price)+"\t"+LTCNumber(o.stoplimit)+
            "\t"+LTCNumber(o.sl)+"\t"+LTCNumber(o.tp)+"\t"+(string)o.time_type+
            "\t"+(string)o.expiration+"\n";
     }
   return text;
  }

bool LTCWrite(string channel,LTCSnapshot &s)
  {
   string body=LTCBody(s);
   string packet=body+"END\t"+(string)s.sequence+"\t"+(string)LTCHash(body)+"\n";
   StringReplace(packet,"\n","\r\n"); // FILE_TXT reader uses Windows line endings.
   // No FILE_SHARE_*: a reader cannot observe a file while it is being written.
   int f=FileOpen(LTCFile(channel),FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON,0,CP_UTF8);
   if(f==INVALID_HANDLE) return false;
   uint wrote=FileWriteString(f,packet);
   FileFlush(f);
   FileClose(f);
   return wrote>0;
  }

bool LTCFinitePositive(double x) { return MathIsValidNumber(x) && x>0; }
bool LTCFiniteNonnegative(double x) { return MathIsValidNumber(x) && x>=0; }

bool LTCRead(string channel,LTCSnapshot &s,string &reason)
  {
   int f=FileOpen(LTCFile(channel),FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON,0,CP_UTF8);
   if(f==INVALID_HANDLE) { reason="snapshot busy or missing"; return false; }
   if(FileSize(f)>LTC_MAX_BYTES || FileSize(f)<20)
     { FileClose(f); reason="invalid snapshot size"; return false; }
   string lines[];
   while(!FileIsEnding(f))
     {
      string line=FileReadString(f);
      if(line=="" && FileIsEnding(f)) break;
      int n=ArraySize(lines);
      if(n>LTC_MAX_ROWS+2) { FileClose(f); reason="too many rows"; return false; }
      ArrayResize(lines,n+1); lines[n]=line;
     }
   FileClose(f);
   int count=ArraySize(lines);
   if(count<2) { reason="truncated snapshot"; return false; }
   string h[],tail[];
   if(StringSplit(lines[0],'\t',h)!=8 || h[0]!="LTC1" ||
      StringSplit(lines[count-1],'\t',tail)!=3 || tail[0]!="END")
     { reason="bad snapshot framing"; return false; }
   int np=(int)StringToInteger(h[6]), no=(int)StringToInteger(h[7]);
   if(np<0 || no<0 || np+no>LTC_MAX_ROWS || count!=np+no+2)
     { reason="snapshot count mismatch"; return false; }
   string body="";
   for(int i=0;i<count-1;i++) body+=lines[i]+"\n";
   if(h[1]!=tail[1] || (uint)StringToInteger(tail[2])!=LTCHash(body))
     { reason="snapshot checksum mismatch"; return false; }
   s.sequence=(ulong)StringToInteger(h[1]);
   s.clock_ms=(ulong)StringToInteger(h[2]);
   s.login=StringToInteger(h[3]); s.server=h[4]; s.ready=(h[5]=="1");
   if(s.sequence==0 || s.login<=0 || !LTCFieldValid(s.server) || (h[5]!="0" && h[5]!="1"))
     { reason="bad snapshot identity"; return false; }
   ArrayResize(s.positions,np); ArrayResize(s.orders,no);
   for(int i=0;i<np;i++)
     {
      string x[];
      if(StringSplit(lines[i+1],'\t',x)!=7 || x[0]!="P")
        { reason="invalid position row"; return false; }
      LTCPosition p;
      p.key=(ulong)StringToInteger(x[1]); p.symbol=x[2];
      p.side=(int)StringToInteger(x[3]); p.volume=StringToDouble(x[4]);
      p.sl=StringToDouble(x[5]); p.tp=StringToDouble(x[6]);
      if(p.key==0 || !LTCFieldValid(p.symbol) || p.side<0 || p.side>1 ||
         !LTCFinitePositive(p.volume) || !LTCFiniteNonnegative(p.sl) || !LTCFiniteNonnegative(p.tp))
        { reason="invalid position values"; return false; }
      for(int j=0;j<i;j++) if(s.positions[j].key==p.key)
        { reason="duplicate position key"; return false; }
      s.positions[i]=p;
     }
   for(int i=0;i<no;i++)
     {
      string x[];
      if(StringSplit(lines[np+i+1],'\t',x)!=11 || x[0]!="O")
        { reason="invalid order row"; return false; }
      LTCOrder o;
      o.key=(ulong)StringToInteger(x[1]); o.symbol=x[2]; o.type=(int)StringToInteger(x[3]);
      o.volume=StringToDouble(x[4]); o.price=StringToDouble(x[5]); o.stoplimit=StringToDouble(x[6]);
      o.sl=StringToDouble(x[7]); o.tp=StringToDouble(x[8]);
      o.time_type=(int)StringToInteger(x[9]); o.expiration=StringToInteger(x[10]);
      if(o.key==0 || !LTCFieldValid(o.symbol) || o.type<2 || o.type>7 ||
         !LTCFinitePositive(o.volume) || !LTCFinitePositive(o.price) ||
         !LTCFiniteNonnegative(o.stoplimit) || !LTCFiniteNonnegative(o.sl) ||
         !LTCFiniteNonnegative(o.tp) || o.time_type<0 || o.time_type>3 || o.expiration<0)
        { reason="invalid pending values"; return false; }
      for(int j=0;j<i;j++) if(s.orders[j].key==o.key)
        { reason="duplicate pending key"; return false; }
      s.orders[i]=o;
     }
   reason="ok"; return true;
  }
int LTCPositionIndex(LTCSnapshot &s,ulong key)
  {
   for(int i=0;i<ArraySize(s.positions);i++) if(s.positions[i].key==key) return i;
   return -1;
  }
int LTCOrderIndex(LTCSnapshot &s,ulong key)
  {
   for(int i=0;i<ArraySize(s.orders);i++) if(s.orders[i].key==key) return i;
   return -1;
  }
#endif
