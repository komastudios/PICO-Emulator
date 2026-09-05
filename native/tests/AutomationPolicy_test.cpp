// Copyright 2026 Koma Studios. Licensed under the Apache License, Version 2.0.
#include "AutomationPolicy.h"
#include <cstdlib>
#include <iostream>
using namespace pico::automation;
int main() {
    using namespace std::chrono;
    auto now=Monotonic::time_point(seconds(100));
    auto check=[&](const std::string& epoch,const std::string& token,uint64_t seq,int queueMs,int leaseMs=5000){return checkCommand("boot:2",epoch,"secret",token,7,seq,now+milliseconds(queueMs),now+milliseconds(100),now+milliseconds(leaseMs));};
    auto require=[](bool v){if(!v){std::cerr<<"policy regression\n";std::exit(1);}};
    require(check("boot:2","secret",8,0)==Rejection::None);
    require(check("boot:1","secret",8,0)==Rejection::Epoch);
    require(check("boot:2","other",8,0)==Rejection::Token);
    require(check("boot:2","secret",7,0)==Rejection::Sequence);
    require(check("boot:2","secret",0,0)==Rejection::Sequence);
    require(check("boot:2","secret",8,100)==Rejection::Deadline);
    require(check("boot:2","secret",8,10,10)==Rejection::Token);
    require(checkCommand("boot:2","boot:2","","",0,1,now,now+seconds(1),now+seconds(5))==Rejection::Token);
    require(pressDeadline(now,5000,now+milliseconds(30))==now+milliseconds(30));
    require(pressDeadline(now,20,now+seconds(5))==now+milliseconds(20));
    // Arbitrary queue delay cannot revive an expired mutation or old epoch.
    for(int delay=100;delay<10000;++delay)require(check("boot:2","secret",8,delay)==Rejection::Deadline);
    std::cout<<"automation policy: 9910 checks passed\n";
}
