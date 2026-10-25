// SPDX-License-Identifier: MIT
#import <Foundation/Foundation.h>
#include <vector>
#include <cstdint>
// Debug-only, app-audio capture. Video and microphone samples are never stored.
@interface AudioCaptureProbe : NSObject
- (instancetype)initWithDirectory:(NSURL*)directory;
- (void)start:(void (^)(NSError*))completion;
- (void)appendReference:(const std::vector<int16_t>&)pcm rate:(int)rate;
- (void)event:(NSString*)name;
- (void)stop:(void (^)(void))completion;
@end
