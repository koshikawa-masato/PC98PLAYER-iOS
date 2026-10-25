// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>
@interface PC98Keyboard : UIView
@property(nonatomic) BOOL hardwareLayout;
@property(copy) void (^keyChanged)(int scan, BOOL down);
@property(copy) void (^optionsRequested)(void);
- (void)releaseAll;
- (void)repeatHeldKeys;
#ifdef PC98PLAYER_TESTING
- (BOOL)tapReturnSectionsForTesting;
- (BOOL)hardwareLayoutForTesting;
- (BOOL)tapScanForTesting:(int)scan;
- (BOOL)pressScansForTesting:(NSArray<NSNumber*>*)scans;
- (BOOL)releaseScanForTesting:(int)scan cancelled:(BOOL)cancelled;
#endif
@end
// USB HID usages from hardware keyboards share the guest scan codes with touch keys.
int pc98_scan_from_hid(NSInteger usage);
