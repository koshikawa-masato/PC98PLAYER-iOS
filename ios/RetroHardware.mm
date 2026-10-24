// SPDX-License-Identifier: MIT
#import "RetroHardware.h"

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
    if((self=[super initWithFrame:frame])) { self.backgroundColor=UIColor.clearColor; self.opaque=NO; self.contentMode=UIViewContentModeRedraw; }
    return self;
}
- (void)setExpandedDisplay:(BOOL)value {
    if(_expandedDisplay==value) return;
    _expandedDisplay=value; [self setNeedsDisplay];
}
- (CGRect)cabinetFrame {
    if(self.expandedDisplay) {
        CGFloat screenHeight=MAX(1,MIN(self.bounds.size.height-71,(self.bounds.size.width-36)/1.6));
        CGFloat width=screenHeight*1.6+24, height=screenHeight+67;
        return CGRectMake((self.bounds.size.width-width)/2,(self.bounds.size.height-height)/2,width,height);
    }
    CGFloat width=MAX(1,MIN(self.bounds.size.width-12,(self.bounds.size.height-42)*1.31));
    CGFloat height=(width-44)/1.6+92;
    return CGRectMake((self.bounds.size.width-width)/2,MAX(0,(self.bounds.size.height-height-30)/2),width,height);
}
- (CGRect)screenFrame {
    CGRect r=[self cabinetFrame];
    CGFloat side=self.expandedDisplay?12:22, top=self.expandedDisplay?10:22;
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
    PC98Gradient(CGRectInset([self controlsFrame],-3,-3),PC98Plastic(.63),PC98Plastic(.87),4);
    CGRect status=[self statusFrame];
    [[UIColor colorWithRed:.23 green:.36 blue:.18 alpha:1] setFill]; [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(status.origin.x-14,status.origin.y+3,6,4) cornerRadius:1] fill];
    [[UIColor colorWithRed:.66 green:.82 blue:.38 alpha:1] setFill]; UIRectFill(CGRectMake(status.origin.x-13,status.origin.y+3,4,1));
}
@end
