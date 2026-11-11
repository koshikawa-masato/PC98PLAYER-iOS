// SPDX-License-Identifier: MIT
#import "../ios/FeedbackDiagnostics.h"
#include "../ios/FeedbackErrorPolicy.h"
#include "player.h"
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <unistd.h>

static void check(bool ok,const char* why) { if(!ok)throw std::runtime_error(why); }
int main() { @autoreleasepool {
    char path[]="/tmp/retrodos-feedback-test-XXXXXX";
    if(!mkdtemp(path))return 1;
    try {
        using feedback_error::GuestFailure;
        // Real DOS launch failures and normal exit go through the unchanged core.
        const unsigned char exitProgram[]={0xb8,0x00,0x4c,0xcd,0x21};
        std::ofstream file(std::filesystem::path(path)/"EXIT.COM",std::ios::binary);
        file.write((const char*)exitProgram,sizeof(exitProgram));file.close();
        for(const auto* start:{"MISSING.EXE","EXIT.COM"}) {
            auto player=std::make_unique<Player>();PlayerSettings settings;
            settings.cfg.root=path;settings.cfg.start=start;settings.cfg.midi=0;
            std::string error;check(player->init(settings,&error),"fixture init");
            for(int i=0;i<60 && !player->m->quit;++i) player->run_frame();
            check(player->m->quit==1,"fixture terminates");
            auto expected=std::string(start)=="MISSING.EXE"?GuestFailure::Command:GuestFailure::None;
            check(feedback_error::guestFailure(player->m)==expected,"normal exit versus missing command");
            player->m->quit=0;
            check(feedback_error::guestFailure(player->m)==GuestFailure::None,"no prompt while guest is running");
            player->m->quit=1;player->m->gdcm.display=0;
            check(feedback_error::guestFailure(player->m)==GuestFailure::None,"hidden stale text is ignored");
            player->m->quit=2;
            check(feedback_error::guestFailure(player->m)==GuestFailure::Execution,"CPU execution failure");
            player->m->quit=3;
            check(feedback_error::guestFailure(player->m)==GuestFailure::Compatibility,"unsupported ROM call");
            player->shutdown();
        }
        NSMutableDictionary* sample=[@{@"cpu_mhz":@66,@"event":@"guest_command"} mutableCopy];
        NSString* json=PC98FeedbackDiagnosticJSON(sample);sample[@"cpu_mhz"]=@133;
        NSDictionary* frozen=[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        check([frozen[@"cpu_mhz"] intValue]==66,"snapshot is immutable at capture time");
        check([PC98FeedbackBody(@"report",json,NO) isEqualToString:@"report"],"opt-out removes diagnostic JSON entirely");
        check([PC98FeedbackBody(@"report",json,YES) containsString:json],"opt-in preserves JSON");
        check(!PC98FeedbackDiagnosticJSON(@{@"bad":[NSDate date]}),"unsupported values rejected");
        check(!PC98FeedbackDiagnosticJSON(@{@"oversize":[@"x" stringByPaddingToLength:7000 withString:@"x" startingAtIndex:0]}),"bounded diagnostic size");
        std::filesystem::remove_all(path);puts("Feedback error policy and frozen diagnostics passed");return 0;
    } catch(const std::exception& error) {
        fprintf(stderr,"%s\n",error.what());std::filesystem::remove_all(path);return 1;
    }
} }
