// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>
@interface PC98Keyboard : UIView
@property(copy) void (^keyChanged)(int scan, BOOL down);
- (void)releaseAll;
- (void)repeatHeldKeys;
#ifdef PC98PLAYER_TESTING
- (BOOL)tapReturnSectionsForTesting;
- (BOOL)tapScanForTesting:(int)scan;
#endif
@end
// USB HID usages from hardware keyboards share the guest scan codes with touch keys.
int pc98_scan_from_hid(NSInteger usage);
