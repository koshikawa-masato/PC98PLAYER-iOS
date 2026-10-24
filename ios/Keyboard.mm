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
    {{"STOP",0x60},{"COPY",0x61},{"F1",0x62},{"F2",0x63},{"F3",0x64},{"F4",0x65},{"F5",0x66},{"F6",0x67},{"F7",0x68},{"F8",0x69},{"F9",0x6A},{"F10",0x6B},{"VF1",0x52},{"VF2",0x53},{"VF3",0x54},{"VF4",0x55},{"VF5",0x56}},
    {{"ESC",0},{"1",1},{"2",2},{"3",3},{"4",4},{"5",5},{"6",6},{"7",7},{"8",8},{"9",9},{"0",10},{"-",11},{"^",12},{"¥",13},{"BS",14,1.4}},
    {{"TAB",15,1.4},{"Q",16},{"W",17},{"E",18},{"R",19},{"T",20},{"Y",21},{"U",22},{"I",23},{"O",24},{"P",25},{"@",26},{"[",27},{"↵",28,1.4}},
    {{"CTRL",0x74,1.4},{"A",29},{"S",30},{"D",31},{"F",32},{"G",33},{"H",34},{"J",35},{"K",36},{"L",37},{";",38},{":",39},{"]",40},{"↵",28,1.4}},
    {{"SHIFT",0x70,1.8},{"Z",41},{"X",42},{"C",43},{"V",44},{"B",45},{"N",46},{"M",47},{",",48},{".",49},{"/",50},{"_",51},{"SHIFT",0x70,1.8}},
    {{"CAPS",0x71},{"かな",0x72},{"GRPH",0x73},{"NFER",0x51},{"SPACE",0x34,4},{"XFER",0x35},{"↑",0x3A},{"←",0x3B},{"↓",0x3D},{"→",0x3C}},
    {{"HELP",0x3F},{"HOME",0x3E},{"INS",0x38},{"DEL",0x39},{"R↓",0x37},{"R↑",0x36},{"7",0x42},{"8",0x43},{"9",0x44},{"/",0x41},{"*",0x45},{"-",0x40}},
    {{"4",0x46},{"5",0x47},{"6",0x48},{"+",0x49},{"1",0x4A},{"2",0x4B},{"3",0x4C},{"=",0x4D},{"0",0x4E},{",",0x4F},{".",0x50},{"↵",28}}
};
@interface PC98KeyButton : UIButton
@property(copy) BOOL (^activate)(void);
@property BOOL retroPressed;
@property BOOL modifier;
@property NSString* kana;
@end
@implementation PC98KeyButton
- (BOOL)accessibilityActivate { return self.activate ? self.activate() : NO; }
- (void)setRetroPressed:(BOOL)value { _retroPressed=value; [self setNeedsDisplay]; [self setNeedsLayout]; }
- (CGRect)titleRectForContentRect:(CGRect)contentRect {
    CGFloat inset=self.bounds.size.width<24 ? 2 : 4;
    return CGRectMake(inset,self.retroPressed?4:2,MAX(1,self.bounds.size.width-inset*2),self.bounds.size.height*(self.kana.length?.56:.85));
}
- (void)layoutSubviews {
    self.titleLabel.font=[UIFont monospacedSystemFontOfSize:MAX(7,MIN(13,self.bounds.size.width*.36)) weight:UIFontWeightMedium];
    [super layoutSubviews];
}
- (void)drawRect:(CGRect)rect {
    CGRect r=CGRectInset(self.bounds,.5,.5);
    [[UIColor colorWithWhite:.20 alpha:1] setFill]; [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:3] fill];
    CGRect base=CGRectInset(r,1,1);
    PC98Gradient(base,PC98Plastic(.76),PC98Plastic(.48),2.5);
    CGRect face=CGRectMake(2,self.retroPressed?4:1.5,MAX(1,r.size.width-3),MAX(1,r.size.height-(self.retroPressed?5:6)));
    CGFloat tone=self.modifier?.75:.95;
    if(self.retroPressed) tone-=.13;
    PC98Gradient(face,PC98Plastic(tone),PC98Plastic(tone-.10),2);
    [PC98Plastic(MIN(1,tone+.08)) setStroke];
    UIBezierPath* edge=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(face,.5,.5) cornerRadius:1.5]; edge.lineWidth=.6; [edge stroke];
    if(self.kana.length) {
        CGFloat size=MAX(6,MIN(10,self.bounds.size.width*.30));
        NSDictionary* style=@{NSFontAttributeName:[UIFont systemFontOfSize:size],NSForegroundColorAttributeName:[UIColor colorWithWhite:.30 alpha:1]};
        CGSize label=[self.kana sizeWithAttributes:style];
        [self.kana drawAtPoint:CGPointMake(CGRectGetMaxX(face)-label.width-2,CGRectGetMaxY(face)-label.height-1) withAttributes:style];
    }
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
                PC98KeyButton* b=[PC98KeyButton buttonWithType:UIButtonTypeCustom]; b.tag=k.scan;
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
- (void)drawRect:(CGRect)rect {
    CGRect shell=CGRectInset(self.bounds,.5,.5);
    PC98Gradient(shell,PC98Plastic(.91),PC98Plastic(.69),10);
    [PC98Plastic(.97) setStroke]; UIBezierPath* edge=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(shell,1,1) cornerRadius:9]; edge.lineWidth=1; [edge stroke];
    // Blank recessed nameplate and indicator lamps; no manufacturer mark.
    PC98Gradient(CGRectMake(12,8,MAX(1,self.bounds.size.width*.58),14),PC98Plastic(.75),PC98Plastic(.87),1);
    for(int i=0;i<3;++i) {
        CGFloat x=self.bounds.size.width-54+i*15;
        [PC98Plastic(.41) setFill]; UIRectFill(CGRectMake(x,12,5,3));
        if(latched.count(0x71+i)) { [[UIColor colorWithRed:.64 green:.76 blue:.30 alpha:1] setFill]; UIRectFill(CGRectMake(x+1,12,3,2)); }
    }
    CGRect well=CGRectMake(8,28,self.bounds.size.width-16,self.bounds.size.height-38);
    PC98Gradient(well,PC98Plastic(.37),PC98Plastic(.54),3);
    // Separate the function keys and the auxiliary/numeric bank with case ribs.
    CGFloat content=well.size.height-8, rowHeight=content/8.0;
    [PC98Plastic(.73) setFill]; UIRectFill(CGRectMake(8,well.origin.y+rowHeight-1,well.size.width,4));
    UIRectFill(CGRectMake(8,well.origin.y+rowHeight*6-1,well.size.width,4));
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat gap=3, left=10, top=30, usable=self.bounds.size.width-20;
    CGFloat h=(self.bounds.size.height-top-12-gap*(rows.size()-1))/rows.size();
    for(size_t r=0;r<rows.size();++r) {
        float units=0; for(auto k:rows[r]) units+=k.width;
        CGFloat unit=(usable-gap*(rows[r].size()-1))/units, x=left;
        for(size_t c=0;c<rows[r].size();++c) {
            CGFloat w=unit*rows[r][c].width;
            self.keys[r][c].frame=CGRectMake(x,top+r*(h+gap),w,MAX(1,h)); x+=w+gap;
        }
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
- (void)touchesBegan:(NSSet<UITouch*>*)set withEvent:(UIEvent*)event {
    for(UITouch* t in set) for(NSArray* row in self.keys) for(UIButton* b in row)
        if(CGRectContainsPoint(b.frame,[t locationInView:self])) { touches[t]=b; [self updateKey:b down:YES]; }
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
- (BOOL)tapScanForTesting:(int)scan {
    for(NSArray* row in self.keys) for(UIButton* b in row) if(b.tag==scan) return [b accessibilityActivate];
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
