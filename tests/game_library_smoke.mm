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
        for(NSString* folder in @[@"", @"PACK/GAME"]) {
            NSURL* directory=folder.length ? [cache URLByAppendingPathComponent:folder] : cache;
            NSURL* program=[directory URLByAppendingPathComponent:@"DEPTH.EXE"];
            check([[GameLibrary launchFolderForProgram:program relativeToRoot:cache].path isEqual:cache.path],
                  "DOS-safe folder keeps the configured root");
        }
        for(NSString* folder in @[@"LongArchive/GAME", @"Games Collection/Super Depth", @"作品集/ゲーム", @"PACK.2026/GAME"]) {
            NSURL* leaf=[cache URLByAppendingPathComponent:folder];
            NSURL* program=[leaf URLByAppendingPathComponent:@"DEPTH.EXE"];
            check([[GameLibrary launchFolderForProgram:program relativeToRoot:cache].path isEqual:leaf.path],
                  "host-only folder names are outside the DOS path");
        }
        NSURL* exe=[cache URLByAppendingPathComponent:@"PC98PLAYER.EXE"];
        NSMutableData* header=[NSMutableData dataWithLength:128];
        auto* bytes=static_cast<uint8_t*>(header.mutableBytes);
        bytes[0]='M'; bytes[1]='Z'; bytes[60]=96;
        check([header writeToURL:exe options:0 error:&error],"write DOS executable header");
        check(![GameLibrary isWindowsProgramAtURL:exe],"DOS executable remains a launch candidate");
        bytes[96]='P'; bytes[97]='E';
        check([header writeToURL:exe options:0 error:&error],"write Windows executable header");
        check([GameLibrary isWindowsProgramAtURL:exe],"Windows PE executable is excluded");
        bytes[60]=255;
        check([header writeToURL:exe options:0 error:&error],"write truncated PE offset");
        check(![GameLibrary isWindowsProgramAtURL:exe],"truncated PE offset is handled safely");
        NSURL* alias=[temp URLByAppendingPathComponent:@"alias"];
        check([fm createSymbolicLinkAtURL:alias withDestinationURL:cache error:&error],"create root alias");
        NSURL* cachedProgram=[cache URLByAppendingPathComponent:@"nested/DEMO.COM"];
        check([[GameLibrary relativePathForProgram:cachedProgram inRoot:alias] isEqual:@"nested/DEMO.COM"],
              "relative path omits the real root when the selected root is an alias");
        check([GameLibrary relativePathForProgram:[nested URLByAppendingPathComponent:@"DEMO.COM"] inRoot:alias]==nil,
              "program outside the resolved root is rejected");
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
