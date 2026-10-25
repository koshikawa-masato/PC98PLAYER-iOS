// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "GameLibrary.h"
static NSString* digest(NSData* bytes) {
    unsigned char sha[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,sha);
    NSMutableString* value=[NSMutableString new];for(unsigned char c:sha) [value appendFormat:@"%02x",c];return value;
}
int main() { @autoreleasepool {
    NSFileManager* fm=NSFileManager.defaultManager;
    NSURL* base=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL* source=[base URLByAppendingPathComponent:@"source" isDirectory:YES];
    [fm createDirectoryAtURL:[source URLByAppendingPathComponent:@"SUB"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableData* binary=[NSMutableData dataWithLength:65537];memset(binary.mutableBytes,0xA5,binary.length);
    [binary writeToURL:[source URLByAppendingPathComponent:@"SUB/PLAY.COM"] atomically:YES];
    [[NSData data] writeToURL:[source URLByAppendingPathComponent:@"ZERO.SYS"] atomically:YES];
    __block int failures=0, count=0;
    void (^check)(BOOL,NSString*)=^(BOOL passed,NSString* name) { ++count;if(!passed) { ++failures;fprintf(stderr,"FAIL %s\n",name.UTF8String); } };
    NSError* error=nil;NSURL* copy=[base URLByAppendingPathComponent:@"recursive"];
    check([GameLibrary copyFolderFromURL:source toURL:copy error:&error],@"recursive provider copy");
    check([GameLibrary isUsableCacheAtURL:copy],@"usable recursive cache");
    check([[NSData dataWithContentsOfURL:[copy URLByAppendingPathComponent:@"SUB/PLAY.COM"]] isEqualToData:binary],@"binary copied exactly");
    check([fm fileExistsAtPath:[copy URLByAppendingPathComponent:@"ZERO.SYS"].path],@"zero-byte file preserved");
    NSURL* blank=[base URLByAppendingPathComponent:@"blank"];
    [fm createDirectoryAtURL:blank withIntermediateDirectories:NO attributes:nil error:nil];
    check(![GameLibrary isUsableCacheAtURL:blank],@"empty legacy cache rejected");
    NSURL* index=[source URLByAppendingPathComponent:@"PC98PLAYER.FILES.json"];
    NSDictionary* entry=@{@"path":@"SUB/PLAY.COM",@"size":@(binary.length),@"sha256":digest(binary)};
    void (^writeIndex)(id)=^(id contents) { [[NSJSONSerialization dataWithJSONObject:contents options:0 error:nil] writeToURL:index atomically:YES]; };
    writeIndex(@{@"version":@1,@"files":@[entry]});
    copy=[base URLByAppendingPathComponent:@"indexed"];error=nil;
    check([GameLibrary copyFolderFromURL:source toURL:copy error:&error],@"indexed provider copy");
    check([[NSData dataWithContentsOfURL:[copy URLByAppendingPathComponent:@"SUB/PLAY.COM"]] isEqualToData:binary],@"indexed binary copied exactly");
    NSMutableDictionary* corrupt=[entry mutableCopy];corrupt[@"sha256"]=[@"" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0];
    NSArray* invalid=@[
        @{@"version":@1,@"files":@[corrupt]},
        @{@"version":@2,@"files":@[entry]},
        @{@"version":@1,@"files":@[]},
        @{@"version":@1,@"files":@[entry,entry]},
        @{@"version":@1,@"files":@[@{@"path":@"../escape.COM",@"size":@(binary.length),@"sha256":digest(binary)}]},
        @{@"version":@1,@"files":@[@{@"path":@"/escape.COM",@"size":@(binary.length),@"sha256":digest(binary)}]},
        @{@"version":@1,@"files":@[@{@"path":@"MISSING.COM",@"size":@(binary.length),@"sha256":digest(binary)}]},
        @[entry]
    ];
    for(NSUInteger i=0;i<invalid.count;++i) {
        writeIndex(invalid[i]);error=nil;
        check(![GameLibrary copyFolderFromURL:source toURL:[base URLByAppendingPathComponent:[NSString stringWithFormat:@"bad%lu",(unsigned long)i]] error:&error] && error!=nil,[NSString stringWithFormat:@"invalid index %lu rejected",(unsigned long)i]);
    }
    check(![fm fileExistsAtPath:[base URLByAppendingPathComponent:@"escape.COM"].path],@"no traversal output");
    [fm createSymbolicLinkAtURL:[source URLByAppendingPathComponent:@"LINK.COM"] withDestinationURL:[source URLByAppendingPathComponent:@"SUB/PLAY.COM"] error:nil];
    writeIndex(@{@"version":@1,@"files":@[@{@"path":@"LINK.COM",@"size":@(binary.length),@"sha256":digest(binary)}]});error=nil;
    check(![GameLibrary copyFolderFromURL:source toURL:[base URLByAppendingPathComponent:@"linked-index"] error:&error],@"indexed symlink rejected");
    [fm removeItemAtURL:index error:nil];error=nil;
    check(![GameLibrary copyFolderFromURL:source toURL:[base URLByAppendingPathComponent:@"linked-tree"] error:&error],@"ordinary symlink rejected");
    [fm removeItemAtURL:base error:nil];
    printf("game_cache_smoke: %d checks, %d failures\n",count,failures);return failures?1:0;
} }
