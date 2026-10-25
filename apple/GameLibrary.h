// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Folder bookmarks are kept outside game folders. No credentials are stored here.
@interface GameLibrary : NSObject
+ (BOOL)isUsableCacheAtURL:(NSURL*)url;
+ (BOOL)copyFolderFromURL:(NSURL*)source toURL:(NSURL*)destination error:(NSError**)error;
+ (NSArray<NSDictionary*>*)entries;
+ (BOOL)rememberURL:(NSURL*)url name:(NSString*)name error:(NSError**)error;
+ (nullable NSURL*)resolveEntry:(NSDictionary*)entry error:(NSError**)error;
@end
NS_ASSUME_NONNULL_END
