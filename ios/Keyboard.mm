// SPDX-License-Identifier: MIT
#import "Keyboard.h"
#import "RetroHardware.h"
#include <map>
#include <vector>
#include <algorithm>

#include <set>
#import <QuartzCore/QuartzCore.h>
struct Key { const char* name; int scan; float width=1; };
static const std::vector<std::vector<Key>> rows = {
    {{"VF1",0x52},{"VF2",0x53},{"VF3",0x54},{"VF4",0x55},{"VF5",0x56}},
    {{"STOP",0x60},{"COPY",0x61},{"F1",0x62},{"F2",0x63},{"F3",0x64},{"F4",0x65},{"F5",0x66},{"F6",0x67},{"F7",0x68},{"F8",0x69},{"F9",0x6A},{"F10",0x6B}},
    {{"ESC",0},{"1",1},{"2",2},{"3",3},{"4",4},{"5",5},{"6",6},{"7",7},{"8",8},{"9",9},{"0",10},{"-",11},{"^",12},{"¥",13},{"BS",14,1.4}},
    {{"TAB",15,1.4},{"Q",16},{"W",17},{"E",18},{"R",19},{"T",20},{"Y",21},{"U",22},{"I",23},{"O",24},{"P",25},{"@",26},{"[",27},{"↵",28,1.4}},
    {{"CTRL",0x74,1.4},{"A",29},{"S",30},{"D",31},{"F",32},{"G",33},{"H",34},{"J",35},{"K",36},{"L",37},{";",38},{":",39},{"]",40},{"↵",28,1.4}},
    {{"SHIFT",0x70,1.8},{"Z",41},{"X",42},{"C",43},{"V",44},{"B",45},{"N",46},{"M",47},{",",48},{".",49},{"/",50},{"_",51},{"SHIFT",0x70,1.8}},
    {{"CAPS",0x71},{"かな",0x72},{"GRPH",0x73},{"NFER",0x51},{"SPACE",0x34,4},{"XFER",0x35},{"↑",0x3A},{"←",0x3B},{"↓",0x3D},{"→",0x3C}},
    {{"HELP",0x3F},{"HOME",0x3E},{"INS",0x38},{"DEL",0x39},{"R↓",0x37},{"R↑",0x36},{"7",0x42},{"8",0x43},{"9",0x44},{"/",0x41},{"*",0x45},{"-",0x40}},
    {{"4",0x46},{"5",0x47},{"6",0x48},{"+",0x49},{"1",0x4A},{"2",0x4B},{"3",0x4C},{"=",0x4D},{"0",0x4E},{",",0x4F},{".",0x50},{"↵",28}}
};
struct HardwareKey {int scan; CGFloat x,y,w,h;};
static std::vector<HardwareKey> hardwareKeys() {
    std::vector<HardwareKey> keys;
    auto add=[&](int scan,CGFloat x,CGFloat y,CGFloat w=29,CGFloat h=30) { keys.push_back({scan,x,y,w,h}); };
    add(0x60,28,56,35); add(0x61,70,56,35);
    for(int i=0;i<10;++i) add(0x62+i,111+i*41+(i>=5?7:0),56,37);
    for(int i=0;i<5;++i) add(0x52+i,537+i*40,56,36);
    add(0,28,104,38);
    for(int i=0;i<13;++i) add(1+i,71+i*33,104);
    add(14,500,104,32);
    add(15,28,138,54);
    for(int i=0;i<12;++i) add(16+i,86+i*32.5,138);
    add(28,476,138,56,63);
    add(0x74,28,171,26); add(0x71,58,171,26);
    for(int i=0;i<12;++i) add(29+i,88+i*33,171);
    add(0x70,28,204,79);
    for(int i=0;i<11;++i) add(41+i,111+i*33,204);
    add(0x70,476,204,56);
    add(0x72,91,237,29); add(0x73,125,237,29); add(0x51,160,237,44);
    add(0x34,210,237,208); add(0x35,424,237,46);
    add(0x38,536,104,32); add(0x39,572,104,32);
    add(0x36,536,138,32); add(0x37,572,138,32);
    add(0x3A,536,171,68); add(0x3B,536,204,32); add(0x3C,572,204,32); add(0x3D,536,237,68);
    const int pad[5][4]={{0x3E,0x3F,0x40,0x41},{0x42,0x43,0x44,0x45},{0x46,0x47,0x48,0x49},{0x4A,0x4B,0x4C,0x4D},{0x4E,0x4F,0x50,28}};
    for(int row=0;row<5;++row) for(int col=0;col<4;++col) add(pad[row][col],612+col*33,104+row*33.25,29);
    return keys;
}
@interface PC98KeyButton : UIButton
@property(copy) BOOL (^activate)(void);
@property(nonatomic) BOOL retroPressed;
@property BOOL modifier;
@property BOOL steppedReturn;
@property CGFloat detailScale;
@property BOOL expandedLegends;
@property NSString* kana;
@end
@implementation PC98KeyButton
- (BOOL)accessibilityActivate { return self.activate ? self.activate() : NO; }
- (void)setRetroPressed:(BOOL)value { _retroPressed=value; [self setNeedsDisplay]; [self setNeedsLayout]; }
- (UIBezierPath*)capPath:(CGRect)r {
    if(!self.steppedReturn) return [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:2*self.detailScale];
    CGFloat notch=r.size.width*12/56, step=r.origin.y+r.size.height*31/63;
    UIBezierPath* p=[UIBezierPath bezierPath];
    [p moveToPoint:r.origin]; [p addLineToPoint:CGPointMake(CGRectGetMaxX(r),r.origin.y)];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r),CGRectGetMaxY(r))];
    [p addLineToPoint:CGPointMake(r.origin.x+notch,CGRectGetMaxY(r))];
    [p addLineToPoint:CGPointMake(r.origin.x+notch,step)];
    [p addLineToPoint:CGPointMake(r.origin.x,step)]; [p closePath]; return p;
}
- (BOOL)containsKeyPoint:(CGPoint)point { return [[self capPath:self.bounds] containsPoint:point]; }
- (CGRect)titleRectForContentRect:(CGRect)contentRect {
    if(self.steppedReturn) return CGRectMake(self.bounds.size.width*.25,self.bounds.size.height*.28,self.bounds.size.width*.67,self.bounds.size.height*.4);
    CGFloat inset=(self.bounds.size.width<24 ? 2 : 4)*self.detailScale;
    return CGRectMake(inset,(self.retroPressed?4:2)*self.detailScale,MAX(1,self.bounds.size.width-inset*2),self.bounds.size.height*(self.kana.length?.56:.85));
}
- (void)layoutSubviews {
    CGFloat size=self.expandedLegends ? MAX(5,MIN(16,MIN(self.bounds.size.width*.58,self.bounds.size.height*.34))) : MAX(3,MIN(13*self.detailScale,MIN(self.bounds.size.width*.36,self.bounds.size.height*.32)));
    self.titleLabel.font=[UIFont monospacedSystemFontOfSize:size weight:UIFontWeightMedium];
    [super layoutSubviews];
}
- (void)drawRect:(CGRect)rect {
    CGFloat detail=self.detailScale;
    CGRect r=CGRectInset(self.bounds,.5*detail,.5*detail);
    [[UIColor colorWithWhite:.20 alpha:1] setFill]; [[self capPath:r] fill];
    CGContextRef context=UIGraphicsGetCurrentContext(); CGContextSaveGState(context);
    [[self capPath:r] addClip];
    CGRect base=CGRectInset(r,detail,detail);
    PC98Gradient(base,PC98Plastic(.76),PC98Plastic(.48),2.5*detail);
    CGRect face=CGRectMake(2*detail,(self.retroPressed?4:1.5)*detail,MAX(1,r.size.width-3*detail),MAX(1,r.size.height-(self.retroPressed?5:6)*detail));
    CGFloat tone=self.modifier?.75:.95;
    if(self.retroPressed) tone-=.13;
    CGContextSaveGState(context); [[self capPath:face] addClip];
    PC98Gradient(face,PC98Plastic(tone),PC98Plastic(tone-.10),2*detail); CGContextRestoreGState(context);
    [PC98Plastic(MIN(1,tone+.08)) setStroke];
    UIBezierPath* edge=[self capPath:CGRectInset(face,.5*detail,.5*detail)]; edge.lineWidth=.6*detail; [edge stroke];
    if(self.kana.length) {
        CGFloat size=self.expandedLegends ? MAX(4,MIN(12,MIN(self.bounds.size.width*.48,self.bounds.size.height*.24))) : MAX(3,MIN(10*detail,MIN(self.bounds.size.width*.30,self.bounds.size.height*.28)));
        NSDictionary* style=@{NSFontAttributeName:[UIFont systemFontOfSize:size],NSForegroundColorAttributeName:[UIColor colorWithWhite:.30 alpha:1]};
        CGSize label=[self.kana sizeWithAttributes:style];
        [self.kana drawAtPoint:CGPointMake(CGRectGetMaxX(face)-label.width-2*detail,CGRectGetMaxY(face)-label.height-detail) withAttributes:style];
    }
    CGContextRestoreGState(context);
    if(self.retroPressed && self.tag>=0x70 && self.tag<=0x74) {
        [[UIColor colorWithRed:.55 green:.29 blue:.08 alpha:1] setFill];
        UIRectFill(CGRectMake(CGRectGetMaxX(face)-5,CGRectGetMinY(face)+2,3,2));
    }
}
@end
@interface PC98Keyboard () {
    std::map<UITouch*,UIButton*> touches;
    std::map<int,int> counts;
    std::set<int> latched;
    std::map<int,double> repeatAt;
}
@property(strong) NSArray<NSArray<UIButton*>*>* keys;
@end
@implementation PC98Keyboard
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.multipleTouchEnabled=YES; self.backgroundColor=UIColor.clearColor; self.opaque=NO; self.contentMode=UIViewContentModeRedraw;
        self.layer.shadowColor=UIColor.blackColor.CGColor; self.layer.shadowOffset=CGSizeMake(0,5); self.layer.shadowOpacity=.3; self.layer.shadowRadius=6;
        NSMutableArray* groups=[NSMutableArray new];
        for(const auto& row:rows) {
            NSMutableArray* group=[NSMutableArray new];
            for(const auto& k:row) {
                PC98KeyButton* b=[PC98KeyButton buttonWithType:UIButtonTypeCustom]; b.tag=k.scan; b.detailScale=1;
                [b setTitle:[NSString stringWithUTF8String:k.name] forState:UIControlStateNormal];
                b.titleLabel.font=[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold];
                b.titleLabel.adjustsFontSizeToFitWidth=YES; b.titleLabel.minimumScaleFactor=0.5;
                [b setTitleColor:[UIColor colorWithWhite:.14 alpha:1] forState:UIControlStateNormal];
                b.backgroundColor=UIColor.clearColor; b.modifier=(k.scan==0 || k.scan==14 || k.scan==15 || k.scan==28 || k.scan==0x60 || k.scan==0x61 || k.scan>=0x70 || k.scan==0x51 || k.scan==0x35 || k.scan==0x34);
                static NSDictionary* kana=@{@1:@"ぬ",@2:@"ふ",@3:@"あ",@4:@"う",@5:@"え",@6:@"お",@7:@"や",@8:@"ゆ",@9:@"よ",@10:@"わ",@11:@"ほ",@12:@"へ",@13:@"ー",@16:@"た",@17:@"て",@18:@"い",@19:@"す",@20:@"か",@21:@"ん",@22:@"な",@23:@"に",@24:@"ら",@25:@"せ",@26:@"゛",@27:@"゜",@29:@"ち",@30:@"と",@31:@"し",@32:@"は",@33:@"き",@34:@"く",@35:@"ま",@36:@"の",@37:@"り",@38:@"れ",@39:@"け",@40:@"む",@41:@"つ",@42:@"さ",@43:@"そ",@44:@"ひ",@45:@"こ",@46:@"み",@47:@"も",@48:@"ね",@49:@"る",@50:@"め",@51:@"ろ"};
                b.kana=kana[@(k.scan)];
                b.userInteractionEnabled=NO; b.accessibilityLabel=[NSString stringWithFormat:@"PC98 %@",b.currentTitle];
                b.isAccessibilityElement=YES; b.accessibilityTraits=UIAccessibilityTraitKeyboardKey;
                __weak PC98Keyboard* weak=self; __weak UIButton* weakButton=b;
                b.activate=^BOOL { PC98Keyboard* keyboard=weak; UIButton* button=weakButton; if(!keyboard || !button) return NO; [keyboard updateKey:button down:YES]; [keyboard updateKey:button down:NO]; return YES; };
                [self addSubview:b]; [group addObject:b];
            }
            [groups addObject:group];
        }
        self.keys=groups;
    }
    return self;
}
- (void)setHardwareLayout:(BOOL)value {
    if(_hardwareLayout==value) return;
    [self releaseAll]; _hardwareLayout=value; [self setNeedsLayout]; [self setNeedsDisplay];
}
- (CGRect)hardwareFrame {
    CGRect available=CGRectInset(self.bounds,2,4);
    // A portrait outer display or side pane must not stretch the six rows into
    // thin vertical strips. Use the full width and keep a keyboard-like height.
    CGFloat height=MAX(1,MIN(available.size.height,available.size.width*.40));
    return CGRectMake(available.origin.x,CGRectGetMidY(available)-height/2,available.size.width,height);
}
- (CGFloat)hardwareY:(CGFloat)y {
    // Keep the original row order and stagger; spend the available height on keys,
    // rather than uniformly scaling the photograph's unused case margins.
    CGFloat height=[self hardwareFrame].size.height;
    CGFloat top=MIN(16,height*.04), bottom=MIN(12,height*.03), gap=MIN(5,MAX(2,height*.012));
    CGFloat keyHeight=MAX(1,(height-top-bottom-gap*5-4)/6);
    const CGFloat source[]={0,56,86,104,134,138,168,171,201,204,234,237,267,310};
    CGFloat target[]={0,top,top+keyHeight,0,0,0,0,0,0,0,0,0,height-bottom,height};
    target[3]=target[2]+gap+4;
    target[4]=target[3]+keyHeight; target[5]=target[4]+gap;
    target[6]=target[5]+keyHeight; target[7]=target[6]+gap;
    target[8]=target[7]+keyHeight; target[9]=target[8]+gap;
    target[10]=target[9]+keyHeight; target[11]=target[10]+gap;
    for(int i=0;i<13;++i) if(y<=source[i+1])
        return target[i]+(y-source[i])/(source[i+1]-source[i])*(target[i+1]-target[i]);
    return height;
}
- (CGFloat)hardwareX:(CGFloat)x {
    CGFloat width=[self hardwareFrame].size.width, edge=MIN(6,width*.02);
    if(x<26) return edge*x/26;
    if(x>743) return width-edge+(x-743)*edge/17;
    return edge+(x-26)*(width-edge*2)/717;
}
- (CGRect)hardwareRect:(CGRect)r {
    CGRect frame=[self hardwareFrame];
    CGFloat left=[self hardwareX:r.origin.x], right=[self hardwareX:CGRectGetMaxX(r)];
    CGFloat top=[self hardwareY:r.origin.y], bottom=[self hardwareY:CGRectGetMaxY(r)];
    return CGRectMake(frame.origin.x+left,frame.origin.y+top,MAX(1,right-left),MAX(1,bottom-top));
}
- (void)drawHardwareCase {
    CGRect frame=[self hardwareFrame];
    auto rect=[&](CGFloat x,CGFloat y,CGFloat w,CGFloat h) { return [self hardwareRect:CGRectMake(x,y,w,h)]; };
    PC98Gradient(frame,PC98Plastic(.91),PC98Plastic(.69),10);
    [PC98Plastic(.98) setStroke]; [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(frame,1,1) cornerRadius:9] stroke];
    PC98Gradient(rect(56,9,470,39),PC98Plastic(.75),PC98Plastic(.87),1);
    PC98Gradient(rect(26,53,717,36),PC98Plastic(.35),PC98Plastic(.57),2);
    PC98Gradient(rect(26,101,580,170),PC98Plastic(.35),PC98Plastic(.57),2);
    PC98Gradient(rect(610,101,133,170),PC98Plastic(.35),PC98Plastic(.57),2);
    PC98Gradient(rect(27,236,59,35),PC98Plastic(.84),PC98Plastic(.74),1);
    PC98Gradient(rect(475,236,57,35),PC98Plastic(.84),PC98Plastic(.74),1);
    NSArray* names=@[@"CAPS",@"かな"];
    for(int i=0;i<2;++i) {
        [PC98Plastic(.38) setFill]; UIRectFill(rect(33,244+i*10,4,3));
        if(latched.count(0x71+i)) { [[UIColor colorWithRed:.64 green:.76 blue:.30 alpha:1] setFill]; UIRectFill(rect(33,244+i*10,3,2)); }
        CGRect label=rect(42,242+i*10,40,8);
        [names[i] drawAtPoint:label.origin withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:MAX(6,MIN(8,label.size.height))],NSForegroundColorAttributeName:PC98Plastic(.30)}];
    }
}
- (void)drawRect:(CGRect)rect {
    if(self.hardwareLayout) { [self drawHardwareCase]; return; }
    CGRect shell=CGRectInset(self.bounds,.5,.5);
    PC98Gradient(shell,PC98Plastic(.91),PC98Plastic(.69),10);
    [PC98Plastic(.97) setStroke]; UIBezierPath* edge=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(shell,1,1) cornerRadius:9]; edge.lineWidth=1; [edge stroke];
    // The top deck has indicators on the left and a separate VF bank on the right.
    PC98Gradient(CGRectMake(10,7,78,31),PC98Plastic(.77),PC98Plastic(.85),2);
    NSArray* lampNames=@[@"CAPS",@"かな",@"GRPH"];
    for(int i=0;i<3;++i) {
        CGFloat x=19+i*24;
        [PC98Plastic(.41) setFill]; UIRectFill(CGRectMake(x+3,13,7,3));
        if(latched.count(0x71+i)) { [[UIColor colorWithRed:.64 green:.76 blue:.30 alpha:1] setFill]; UIRectFill(CGRectMake(x+4,13,5,2)); }
        [lampNames[i] drawAtPoint:CGPointMake(x-2,23) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:6],NSForegroundColorAttributeName:[UIColor colorWithWhite:.27 alpha:1]}];
    }
    PC98Gradient(CGRectInset([self vfBankFrame],-2,-2),PC98Plastic(.40),PC98Plastic(.60),3);
    CGRect well=CGRectMake(8,46,self.bounds.size.width-16,self.bounds.size.height-56);
    PC98Gradient(well,PC98Plastic(.37),PC98Plastic(.54),3);
    // Separate the function keys and the auxiliary/numeric bank with case ribs.
    CGFloat content=well.size.height-8, rowHeight=content/8.0;
    [PC98Plastic(.73) setFill]; UIRectFill(CGRectMake(8,well.origin.y+rowHeight-1,well.size.width,4));
    UIRectFill(CGRectMake(8,well.origin.y+rowHeight*6-1,well.size.width,4));
}
- (CGRect)vfBankFrame {
    CGFloat width=MIN((self.bounds.size.width-20)*.58,232);
    return CGRectMake(self.bounds.size.width-10-width,8,width,30);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    for(size_t r=0;r<rows.size();++r) for(size_t i=0;i<rows[r].size();++i) {
        PC98KeyButton* key=(PC98KeyButton*)self.keys[r][i]; const Key& definition=rows[r][i];
        key.hidden=NO; key.isAccessibilityElement=YES; key.steppedReturn=NO; key.detailScale=1; key.expandedLegends=NO;
        [key setTitle:[NSString stringWithUTF8String:definition.name] forState:UIControlStateNormal];
        key.modifier=(definition.scan==0 || definition.scan==14 || definition.scan==15 || definition.scan==28 || definition.scan==0x60 || definition.scan==0x61 || definition.scan>=0x70 || definition.scan==0x51 || definition.scan==0x35 || definition.scan==0x34);
    }
    if(self.hardwareLayout) { [self layoutHardwareKeys]; return; }
    CGFloat gap=3, left=10, top=48, usable=self.bounds.size.width-20;
    CGRect bank=[self vfBankFrame]; CGFloat vfWidth=(bank.size.width-gap*4)/5;
    for(NSUInteger i=0;i<5;++i)
        self.keys[0][i].frame=CGRectMake(bank.origin.x+i*(vfWidth+gap),bank.origin.y,vfWidth,bank.size.height);
    CGFloat h=(self.bounds.size.height-top-12-gap*(rows.size()-2))/(rows.size()-1);
    for(size_t r=1;r<rows.size();++r) {
        float units=0; for(auto k:rows[r]) units+=k.width;
        CGFloat unit=(usable-gap*(rows[r].size()-1))/units, x=left;
        for(size_t c=0;c<rows[r].size();++c) {
            CGFloat w=unit*rows[r][c].width;
            self.keys[r][c].frame=CGRectMake(x,top+(r-1)*(h+gap),w,MAX(1,h)); x+=w+gap;
        }
    }
    // The two row slots form one tall Return key; the numeric Return stays separate.
    UIButton* upperReturn=self.keys[3].lastObject;
    UIButton* lowerReturn=self.keys[4].lastObject;
    upperReturn.frame=CGRectUnion(upperReturn.frame,lowerReturn.frame);
    lowerReturn.hidden=YES; lowerReturn.isAccessibilityElement=NO;
    [self bringSubviewToFront:upperReturn];
    [self setNeedsDisplay];
}
- (void)layoutHardwareKeys {
    CGRect frame=[self hardwareFrame]; CGFloat scale=frame.size.width/760;
    for(NSArray* row in self.keys) for(UIButton* key in row) { key.hidden=YES; key.isAccessibilityElement=NO; }
    std::set<UIButton*> placed;
    for(const HardwareKey& spec:hardwareKeys()) {
        PC98KeyButton* button=nil;
        for(NSArray* row in self.keys) for(PC98KeyButton* key in row)
            if(!button && key.tag==spec.scan && !placed.count(key)) button=key;
        if(!button) continue;
        placed.insert(button); button.detailScale=scale; button.expandedLegends=YES; button.hidden=NO; button.isAccessibilityElement=YES;
        button.frame=[self hardwareRect:CGRectMake(spec.x,spec.y,spec.w,spec.h)];
        button.steppedReturn=spec.scan==28 && spec.h>40;
        if(spec.scan==0x34) [button setTitle:@"" forState:UIControlStateNormal];
        if(spec.scan>=0x52 && spec.scan<=0x6B) button.modifier=YES;
        [button setNeedsDisplay];
    }
    [self setNeedsDisplay];
}
- (BOOL)isLatch:(int)scan { return scan==0x70 || scan==0x71 || scan==0x72 || scan==0x73 || scan==0x74; }
- (void)updateKey:(UIButton*)key down:(BOOL)down {
    int scan=(int)key.tag;
    if([self isLatch:scan]) {
        if(!down) return;
        if(latched.count(scan)) latched.erase(scan); else latched.insert(scan);
        if(self.keyChanged) self.keyChanged(scan,latched.count(scan)>0);
    } else {
        int previous=counts[scan]; counts[scan]=std::max(0,previous+(down?1:-1));
        if(!previous && down) repeatAt[scan]=CACurrentMediaTime()+0.45;
        if(!counts[scan]) repeatAt.erase(scan);
        if(self.keyChanged && ((previous==0)!=(counts[scan]==0))) self.keyChanged(scan,counts[scan]>0);
    }
    for(NSArray* row in self.keys) for(PC98KeyButton* b in row) if(b.tag==scan)
        b.retroPressed=counts[scan]>0 || latched.count(scan);
    [self setNeedsDisplay];
}
- (UIButton*)keyAtPoint:(CGPoint)point {
    for(NSArray* row in self.keys) for(PC98KeyButton* key in row)
        if(!key.hidden && CGRectContainsPoint(key.frame,point) && [key containsKeyPoint:CGPointMake(point.x-key.frame.origin.x,point.y-key.frame.origin.y)]) return key;
    if(!self.hardwareLayout) return nil;
    // Fill narrow gaps with the nearest adjacent key. Large case areas and the
    // Return notch remain inactive; no key receives an overlapping touch target.
    UIButton* nearest=nil; CGFloat best=CGFLOAT_MAX;
    for(NSArray* row in self.keys) for(PC98KeyButton* key in row) if(!key.hidden) {
        CGPoint local=CGPointMake(point.x-key.frame.origin.x,point.y-key.frame.origin.y);
        if(key.steppedReturn && CGRectContainsPoint(key.bounds,local) && ![key containsKeyPoint:local]) continue;
        if(!CGRectContainsPoint(CGRectInset(key.frame,-1.5,-3),point)) continue;
        CGFloat dx=MAX(MAX(CGRectGetMinX(key.frame)-point.x,point.x-CGRectGetMaxX(key.frame)),0);
        CGFloat dy=MAX(MAX(CGRectGetMinY(key.frame)-point.y,point.y-CGRectGetMaxY(key.frame)),0);
        CGFloat distance=dx*dx+dy*dy;
        if(distance<best) { best=distance; nearest=key; }
    }
    return nearest;
}
- (void)touchesBegan:(NSSet<UITouch*>*)set withEvent:(UIEvent*)event {
    for(UITouch* t in set) {
        UIButton* key=[self keyAtPoint:[t locationInView:self]];
        if(key) { touches[t]=key; [self updateKey:key down:YES]; }
    }
}
- (void)touchesEnded:(NSSet<UITouch*>*)set withEvent:(UIEvent*)event {
    for(UITouch* t in set) { auto it=touches.find(t); if(it!=touches.end()) { [self updateKey:it->second down:NO]; touches.erase(it); } }
}
- (void)touchesCancelled:(NSSet<UITouch*>*)set withEvent:(UIEvent*)event { [self touchesEnded:set withEvent:event]; }
- (void)repeatHeldKeys {
    double now=CACurrentMediaTime();
    for(auto& pair:repeatAt) if(now>=pair.second) { if(self.keyChanged) self.keyChanged(pair.first,YES); pair.second=now+0.05; }
}
#ifdef PC98PLAYER_TESTING
- (BOOL)tapReturnSectionsForTesting {
    [self layoutIfNeeded];
    UIButton* key=self.keys[3].lastObject;
    // Include the former seam as well as the upper and lower ends.
    for(CGFloat fraction : {.15,.5,.85}) {
        CGPoint point=CGPointMake(key.frame.origin.x+key.frame.size.width*.65,key.frame.origin.y+key.frame.size.height*fraction);
        UIButton* hit=[self keyAtPoint:point];
        if(hit!=key || hit.tag!=28 || ![hit accessibilityActivate]) return NO;
    }
    return YES;
}
- (BOOL)hardwareLayoutForTesting {
    if(!self.hardwareLayout) return NO;
    [self layoutIfNeeded];
    auto visible=[&](int scan)->PC98KeyButton* {
        for(NSArray* row in self.keys) for(PC98KeyButton* key in row) if(key.tag==scan && !key.hidden) return key;
        return nil;
    };
    PC98KeyButton* enter=visible(28); PC98KeyButton* vf=visible(0x52); PC98KeyButton* f10=visible(0x6B);
    PC98KeyButton* seven=visible(0x42); PC98KeyButton* insert=visible(0x38); PC98KeyButton* space=visible(0x34);
    if(!enter || !vf || !f10 || !seven || !insert || !space || !enter.steppedReturn) return NO;
    if(!(CGRectGetMinX(seven.frame)>CGRectGetMaxX(insert.frame) && CGRectGetMinX(vf.frame)>CGRectGetMaxX(f10.frame) && space.frame.size.width>seven.frame.size.width*6)) return NO;
    NSUInteger visibleCount=0;
    for(NSArray* row in self.keys) for(UIButton* key in row) if(!key.hidden) {
        ++visibleCount;
        if([self keyAtPoint:CGPointMake(CGRectGetMidX(key.frame),CGRectGetMidY(key.frame))]!=key) return NO;
    }
    if(visibleCount!=hardwareKeys().size()) return NO;
    CGRect fitted=[self hardwareFrame];
    if(fitted.size.width<self.bounds.size.width*.9 || !CGRectContainsRect(self.bounds,fitted) || seven.frame.size.height>seven.frame.size.width*1.65) return NO;
    PC98KeyButton* a=visible(29); PC98KeyButton* s=visible(30);
    CGPoint gap=CGPointMake(CGRectGetMaxX(a.frame)+(CGRectGetMinX(s.frame)-CGRectGetMaxX(a.frame))*.25,CGRectGetMidY(a.frame));
    if([self keyAtPoint:gap]!=a) return NO;
    // The empty lower-left notch must not trigger Return.
    CGPoint notch=CGPointMake(enter.frame.origin.x+enter.frame.size.width*.08,enter.frame.origin.y+enter.frame.size.height*.75);
    return [self keyAtPoint:notch]!=enter && [self tapReturnSectionsForTesting];
}
- (BOOL)tapScanForTesting:(int)scan {
    for(NSArray* row in self.keys) for(UIButton* b in row) if(b.tag==scan && !b.hidden) return [b accessibilityActivate];
    return NO;
}
#endif
- (void)releaseAll {
    std::set<int> down=latched; for(auto pair:counts) if(pair.second) down.insert(pair.first);
    for(int scan:down) if(self.keyChanged) self.keyChanged(scan,NO);
    touches.clear(); counts.clear(); latched.clear(); repeatAt.clear();
    for(NSArray* row in self.keys) for(PC98KeyButton* b in row) b.retroPressed=NO;
    [self setNeedsDisplay];
}
@end
int pc98_scan_from_hid(NSInteger u) {
    static const int letters[]={29,45,43,31,18,32,33,34,23,35,36,37,47,46,24,25,16,19,30,20,22,44,17,42,21,41};
    if(u>=4 && u<=29) return letters[u-4];
    if(u>=30 && u<=38) return (int)u-29;
    if(u==39) return 10;
    if(u>=58 && u<=67) return 0x62+(int)u-58;
    switch(u) {
        case 40:case 88:return 28; case 41:return 0; case 42:return 14; case 43:return 15;
        case 44:return 0x34; case 45:return 11; case 46:return 12; case 47:return 26; case 48:return 27;
        case 49:return 40; case 51:return 38; case 52:return 39; case 54:return 48; case 55:return 49; case 56:return 50;
        case 57:return 0x71; case 70:return 0x61; case 72:return 0x60;
        case 73:return 0x38; case 74:return 0x3E; case 75:return 0x37; case 76:return 0x39; case 77:return 0x3F; case 78:return 0x36;
        case 79:return 0x3C; case 80:return 0x3B; case 81:return 0x3D; case 82:return 0x3A;
        case 84:return 0x41; case 85:return 0x45; case 86:return 0x40; case 87:return 0x49;
        case 89:return 0x4A; case 90:return 0x4B; case 91:return 0x4C; case 92:return 0x46; case 93:return 0x47; case 94:return 0x48;
        case 95:return 0x42; case 96:return 0x43; case 97:return 0x44; case 98:return 0x4E; case 99:return 0x50;
        case 135:return 0x33; case 137:return 13; case 138:return 0x35; case 139:return 0x51;
        case 144:return 0x72; case 145:return 0x51;
        case 224:case 228:return 0x74; case 225:case 229:return 0x70; case 226:case 230:return 0x73;
        default:return -1;
    }
}
