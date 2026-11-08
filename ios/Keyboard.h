// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>
@interface PC98Keyboard : UIView
@property(nonatomic) BOOL hardwareLayout;
@property(copy) void (^pauseChanged)(void);
@property(copy) void (^controllerSettingsOpening)(void);
- (void)loadControllerBindingsForGame:(NSString*)identifier;
- (int)controllerScanAtIndex:(NSUInteger)index;
- (void)updateControllerPause:(BOOL)paused enabled:(BOOL)enabled;
@property(copy) void (^keyChanged)(int scan, BOOL down);
- (void)releaseAll;
- (void)repeatHeldKeys;
#ifdef PC98PLAYER_TESTING
- (BOOL)controllerChordForTesting:(BOOL (^)(int scan))isDown;
- (BOOL)tapReturnSectionsForTesting;
- (BOOL)hardwareLayoutForTesting;
- (BOOL)tapScanForTesting:(int)scan;
- (BOOL)pressScansForTesting:(NSArray<NSNumber*>*)scans;
- (BOOL)releaseScanForTesting:(int)scan cancelled:(BOOL)cancelled;
#endif
@end
// USB HID usages from hardware keyboards share the guest scan codes with touch keys.
int pc98_scan_from_hid(NSInteger usage);
