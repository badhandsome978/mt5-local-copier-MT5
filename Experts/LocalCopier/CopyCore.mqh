#ifndef LOCAL_COPIER_CORE
#define LOCAL_COPIER_CORE
// Deliberately shared verbatim by the MQL5 EA and the native regression tests.
enum LTC_ACTION
  {
   LTC_NONE=0,
   LTC_CLOSE=1,
   LTC_REDUCE=2,
   LTC_CANCEL_BEFORE_OPEN=3,
   LTC_OPEN=4
  };

enum LTC_LOTS_MODE { LTC_EXACT=0, LTC_CONVERT=1, LTC_FIXED=2 };
enum LTC_OPERATION { LTC_MULTIPLY=0, LTC_DIVIDE=1 };
enum LTC_ROUNDING { LTC_TRUNCATE=0, LTC_HALF_UP=1 };

// Entry target only. Execution chunks and close amounts always round DOWN.
double LTCLots(double source,int mode,int operation,double factor,double fixed_lots,
               int rounding,double baseline,double step)
  {
   if(source<=0 || step<=0 || factor<=0 || fixed_lots<=0 ||
      mode<0 || mode>2 || operation<0 || operation>1 || rounding<0 || rounding>1) return -1;
   double raw=source;
   if(mode==LTC_CONVERT) raw=(operation==LTC_MULTIPLY?source*factor:source/factor);
   if(mode==LTC_FIXED)
     {
      if(baseline<=0) return -1;
      raw=fixed_lots*(source/baseline);
     }
   // Bound before converting units; callers also reject nonfinite inputs.
   if(!(raw>=0) || raw>100000000.0) return -1;
   if(mode!=LTC_EXACT)
      raw=MathFloor(raw*100.0+(rounding==LTC_HALF_UP?0.5:0.0)+0.00000001)/100.0;
   double units=raw/step;
   if(units>1000000000000.0) return -1;
   return MathFloor(units+0.00000001)*step;
  }

bool LTCFresh(double now_ms,double published_ms,double maximum_age_ms)
  {
   return published_ms>0 && now_ms>=published_ms &&
          now_ms-published_ms<=maximum_age_ms;
  }

double LTCTarget(double source_volume,double multiplier,double step)
  {
   if(source_volume<=0 || multiplier<=0 || step<=0) return 0;
   double units=source_volume*multiplier/step;
   if(units>1000000000000.0) return -1;
   // Round down: never increase exposure to satisfy a broker's lot step.
   return MathFloor(units+0.00000001)*step;
  }

LTC_ACTION LTCDecide(bool source_exists,bool symbol_matches,bool side_matches,
                     double target,double actual,bool pending,double epsilon)
  {
   if(actual>epsilon && (!source_exists || !symbol_matches || !side_matches))
      return LTC_CLOSE;
   if(!source_exists) return LTC_NONE;
   if(actual>target+epsilon) return LTC_REDUCE;
   if(actual+epsilon<target)
      return pending ? LTC_CANCEL_BEFORE_OPEN : LTC_OPEN;
   return LTC_NONE;
  }
#endif
