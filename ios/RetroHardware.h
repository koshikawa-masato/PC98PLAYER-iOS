// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>

// Drawn with UIKit so the hardware skin scales without bundled photos or logos.
UIColor* PC98Plastic(CGFloat brightness);
void PC98Gradient(CGRect rect, UIColor* top, UIColor* bottom, CGFloat radius);
@interface PC98MonitorCabinet : UIView
- (CGRect)screenFrame;
- (CGRect)controlsFrame;
- (CGRect)statusFrame;
@end
