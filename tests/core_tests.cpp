#include <cmath>
#include <cstdlib>
#include <iostream>
#include <random>
#define MathFloor std::floor
#include "../Experts/LocalCopier/CopyCore.mqh"
#undef MathFloor

int checks=0;
void require(bool condition,const char* label)
{
    ++checks;
    if(!condition) { std::cerr << "FAIL: " << label << '\n'; std::exit(1); }
}
bool near(double a,double b) { return std::abs(a-b)<1e-8; }

int main()
{
    require(near(LTCLots(.32,LTC_EXACT,0,100,.01,0,.32,.01),.32),"exact ignores factor");
    require(near(LTCLots(.32,LTC_CONVERT,LTC_MULTIPLY,1.5,.01,0,.32,.01),.48),"multiply 0.32 x 1.5");
    require(near(LTCLots(.32,LTC_CONVERT,LTC_DIVIDE,3,.01,LTC_TRUNCATE,.32,.01),.10),"divide truncate");
    require(near(LTCLots(.32,LTC_CONVERT,LTC_DIVIDE,3,.01,LTC_HALF_UP,.32,.01),.11),"divide half up");
    require(near(LTCLots(.03,LTC_CONVERT,0,.5,.01,LTC_HALF_UP,.03,.01),.02),"third digit 5 rounds up");
    require(near(LTCLots(.03,LTC_CONVERT,0,.5,.01,LTC_TRUNCATE,.03,.01),.01),"third digit 5 truncated");
    require(near(LTCLots(.01,LTC_CONVERT,1,3,.01,LTC_HALF_UP,.01,.01),0),"below minimum does not force exposure");
    require(near(LTCLots(.32,LTC_FIXED,0,123,.08,0,.32,.01),.08),"fixed ignores original entry volume");
    require(near(LTCLots(.16,LTC_FIXED,0,123,.08,0,.32,.01),.04),"fixed proportional half close");
    require(near(LTCLots(.08,LTC_FIXED,0,123,.08,0,.32,.01),.02),"fixed proportional quarter remaining");
    require(near(LTCLots(.08,LTC_FIXED,0,1,.08,0,.32,.01),.02),"partial pending fill allocated once");
    require(near(LTCLots(.32,LTC_CONVERT,1,3,.01,LTC_HALF_UP,.32,.1),.1),"coarse broker step remains downward");
    require(LTCLots(.32,LTC_CONVERT,1,0,.01,0,.32,.01)<0,"zero divisor rejected");
    require(LTCLots(.32,LTC_FIXED,0,1,.01,0,0,.01)<0,"missing fixed baseline rejected");
    require(LTCLots(.32,3,0,1,.01,0,.32,.01)<0,"invalid lot mode rejected");
    require(LTCLots(.32,1,0,1e20,.01,0,.32,.01)<0,"converted overflow rejected");
    require(LTCDecide(false,true,true,0,1,false,.0025)==LTC_CLOSE,"master flat -> close follower");
    require(LTCDecide(true,true,false,1,1,false,.0025)==LTC_CLOSE,"wrong direction -> close before reopen");
    require(LTCDecide(true,false,true,1,1,false,.0025)==LTC_CLOSE,"wrong mapped symbol -> close");
    require(LTCDecide(true,true,true,.4,1,false,.0025)==LTC_REDUCE,"master partial close -> reduce");
    require(LTCDecide(true,true,true,1,0,true,.0025)==LTC_CANCEL_BEFORE_OPEN,"master pending filled -> cancel unfilled follower before market entry");
    require(LTCDecide(true,true,true,1,0,false,.0025)==LTC_OPEN,"missing follower -> market entry");
    require(LTCDecide(true,true,true,1,.6,false,.0025)==LTC_OPEN,"partial follower fill -> top up only shortfall");
    require(LTCDecide(true,true,true,0,.01,false,.0025)==LTC_REDUCE,"rounded target zero -> flatten");
    require(LTCDecide(false,true,true,0,0,true,.0025)==LTC_NONE,"never open a vanished master position");
    require(LTCDecide(true,true,true,1,1,false,.0025)==LTC_NONE,"idempotent after successful fill");

    require(LTCFresh(3000,1000,2000),"heartbeat boundary is accepted");
    require(!LTCFresh(3001,1000,2000),"stale heartbeat rejected");
    require(!LTCFresh(1000,1001,2000),"future heartbeat / reboot rejected");
    require(!LTCFresh(1000,0,2000),"missing heartbeat rejected");
    require(near(LTCTarget(.03,.5,.01),.01),"half of .03 lots rounds down, not up");
    require(near(LTCTarget(.3,1,.1),.3),"floating-point boundary retains exact step");
    require(near(LTCTarget(.001,1,.01),0),"sub-step exposure never rounded up");
    require(LTCTarget(1,1,0)==0,"invalid step cannot open");
    require(LTCTarget(1e20,1,.01)<0,"overflow guard");

    // Replay a real reconciliation sequence through the exact shared MQL core.
    double follower=0,target=1;
    bool pending=true;
    require(LTCDecide(true,true,true,target,follower,pending,.0025)==LTC_CANCEL_BEFORE_OPEN,"replay cancel first");
    pending=false;
    require(LTCDecide(true,true,true,target,follower,pending,.0025)==LTC_OPEN,"replay market after cancel observed");
    follower=.4; // IOC partial fill
    require(LTCDecide(true,true,true,target,follower,pending,.0025)==LTC_OPEN,"replay partial top-up");
    follower=1;
    require(LTCDecide(true,true,true,target,follower,pending,.0025)==LTC_NONE,"replay complete");
    target=.3;
    require(LTCDecide(true,true,true,target,follower,pending,.0025)==LTC_REDUCE,"replay master reduces");
    follower=target;
    require(LTCDecide(false,true,true,0,follower,pending,.0025)==LTC_CLOSE,"replay master stop loss closes remainder");

    std::mt19937_64 rng(20261017);
    std::uniform_real_distribution<double> distribution(.00001,100.0);
    for(int i=0;i<20000;i++) {
        double source=distribution(rng), multiplier=distribution(rng)/10;
        double truncated=LTCLots(source,LTC_CONVERT,0,multiplier,.01,LTC_TRUNCATE,source,.01);
        double rounded=LTCLots(source,LTC_CONVERT,0,multiplier,.01,LTC_HALF_UP,source,.01);
        require(truncated<=source*multiplier+1e-8,"converted truncate never increases raw target");
        require(rounded>=truncated-1e-8 && rounded<=truncated+.01000001,"half up differs by at most one centilot");
        double step=(i%3==0?.01:(i%3==1?.1:1));
        double desired=LTCTarget(source,multiplier,step);
        require(desired<=source*multiplier+1e-8,"random: rounding never increases desired exposure");
        require(std::abs(desired/step-std::round(desired/step))<1e-7,"random: target is a broker step");
        double actual=distribution(rng);
        auto action=LTCDecide(false,true,true,desired,actual,true,1e-9);
        require(action==LTC_CLOSE,"random: absent source always closes existing exposure");
        action=LTCDecide(true,true,true,desired,actual,false,1e-9);
        if(action==LTC_OPEN) require(desired>actual,"random: open never adds excess volume");
        if(action==LTC_REDUCE) require(actual>desired,"random: reduce never increases exposure");
        if(action==LTC_OPEN)
            require(LTCDecide(true,true,true,desired,actual,true,1e-9)==LTC_CANCEL_BEFORE_OPEN,
                    "random: every top-up with a live pending must cancel first");
    }
    std::cout << "PASS: " << checks << " assertions; shared MQL/C++ decision core and replay scenarios.\n";
}
