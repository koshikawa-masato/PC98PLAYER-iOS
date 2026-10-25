// SPDX-License-Identifier: MIT
#import "RetroHardware.h"
#import <QuartzCore/QuartzCore.h>

@interface PC98MonitorCabinet ()
@property CALayer* playbackLamp;
@property CALayer* playbackGlow;
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
// A tiny native-resolution sprite keeps the lens and stepped light halo crisp.
static UIImage* playbackLampImage(BOOL illuminated,BOOL red) {
    static const char* dots[]={"0001111000","0123443210","1234554321","1234554321","0123443210","0001111000"};
    NSArray<UIColor*>* shades;
    if(!illuminated) shades=@[UIColor.clearColor,[UIColor colorWithWhite:.2 alpha:.2],[UIColor colorWithWhite:.16 alpha:1],[UIColor colorWithWhite:.24 alpha:1],[UIColor colorWithWhite:.3 alpha:1],[UIColor colorWithWhite:.38 alpha:1]];
    else if(red) shades=@[UIColor.clearColor,[UIColor colorWithRed:1 green:.12 blue:.03 alpha:.22],[UIColor colorWithRed:.48 green:.04 blue:.02 alpha:1],[UIColor colorWithRed:.85 green:.08 blue:.03 alpha:1],[UIColor colorWithRed:1 green:.3 blue:.1 alpha:1],[UIColor colorWithRed:1 green:.78 blue:.5 alpha:1]];
    else shades=@[UIColor.clearColor,[UIColor colorWithRed:.4 green:1 blue:.12 alpha:.22],[UIColor colorWithRed:.12 green:.33 blue:.04 alpha:1],[UIColor colorWithRed:.3 green:.65 blue:.06 alpha:1],[UIColor colorWithRed:.6 green:1 blue:.18 alpha:1],[UIColor colorWithRed:.88 green:1 blue:.62 alpha:1]];
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(10,6),NO,1);
    CGContextSetShouldAntialias(UIGraphicsGetCurrentContext(),NO);
    for(int y=0;y<6;++y) for(int x=0;x<10;++x) {
        [shades[dots[y][x]-'0'] setFill];UIRectFill(CGRectMake(x,y,1,1));
    }
    UIImage* image=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();return image;
}
@implementation PC98MonitorCabinet
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) { self.backgroundColor=UIColor.clearColor; self.opaque=NO; self.contentMode=UIViewContentModeRedraw;
        self.playbackLamp=[CALayer layer];
        self.playbackLamp.contents=(__bridge id)playbackLampImage(NO,NO).CGImage;
        self.playbackLamp.magnificationFilter=kCAFilterNearest;self.playbackLamp.minificationFilter=kCAFilterNearest;
        self.playbackGlow=[CALayer layer];self.playbackGlow.hidden=YES;
        self.playbackGlow.magnificationFilter=kCAFilterNearest;self.playbackGlow.minificationFilter=kCAFilterNearest;
        [self.playbackLamp addSublayer:self.playbackGlow];[self.layer addSublayer:self.playbackLamp];
    }
    return self;
}
- (void)setPlaybackState:(PC98PlaybackState)value {
    if(_playbackState==value) return;
    _playbackState=value;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    [self.playbackGlow removeAnimationForKey:@"pausedBlink"];
    self.playbackGlow.opacity=1;self.playbackGlow.hidden=value==PC98PlaybackStateInactive;
    self.playbackGlow.contents=(__bridge id)playbackLampImage(YES,value==PC98PlaybackStatePaused).CGImage;
    [CATransaction commit];
    if(value==PC98PlaybackStatePaused) {
        // Discrete on/off frames, with the unlit lens visible between flashes.
        CAKeyframeAnimation* blink=[CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        blink.values=@[@1,@0,@0];blink.keyTimes=@[@0,@.5,@1];blink.calculationMode=kCAAnimationDiscrete;
        blink.duration=1.2;blink.repeatCount=HUGE_VALF;
        [self.playbackGlow addAnimation:blink forKey:@"pausedBlink"];
    }
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect status=[self statusFrame];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    CGFloat scale=self.window.screen.scale ?: UIScreen.mainScreen.scale;
    self.playbackLamp.frame=CGRectMake(round((status.origin.x-17)*scale)/scale,round((status.origin.y+2)*scale)/scale,10,6);
    self.playbackGlow.frame=self.playbackLamp.bounds;
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
