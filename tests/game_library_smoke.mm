// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import "GameLibrary.h"
#include <stdexcept>
#include <cstdio>
static void check(BOOL value,const char* message) { if(!value) throw std::runtime_error(message); }
int main() { @autoreleasepool {
    NSFileManager* fm=NSFileManager.defaultManager;
    NSURL* temp=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    try {
        NSError* error=nil;
        NSURL* source=[temp URLByAppendingPathComponent:@"source"];
        NSURL* nested=[source URLByAppendingPathComponent:@"nested"];
        check([fm createDirectoryAtURL:nested withIntermediateDirectories:YES attributes:nil error:&error],"create source");
        NSData* content=[@"demo bytes" dataUsingEncoding:NSUTF8StringEncoding];
        check([content writeToURL:[nested URLByAppendingPathComponent:@"DEMO.COM"] options:0 error:&error],"write fixture");
        NSURL* cache=[temp URLByAppendingPathComponent:@"cache"];
        check([GameLibrary copyFolderFromURL:source toURL:cache error:&error],"coordinated nested copy");
        check([[NSData dataWithContentsOfURL:[cache URLByAppendingPathComponent:@"nested/DEMO.COM"]] isEqual:content],"copied bytes");
        for(NSString* path in @[@"",@".",@"nested/..",@"nested",@"nested\\."]) {
            error=nil;
            check([GameLibrary gameRootAtURL:cache relativePath:path error:&error]!=nil,"valid relative root");
        }
        for(NSString* path in @[@"../source",@"/tmp",@"C:\\game",@"missing",@"nested/DEMO.COM"]) {
            error=nil;
            check([GameLibrary gameRootAtURL:cache relativePath:path error:&error]==nil && error!=nil,"reject invalid root");
        }
        check([fm createSymbolicLinkAtURL:[cache URLByAppendingPathComponent:@"outside"] withDestinationURL:source error:&error],"create link");
        error=nil;
        check([GameLibrary gameRootAtURL:cache relativePath:@"outside" error:&error]==nil,"reject escaping symlink");
        NSURL* failed=[temp URLByAppendingPathComponent:@"failed"];
        error=nil;
        check(![GameLibrary copyFolderFromURL:cache toURL:failed error:&error] && error!=nil,"link copy fails explicitly");
        check([[NSData dataWithContentsOfURL:[nested URLByAppendingPathComponent:@"DEMO.COM"]] isEqual:content],"source unchanged");
        [fm removeItemAtURL:temp error:nil];
        puts("PASS: coordinated copy, relative roots, missing roots, symlink containment, source preservation");
        return 0;
    } catch(const std::exception& e) {
        fprintf(stderr,"FAIL: %s\n",e.what());
        [fm removeItemAtURL:temp error:nil]; return 1;
    }
} }
