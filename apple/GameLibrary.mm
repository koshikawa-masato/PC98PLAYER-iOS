// SPDX-License-Identifier: MIT
#import "GameLibrary.h"
#import <TargetConditionals.h>
#import <CommonCrypto/CommonDigest.h>
static NSError* cacheError(NSInteger code,NSString* message) {
    return [NSError errorWithDomain:@"PC98GameCache" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL copyIndexedFolder(NSURL* source,NSURL* destination,NSDictionary* index,NSError** error) {
    if(![index isKindOfClass:NSDictionary.class] || ![index[@"version"] isEqual:@1] || ![index[@"files"] isKindOfClass:NSArray.class] || ![index[@"files"] count]) {
        if(error) *error=cacheError(4,@"NASのゲームファイル一覧が正しくありません。");return NO;
    }
    NSFileManager* manager=NSFileManager.defaultManager;NSMutableSet* copied=[NSMutableSet new];
    for(NSDictionary* entry in index[@"files"]) {
        if(![entry isKindOfClass:NSDictionary.class]) { if(error) *error=cacheError(4,@"ゲームファイル一覧に不正な項目があります。");return NO; }
        NSString* path=entry[@"path"];NSNumber* size=entry[@"size"];NSString* expected=entry[@"sha256"];
        if(![path isKindOfClass:NSString.class] || !path.length || path.isAbsolutePath || [path containsString:@"\\"] || [path containsString:@"\0"] || ![size isKindOfClass:NSNumber.class] || size.longLongValue<0 || ![expected isKindOfClass:NSString.class] || expected.length!=64 || [copied containsObject:path]) {
            if(error) *error=cacheError(4,@"ゲームファイル一覧に不正なパスがあります。");return NO;
        }
        for(NSString* part in [path componentsSeparatedByString:@"/"]) if(!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."]) { if(error) *error=cacheError(4,@"ゲームフォルダー外のファイルは取得できません。");return NO; }
        [copied addObject:path];
        NSURL* input=[source URLByAppendingPathComponent:path];NSURL* output=[destination URLByAppendingPathComponent:path];
        if(![input.URLByResolvingSymlinksInPath.path isEqualToString:input.URLByStandardizingPath.path]) { if(error) *error=cacheError(2,@"ゲームファイル一覧のシンボリックリンクは取り込めません。");return NO; }
        if(![manager createDirectoryAtURL:output.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
        __block NSError* failure=nil;NSError* coordinationError=nil;
        NSFileCoordinator* coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:input options:NSFileCoordinatorReadingWithoutChanges error:&coordinationError byAccessor:^(NSURL* readable) {
            NSData* bytes=[NSData dataWithContentsOfURL:readable options:NSDataReadingUncached error:&failure];if(!bytes) return;
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
            NSMutableString* actual=[NSMutableString new];for(unsigned char c:digest) [actual appendFormat:@"%02x",c];
            if(bytes.length!=size.unsignedLongLongValue || ![actual isEqualToString:expected.lowercaseString]) { failure=cacheError(5,[@"NASから取得したファイルが一覧と一致しません：" stringByAppendingString:path]);return; }
            [bytes writeToURL:output options:NSDataWritingAtomic error:&failure];
        }];
        if(coordinationError || failure) { if(error) *error=coordinationError ?: failure;return NO; }
    }
    return YES;
}

@implementation GameLibrary
+ (BOOL)isUsableCacheAtURL:(NSURL*)url {
    NSFileManager* manager=NSFileManager.defaultManager;
    NSDirectoryEnumerator* items=[manager enumeratorAtURL:url includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    BOOL ini=NO, disk=NO;
    for(NSURL* item in items) {
        NSNumber* regular=nil; NSNumber* size=nil;
        [item getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [item getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if(!regular.boolValue || !size.unsignedLongLongValue) continue;
        NSString* ext=item.pathExtension.lowercaseString;
        if([@[@"bat",@"com",@"exe"] containsObject:ext]) return YES;
        if([item.lastPathComponent caseInsensitiveCompare:@"PC98PLAYER.INI"]==NSOrderedSame) ini=YES;
        if([@[@"d88",@"fdi",@"hdm",@"d98",@"xdf"] containsObject:ext]) disk=YES;
    }
    return ini && disk;
}
+ (BOOL)copyFolderFromURL:(NSURL*)source toURL:(NSURL*)destination error:(NSError**)error {
    NSFileManager* manager=NSFileManager.defaultManager;
    if(![manager createDirectoryAtURL:destination withIntermediateDirectories:NO attributes:nil error:error]) return NO;
    // A per-game index avoids broken directory enumeration in some iOS SMB providers.
    NSURL* indexURL=[source URLByAppendingPathComponent:@"PC98PLAYER.FILES.json"];
    __block NSData* indexData=nil;
    NSFileCoordinator* indexCoordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [indexCoordinator coordinateReadingItemAtURL:indexURL options:NSFileCoordinatorReadingWithoutChanges error:nil byAccessor:^(NSURL* readable) {
        indexData=[NSData dataWithContentsOfURL:readable options:NSDataReadingUncached error:nil];
    }];
    if(indexData) {
        NSDictionary* index=[NSJSONSerialization JSONObjectWithData:indexData options:0 error:error];
        if(!index) return NO;
        return copyIndexedFolder(source,destination,index,error);
    }
    __block NSArray<NSURL*>* children=nil;
    __block NSError* failure=nil;
    NSFileCoordinator* coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:source options:NSFileCoordinatorReadingWithoutChanges error:&failure byAccessor:^(NSURL* readable) {
        children=[manager contentsOfDirectoryAtURL:readable includingPropertiesForKeys:@[NSURLIsDirectoryKey,NSURLIsSymbolicLinkKey,NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:&failure];
        if(children && !children.count) children=[manager contentsOfDirectoryAtURL:readable includingPropertiesForKeys:@[NSURLIsDirectoryKey,NSURLIsSymbolicLinkKey,NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:&failure];
    }];
    if(failure || !children) { if(error) *error=failure ?: cacheError(6,@"ゲームフォルダーの一覧を取得できませんでした。"); return NO; }
    for(NSURL* child in children) {
        NSNumber* directory=nil; NSNumber* link=nil;
        if(![child getResourceValue:&directory forKey:NSURLIsDirectoryKey error:&failure] || ![child getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:&failure]) { if(error) *error=failure; return NO; }
        if(link.boolValue) { if(error) *error=[NSError errorWithDomain:@"PC98GameCache" code:2 userInfo:@{NSLocalizedDescriptionKey:@"ゲームフォルダー内のシンボリックリンクは取り込めません。"}]; return NO; }
        NSURL* target=[destination URLByAppendingPathComponent:child.lastPathComponent isDirectory:directory.boolValue];
        if(directory.boolValue) {
            if(![self copyFolderFromURL:child toURL:target error:error]) return NO;
        } else {
            // Read every file through its provider instead of relying on bulk directory cloning.
            // SMB / Files providers may report a successful copy of only the directory shell.
            failure=nil;
            [coordinator coordinateReadingItemAtURL:child options:NSFileCoordinatorReadingWithoutChanges error:&failure byAccessor:^(NSURL* readable) {
                NSNumber* expected=nil;
                if(![readable getResourceValue:&expected forKey:NSURLFileSizeKey error:&failure]) return;
                NSData* bytes=[NSData dataWithContentsOfURL:readable options:NSDataReadingUncached error:&failure];
                if(!bytes) return;
                if(bytes.length!=expected.unsignedLongLongValue) { failure=[NSError errorWithDomain:@"PC98GameCache" code:3 userInfo:@{NSLocalizedDescriptionKey:@"NASからのファイル取得が完了していません。接続を確認して再度開いてください。"}]; return; }
                [bytes writeToURL:target options:NSDataWritingAtomic error:&failure];
            }];
            if(failure) { if(error) *error=failure; return NO; }
        }
    }
    return YES;
}

+ (NSArray<NSDictionary*>*)entries {
    NSArray* entries = [NSUserDefaults.standardUserDefaults arrayForKey:@"PC98GameFolders"];
    return entries ?: @[];
}
+ (BOOL)rememberURL:(NSURL*)url name:(NSString*)name error:(NSError**)error {
    NSURLBookmarkCreationOptions options = 0;
#if TARGET_OS_OSX
    options = NSURLBookmarkCreationWithSecurityScope;
#endif
    NSData* bookmark = [url bookmarkDataWithOptions:options includingResourceValuesForKeys:nil relativeToURL:nil error:error];
    if (!bookmark) return NO;
    NSMutableArray* entries = [[self entries] mutableCopy];
    NSIndexSet* duplicates = [entries indexesOfObjectsPassingTest:^BOOL(NSDictionary* e, NSUInteger i, BOOL* stop) {
        return [e[@"path"] isEqual:url.path];
    }];
    [entries removeObjectsAtIndexes:duplicates];
    [entries insertObject:@{@"name":name, @"path":url.path, @"bookmark":bookmark} atIndex:0];
    while(entries.count > 20) [entries removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:entries forKey:@"PC98GameFolders"];
    return YES;
}
+ (NSURL*)resolveEntry:(NSDictionary*)entry error:(NSError**)error {
    BOOL stale = NO;
    NSURLBookmarkResolutionOptions options = NSURLBookmarkResolutionWithoutUI;
#if TARGET_OS_OSX
    options |= NSURLBookmarkResolutionWithSecurityScope;
#endif
    NSURL* url = [NSURL URLByResolvingBookmarkData:entry[@"bookmark"] options:options relativeToURL:nil bookmarkDataIsStale:&stale error:error];
    // Refresh only after the caller has acquired access; never silently fall back to a stale path.
    return url;
}
@end
