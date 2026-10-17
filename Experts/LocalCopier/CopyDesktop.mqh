#ifndef LTC_DESKTOP
#define LTC_DESKTOP
struct LTCControl
  {
   bool running;
   ulong clock_ms;
   long source_login,receiver_login;
   string source_server,receiver_server,source_path,receiver_path;
   int mode,operation,rounding;
   double factor,fixed_lots;
  };
bool LTCReadControl(string channel,LTCControl &c)
  {
   int f=FileOpen("LocalCopier\\"+channel+".control",FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON,0,CP_UTF8);
   if(f==INVALID_HANDLE) return false;
   if(FileSize(f)>16384) { FileClose(f); return false; }
   string line=FileReadString(f),tail=FileReadString(f);
   bool end=FileIsEnding(f); FileClose(f);
   string x[],t[];
   if(!end || StringSplit(line,'\t',x)!=14 || x[0]!="LTCCTRL2" ||
      StringSplit(tail,'\t',t)!=2 || t[0]!="END" ||
      (uint)StringToInteger(t[1])!=LTCHash(line+"\n")) return false;
   if(!LTCFresh((double)GetTickCount64(),(double)StringToInteger(x[1]),2000) ||
      (x[2]!="0" && x[2]!="1")) return false;
   c.clock_ms=(ulong)StringToInteger(x[1]);
   c.running=(x[2]=="1"); c.source_login=StringToInteger(x[3]); c.source_server=x[4];
   c.receiver_login=StringToInteger(x[5]); c.receiver_server=x[6];
   if(x[7]!="0" && x[7]!="1" && x[7]!="2") return false;
   if((x[8]!="0" && x[8]!="1") || (x[11]!="0" && x[11]!="1")) return false;
   c.mode=(int)StringToInteger(x[7]); c.operation=(int)StringToInteger(x[8]);
   c.factor=StringToDouble(x[9]); c.fixed_lots=StringToDouble(x[10]);
   c.rounding=(int)StringToInteger(x[11]); c.source_path=x[12]; c.receiver_path=x[13];
   return LTCFinitePositive(c.factor) && LTCFinitePositive(c.fixed_lots) &&
          c.factor<=1000000 && c.fixed_lots<=1000000 &&
          (!c.running || (c.source_login>0 && c.receiver_login>0 &&
           LTCFieldValid(c.source_server) && LTCFieldValid(c.receiver_server) &&
           LTCFieldValid(c.source_path) && LTCFieldValid(c.receiver_path)));
  }
bool LTCWriteStatus(string channel,string role,long login,string server,bool enabled,
                    int pending,string code,string message,bool allowed)
  {
   StringReplace(message,"\t"," "); StringReplace(message,"\r"," "); StringReplace(message,"\n"," ");
   string line="LTCSTATUS2\t"+(string)GetTickCount64()+"\t"+(string)login+"\t"+server+"\t"+
               TerminalInfoString(TERMINAL_DATA_PATH)+"\t"+(enabled?"1":"0")+"\t"+
               (string)pending+"\t"+code+"\t"+message+"\t"+(allowed?"1":"0");
   string packet=line+"\r\nEND\t"+(string)LTCHash(line+"\n")+"\r\n";
   int f=FileOpen("LocalCopier\\"+channel+"."+role+".status",FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON,0,CP_UTF8);
   if(f==INVALID_HANDLE) return false;
   bool ok=FileWriteString(f,packet)>0; FileFlush(f); FileClose(f); return ok;
  }
#endif
