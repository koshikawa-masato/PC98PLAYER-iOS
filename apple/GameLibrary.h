// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Folder bookmarks are kept outside game folders. No credentials are stored here.
@interface GameLibrary : NSObject
+ (nullable NSString*)relativePathForProgram:(NSURL*)program inRoot:(NSURL*)root;
+ (BOOL)isWindowsProgramAtURL:(NSURL*)url;
+ (NSURL*)launchFolderForProgram:(NSURL*)program relativeToRoot:(NSURL*)root;
+ (BOOL)isUsableCacheAtURL:(NSURL*)url;
+ (BOOL)refreshCacheFromURL:(NSURL*)source toURL:(NSURL*)destination error:(NSError**)error;
+ (BOOL)copyFolderFromURL:(NSURL*)source toURL:(NSURL*)destination error:(NSError**)error;
+ (nullable NSURL*)gameRootAtURL:(NSURL*)cache relativePath:(NSString*)path error:(NSError**)error;
+ (nullable NSString*)verifiedDisplayNameAtURL:(NSURL*)root;
+ (NSArray<NSDictionary*>*)entries;
+ (void)forgetURL:(NSURL*)url;
+ (BOOL)rememberURL:(NSURL*)url name:(NSString*)name error:(NSError**)error;
+ (nullable NSURL*)resolveEntry:(NSDictionary*)entry error:(NSError**)error;
@end
NS_ASSUME_NONNULL_END
