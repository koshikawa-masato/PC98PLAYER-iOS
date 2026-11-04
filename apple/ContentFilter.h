// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>
#include "ContentFilterPolicy.h"
NS_ASSUME_NONNULL_BEGIN
@interface PC98ContentFilter : NSObject
@property(nonatomic,readonly) content_filter::Settings settings;
@property(nonatomic,readonly) NSTimeInterval lastProcessingTime;
@property(nonatomic,readonly,nullable) NSString* lastError;
- (void)configure:(content_filter::Settings)settings;
- (void)reset;
// Main-thread API. At most one job and one replaceable pending image are retained.
// Enabled callers keep their previous filtered frame until completion.
- (void)submitImage:(UIImage*)image completion:(void (^)(UIImage* _Nullable,NSString* _Nullable))completion;
#ifdef PC98PLAYER_TESTING
- (void)runSmokeChecks:(void (^)(NSDictionary*,UIImage*))completion;
#endif
@end
NS_ASSUME_NONNULL_END
