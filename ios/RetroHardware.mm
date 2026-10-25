// SPDX-License-Identifier: MIT
#import "RetroHardware.h"
#import <QuartzCore/QuartzCore.h>

@interface PC98MonitorCabinet ()
@property CALayer* playbackLamp;
@end

UIColor* PC98Plastic(CGFloat b) { return [UIColor colorWithRed:b green:b*0.985 blue:b*0.91 alpha:1]; }
void PC98Gradient(CGRect r,UIColor* top,UIColor* bottom,CGFloat radius) {
    CGContextRef c=UIGraphicsGetCurrentContext(); CGContextSaveGState(c);
    [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius] addClip];
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    NSArray* colors=@[(id)top.CGColor,(id)bottom.CGColor];
    CGGradientRef gradient=CGGradientCreateWithColors(space,(__bridge CFArrayRef)colors,nullptr);
    CGContextDrawLinearGradient(c,gradient,CGPointMake(CGRectGetMidX(r),CGRectGetMinY(r)),CGPointMake(CGRectGetMidX(r),CGRectGetMaxY(r)),0);
    CGGradientRelease(gradient); CGColorSpaceRelease(space); CGContextRestoreGState(c);
}
@implementation PC98MonitorCabinet
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) { self.backgroundColor=UIColor.clearColor; self.opaque=NO; self.contentMode=UIViewContentModeRedraw;
        self.playbackLamp=[CALayer layer];self.playbackLamp.cornerRadius=1;
        self.playbackLamp.backgroundColor=[UIColor colorWithWhite:.28 alpha:1].CGColor;
        [self.layer addSublayer:self.playbackLamp];
    }
    return self;
}
- (void)setPlaybackState:(PC98PlaybackState)value {
    if(_playbackState==value) return;
    _playbackState=value;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    [self.playbackLamp removeAnimationForKey:@"pausedBlink"];
    self.playbackLamp.opacity=1;
    self.playbackLamp.backgroundColor=(value==PC98PlaybackStatePaused?[UIColor colorWithRed:.9 green:.12 blue:.08 alpha:1]:value==PC98PlaybackStateRunning?[UIColor colorWithRed:.4 green:.7 blue:.2 alpha:1]:[UIColor colorWithWhite:.28 alpha:1]).CGColor;
    [CATransaction commit];
    if(value==PC98PlaybackStatePaused) {
        CABasicAnimation* blink=[CABasicAnimation animationWithKeyPath:@"opacity"];
        blink.fromValue=@1;blink.toValue=@.15;blink.duration=.6;blink.autoreverses=YES;blink.repeatCount=HUGE_VALF;
        [self.playbackLamp addAnimation:blink forKey:@"pausedBlink"];
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect status=[self statusFrame];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.playbackLamp.frame=CGRectMake(status.origin.x-14,status.origin.y+3,6,4);
    self.playbackLamp.hidden=self.separateControls;
    [CATransaction commit];
}
- (void)setExpandedDisplay:(BOOL)value {
    if(_expandedDisplay==value) return;
    _expandedDisplay=value; [self setNeedsDisplay];[self setNeedsLayout];
}
- (void)setSeparateControls:(BOOL)value {
    if(_separateControls==value) return;
    _separateControls=value;[self setNeedsDisplay];[self setNeedsLayout];
}
- (CGRect)cabinetFrame {
    if(self.expandedDisplay) {
        CGFloat screenHeight=MAX(1,MIN(self.bounds.size.height-(self.separateControls?20:71),(self.bounds.size.width-(self.separateControls?28:36))/1.6));
        if(self.separateControls) screenHeight*=.96; // Keep the bezel clear of the display’s rounded corners.
        CGFloat width=screenHeight*1.6+(self.separateControls?16:24), height=screenHeight+(self.separateControls?16:67);
        return CGRectMake((self.bounds.size.width-width)/2,(self.bounds.size.height-height)/2,width,height);
    }
    CGFloat width=MAX(1,MIN(self.bounds.size.width-12,(self.bounds.size.height-42)*1.31));
    CGFloat height=(width-44)/1.6+92;
    return CGRectMake((self.bounds.size.width-width)/2,MAX(0,(self.bounds.size.height-height-30)/2),width,height);
}
- (CGRect)screenFrame {
    CGRect r=[self cabinetFrame];
    CGFloat side=self.expandedDisplay?(self.separateControls?8:12):22, top=self.expandedDisplay?(self.separateControls?8:10):22;
    return CGRectMake(r.origin.x+side,r.origin.y+top,MAX(1,r.size.width-side*2),MAX(1,(r.size.width-side*2)/1.6));
}
- (CGRect)controlsFrame { CGRect r=[self cabinetFrame],s=[self screenFrame]; return CGRectMake(r.origin.x+15,CGRectGetMaxY(s)+(self.expandedDisplay?10:13),r.size.width-30,self.expandedDisplay?28:30); }
- (CGRect)statusFrame { CGRect r=[self cabinetFrame]; return CGRectMake(r.origin.x+31,CGRectGetMaxY(r)-(self.expandedDisplay?15:20),r.size.width-53,self.expandedDisplay?10:12); }
- (void)drawRect:(CGRect)rect {
    CGRect r=[self cabinetFrame],screen=[self screenFrame];
    CGContextRef c=UIGraphicsGetCurrentContext();
    // Low circular foot and short neck, like a desktop CRT swivel stand.
    if(!self.expandedDisplay) {
    CGRect foot=CGRectMake(CGRectGetMidX(r)-r.size.width*.26,CGRectGetMaxY(r)+13,r.size.width*.52,15);
    CGContextSaveGState(c); CGContextSetShadowWithColor(c,CGSizeMake(0,4),7,[UIColor colorWithWhite:0 alpha:.28].CGColor);
    [PC98Plastic(.55) setFill]; [[UIBezierPath bezierPathWithOvalInRect:foot] fill]; CGContextRestoreGState(c);
    [PC98Plastic(.77) setFill]; [[UIBezierPath bezierPathWithOvalInRect:CGRectOffset(foot,0,-3)] fill];
    PC98Gradient(CGRectMake(CGRectGetMidX(r)-r.size.width*.13,CGRectGetMaxY(r)-3,r.size.width*.26,20),PC98Plastic(.57),PC98Plastic(.78),4);
    }
    CGContextSaveGState(c); CGContextSetShadowWithColor(c,CGSizeMake(0,6),9,[UIColor colorWithWhite:0 alpha:.25].CGColor);
    [PC98Plastic(.65) setFill]; [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:12] fill]; CGContextRestoreGState(c);
    PC98Gradient(r,PC98Plastic(.94),PC98Plastic(.75),12);
    [PC98Plastic(.98) setStroke]; UIBezierPath* edge=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(r,1,1) cornerRadius:11]; edge.lineWidth=1; [edge stroke];
    // Sloped inner bezel: bright lower lip and shaded upper recess.
    CGRect rim=CGRectInset(screen,-7,-7);
    PC98Gradient(rim,PC98Plastic(.43),PC98Plastic(.98),7);
    PC98Gradient(CGRectInset(rim,3,3),[UIColor colorWithWhite:.08 alpha:1],[UIColor colorWithWhite:.22 alpha:1],5);
    [[UIColor colorWithRed:.035 green:.055 blue:.052 alpha:1] setFill]; [[UIBezierPath bezierPathWithRoundedRect:screen cornerRadius:4] fill];
    // Small unbranded power lamp and inset control strip.
    if(!self.separateControls) {
    PC98Gradient(CGRectInset([self controlsFrame],-3,-3),PC98Plastic(.63),PC98Plastic(.87),4);
    }
}
@end
