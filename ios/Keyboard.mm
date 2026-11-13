// SPDX-License-Identifier: MIT
#import "Keyboard.h"
#import "RetroHardware.h"
#include <map>
#include <vector>
#include <algorithm>
#include <cmath>

#include <set>
#import <QuartzCore/QuartzCore.h>
static constexpr int controllerDefaultScans[]={0x3A,0x3B,0x3C,0x3D,0x34,28};
struct Key { const char* name; int scan; float width=1; };
static const std::vector<std::vector<Key>> rows = {
    {{"VF1",0x52},{"VF2",0x53},{"VF3",0x54},{"VF4",0x55},{"VF5",0x56}},
    {{"STOP",0x60},{"COPY",0x61},{"F1",0x62},{"F2",0x63},{"F3",0x64},{"F4",0x65},{"F5",0x66},{"F6",0x67},{"F7",0x68},{"F8",0x69},{"F9",0x6A},{"F10",0x6B}},
    {{"ESC",0},{"1",1},{"2",2},{"3",3},{"4",4},{"5",5},{"6",6},{"7",7},{"8",8},{"9",9},{"0",10},{"-",11},{"^",12},{"¥",13},{"BS",14,1.4}},
    {{"TAB",15,1.4},{"Q",16},{"W",17},{"E",18},{"R",19},{"T",20},{"Y",21},{"U",22},{"I",23},{"O",24},{"P",25},{"@",26},{"[",27},{"↵",28,1.4}},
    {{"CTRL",0x74,1.4},{"A",29},{"S",30},{"D",31},{"F",32},{"G",33},{"H",34},{"J",35},{"K",36},{"L",37},{";",38},{":",39},{"]",40},{"↵",28,1.4}},
    {{"SHIFT",0x70,1.8},{"Z",41},{"X",42},{"C",43},{"V",44},{"B",45},{"N",46},{"M",47},{",",48},{".",49},{"/",50},{"_",51},{"SHIFT",0x70,1.8}},
    {{"CAPS",0x71},{"かな",0x72},{"GRPH",0x73},{"NFER",0x51},{"SPACE",0x34,4},{"XFER",0x35},{"←",0x3B},{"↑",0x3A},{"↓",0x3D},{"→",0x3C}},
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
@property(nonatomic) BOOL retroCandidate;   // 保留中（指は触れているが、まだ入力になっていない）
@property BOOL modifier;
@property BOOL steppedReturn;
@property BOOL alignedLegend;
@property CGFloat detailScale;
@property BOOL expandedLegends;
@property BOOL outlinesOnly;
@property NSString* kana;
@end
@implementation PC98KeyButton
- (BOOL)accessibilityActivate { return self.activate ? self.activate() : NO; }
- (void)setRetroPressed:(BOOL)value {
    if(_retroPressed==value) return;
    _retroPressed=value;
    [self setNeedsDisplay];
}
- (void)setRetroCandidate:(BOOL)value {
    if(_retroCandidate==value) return;
    _retroCandidate=value;
    [self setNeedsDisplay];
}
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
    if(self.alignedLegend) {
        CGRect legend=self.bounds;
        if(self.steppedReturn) {
            CGFloat notch=CGRectGetWidth(legend)*12/56;
            legend.origin.x+=notch;
            legend.size.width-=notch;
        }
        return CGRectInset(legend,2*self.detailScale,0);
    }
    CGFloat inset=(self.bounds.size.width<24 ? 2 : 4)*self.detailScale;
    return CGRectMake(inset,2*self.detailScale,MAX(1,self.bounds.size.width-inset*2),self.bounds.size.height*(self.kana.length?.56:.85));
}
- (void)layoutSubviews {
    CGFloat size=self.expandedLegends ? MAX(5,MIN(16,MIN(self.bounds.size.width*.58,self.bounds.size.height*.34))) : MAX(3,MIN(13*self.detailScale,MIN(self.bounds.size.width*.36,self.bounds.size.height*.32)));
    self.titleLabel.font=[UIFont monospacedSystemFontOfSize:size weight:UIFontWeightMedium];
    [super layoutSubviews];
    if(self.alignedLegend) {
        self.titleLabel.textAlignment=self.tag==0x3C ? NSTextAlignmentRight : NSTextAlignmentCenter;
        self.titleLabel.frame=[self titleRectForContentRect:self.bounds];
    }
}
- (void)drawRect:(CGRect)rect {
    CGFloat detail=self.detailScale;
    CGRect r=CGRectInset(self.bounds,.5*detail,.5*detail);
    if(self.outlinesOnly) {
        UIBezierPath* outline=[self capPath:r];
        [[UIColor colorWithWhite:0 alpha:.7] setStroke];
        outline.lineWidth=3;
        [outline stroke];
        if(self.retroCandidate && !self.retroPressed) [[UIColor colorWithRed:1 green:.80 blue:.35 alpha:1] setStroke];
        else [[UIColor colorWithWhite:1 alpha:self.retroPressed?1:.65] setStroke];
        outline.lineWidth=(self.retroPressed || self.retroCandidate)?2:1;
        [outline stroke];
        return;
    }
    [[UIColor colorWithWhite:.20 alpha:1] setFill]; [[self capPath:r] fill];
    CGContextRef context=UIGraphicsGetCurrentContext(); CGContextSaveGState(context);
    [[self capPath:r] addClip];
    CGRect base=CGRectInset(r,detail,detail);
    PC98Gradient(base,PC98Plastic(.76),PC98Plastic(.48),2.5*detail);
    CGRect face=CGRectMake(2*detail,(self.retroPressed?4:1.5)*detail,MAX(1,r.size.width-3*detail),MAX(1,r.size.height-(self.retroPressed?5:6)*detail));
    CGFloat tone=self.modifier?.75:.95;
    if(self.retroPressed) tone-=.13;
    else if(self.retroCandidate) tone=MIN(1,tone+.06);
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
    if(self.retroCandidate && !self.retroPressed) {
        [[UIColor colorWithRed:1 green:.80 blue:.35 alpha:1] setStroke];
        UIBezierPath* rim=[self capPath:CGRectInset(r,1.2*detail,1.2*detail)]; rim.lineWidth=1.6*detail; [rim stroke];
    }
    if(self.retroPressed && self.tag>=0x70 && self.tag<=0x74) {
        [[UIColor colorWithRed:.55 green:.29 blue:.08 alpha:1] setFill];
        UIRectFill(CGRectMake(CGRectGetMaxX(face)-5,CGRectGetMinY(face)+2,3,2));
    }
}
@end
@interface PC98Keyboard () <UIGestureRecognizerDelegate> {
    std::map<UITouch*,UIButton*> touches;
    std::map<int,int> counts;
    std::set<int> latched;
    std::set<int> modifierChords;
    std::map<int,double> repeatAt;
    __weak UITouch* stickTouch;
    CGRect stickFrame;
    CGRect actionChordFrame;
    std::map<UITouch*,unsigned> actionTouches;
    // 切替スワイプ候補の保留：何も押されていない状態から着地した指は、スワイプ確定・
    // タップ終了・短時間経過のいずれかまでキー／ボタン／スティックとして発火しない。
    struct PendingTouch { CGPoint start; };
    std::map<UITouch*,PendingTouch> pendingTouches;
    unsigned stickDirections;
    CGFloat panelSwipeDirection;     // 三本指切替スワイプの向き（+1=右=次のモード、-1=左=前のモード）
    CGRect touchpadFrame;            // タッチパッド面
    __weak UITouch* touchpadTouch;   // パッド面を操作中のタッチ（1本のみ）
    CGPoint touchpadTouchStart, touchpadTouchLast;
    NSTimeInterval touchpadTouchTime;
    BOOL touchpadTouchTravelled;     // タップの許容量を超えて動いた（＝タップではなく移動）
    BOOL touchpadTapCancelled;       // 2本目以降の指が触れた（＝マルチタッチ操作の始まり）のでタップにしない
}
@property(strong) NSArray<NSArray<UIButton*>*>* keys;
@property(strong) UIImpactFeedbackGenerator* keyFeedback;
@property(strong) NSArray<PC98KeyButton*>* controllerKeys;
@property(copy) NSString* controllerBindingsKey;
@property(copy) NSArray<NSNumber*>* controllerBindings;
@property(strong) UIButton* controllerSettings;
@property(strong) UIButton* controllerPause;
@property(strong) UIView* stickKnob;
@property(strong) NSArray<UIButton*>* touchpadButtons;   // [0]=左クリック、[1]=右クリック
@property BOOL controllerMode;
// 入力モードは キーボード（両方NO）／ゲームパッド（controllerMode）／タッチパッド（touchpadMode）の3値
@property(nonatomic) BOOL touchpadMode;
@property BOOL switchingInputMode;
@end
@implementation PC98Keyboard
@synthesize controllerMode=_controllerMode;
@synthesize touchpadMode=_touchpadMode;

- (BOOL)controllerMode { return _controllerMode || self.outlinesOnly; }
// 全画面（outlinesOnly）中は従来どおりコントローラーの枠表示を使い、タッチパッドは通常表示に戻ったとき復帰する
- (BOOL)touchpadMode { return _touchpadMode && !self.outlinesOnly; }
- (NSInteger)inputModeIndex { return _touchpadMode ? 2 : _controllerMode ? 1 : 0; }
// 三本指で右スワイプ＝次のモード（+1）、左スワイプ＝前のモード（-1）。両端では止まる
- (void)stepInputMode:(NSInteger)step {
    NSInteger mode=std::clamp<NSInteger>([self inputModeIndex]+step,0,2);
    self.controllerMode=mode==1;
    self.touchpadMode=mode==2;
    if(mode==1 && !self.controllerKeys) [self buildController];
    if(mode==2 && !self.touchpadButtons) [self buildTouchpad];
}
- (void)setTouchpadTopInset:(CGFloat)value {
    if(_touchpadTopInset==value) return;
    _touchpadTopInset=value;
    [self setNeedsLayout];
    [self setNeedsDisplay];
}
- (void)setControllerTopInset:(CGFloat)value {
    if(_controllerTopInset==value) return;
    _controllerTopInset=value;
    [self setNeedsLayout];
}
- (void)setLandscapeEdgeControls:(BOOL)value {
    if(_landscapeEdgeControls==value) return;
    _landscapeEdgeControls=value;
    [self setNeedsLayout];
}
- (void)setOutlinesOnly:(BOOL)value {
    if(_outlinesOnly==value) return;
    if(value && !self.controllerKeys) [self buildController];
    _outlinesOnly=value;
    self.layer.shadowOpacity=value?0:.3;
    self.controllerPause.backgroundColor=value?UIColor.clearColor:PC98Plastic(.96);
    self.controllerPause.layer.borderWidth=value?1:0;
    self.controllerPause.layer.borderColor=[UIColor colorWithWhite:1 alpha:.65].CGColor;
    [self.controllerPause setTitleColor:value?UIColor.whiteColor:nil forState:UIControlStateNormal];
    self.stickKnob.backgroundColor=value?UIColor.clearColor:PC98Plastic(.55);
    self.stickKnob.layer.borderColor=(value?[UIColor colorWithWhite:1 alpha:.65]:PC98Plastic(.40)).CGColor;
    for(PC98KeyButton* key in self.controllerKeys) {
        key.outlinesOnly=value;
        key.titleLabel.alpha=value?0:1;
        [key setNeedsDisplay];
    }
    [self setNeedsLayout];
    [self setNeedsDisplay];
}
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.multipleTouchEnabled=YES; self.backgroundColor=UIColor.clearColor; self.opaque=NO; self.contentMode=UIViewContentModeRedraw;
        self.layer.shadowColor=UIColor.blackColor.CGColor; self.layer.shadowOffset=CGSizeMake(0,5); self.layer.shadowOpacity=.3; self.layer.shadowRadius=6;
        NSMutableArray* groups=[NSMutableArray new];
        for(const auto& row:rows) {
            NSMutableArray* group=[NSMutableArray new];
            for(const auto& k:row) {
                PC98KeyButton* b=[PC98KeyButton buttonWithType:UIButtonTypeCustom]; b.tag=k.scan; b.detailScale=1;
                b.alignedLegend=k.scan==28 || k.scan==0x3A || k.scan==0x3C || k.scan==0x3D;
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
        UIPanGestureRecognizer* swipe=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(swipeInputPanel:)];
        swipe.delegate=self;
        // 一本指はタイピング・パッド操作、二本指は右クリック等に使うため、モード切替は三本指スワイプのみ
        swipe.minimumNumberOfTouches=3;
        swipe.maximumNumberOfTouches=3;
        [self addGestureRecognizer:swipe];
    }
    return self;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    UIPanGestureRecognizer* swipe=(UIPanGestureRecognizer*)gesture;
    // 複数指では重心が指の追加でずれるため、原点ではなく認識器の移動量（translation）で判定する
    CGPoint movement=[swipe translationInView:self.superview];
    if(CGPointEqualToPoint(movement,CGPointZero)) movement=[swipe velocityInView:self.superview];
    // 全モードで左右どちらも受け付ける（右＝次、左＝前）。端では stepInputMode: のクランプで止まる
    panelSwipeDirection=movement.x<0 ? -1 : 1;
    return !self.outlinesOnly && !self.switchingInputMode && std::abs(movement.x)>=std::abs(movement.y)*1.4;
}
- (void)applySwipeSlide:(CGAffineTransform)slide {
    self.transform=slide;
    // ゲーム画面もパネルと同じ量だけスライドさせ、画面全体で切り替わる見た目にする
    self.swipeCompanionView.transform=slide;
}
- (void)swipeInputPanel:(UIPanGestureRecognizer*)gesture {
    // スワイプが始まったら保留中の指は入力にしない。認識に失敗したら通常入力として確定する
    if(gesture.state==UIGestureRecognizerStateBegan) [self discardPendingTouches];
    if(gesture.state==UIGestureRecognizerStateFailed) [self commitPendingTouches];
    CGFloat direction=panelSwipeDirection;
    CGFloat distance=MIN(64,self.bounds.size.width*.18);
    CGFloat drag=MAX(0,[gesture translationInView:self.superview].x*direction);
    BOOL reduceMotion=UIAccessibilityIsReduceMotionEnabled();
    if(gesture.state==UIGestureRecognizerStateBegan) [self releaseAll];
    if(gesture.state==UIGestureRecognizerStateBegan || gesture.state==UIGestureRecognizerStateChanged) {
        // スワイプが始まった瞬間からパネルが指に 1:1 で追従してスクロールする
        if(!reduceMotion) [self applySwipeSlide:CGAffineTransformMakeTranslation(direction*MIN(drag,self.bounds.size.width*.45),0)];
        return;
    }

    CGFloat velocity=[gesture velocityInView:self.superview].x*direction;
    BOOL change=gesture.state==UIGestureRecognizerStateEnded &&
                (drag>=MIN(70,self.bounds.size.width*.22) || (drag>=20 && velocity>450));
    if(!change) {
        [UIView animateWithDuration:reduceMotion ? 0 : .18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            [self applySwipeSlide:CGAffineTransformIdentity];
        } completion:nil];
        return;
    }

    self.switchingInputMode=YES;
    CGFloat exitOffset=MAX(distance,MIN(drag,self.bounds.size.width*.45));
    [UIView animateWithDuration:reduceMotion ? 0 : .10 animations:^{
        if(!reduceMotion) {
            [self applySwipeSlide:CGAffineTransformMakeTranslation(direction*exitOffset,0)];
        }
    } completion:^(BOOL finished) {
        if(self.outlinesOnly) {
            [self applySwipeSlide:CGAffineTransformIdentity];
            self.switchingInputMode=NO;
            return;
        }
        [self releaseAll];
        [self stepInputMode:direction>0 ? 1 : -1];
        [self setNeedsLayout];
        [self layoutIfNeeded];
        [self setNeedsDisplay];
        // Keep the slide on the same side of the resting position, avoiding
        // a full-panel fade and the intermediate offscreen composition.
        [self applySwipeSlide:reduceMotion ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(direction*distance,0)];
        [UIView animateWithDuration:reduceMotion ? 0 : .18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            [self applySwipeSlide:CGAffineTransformIdentity];
        } completion:^(BOOL completed) {
            self.switchingInputMode=NO;
        }];
    }];
}
- (void)buildController {
    NSArray* labels=@[@"↑",@"←",@"→",@"↓",@"A",@"B"];
    NSMutableArray* buttons=[NSMutableArray new];
    for(NSUInteger i=0;i<labels.count;++i) {
        PC98KeyButton* key=[PC98KeyButton buttonWithType:UIButtonTypeCustom];
        key.tag=self.controllerBindings ? self.controllerBindings[i].intValue : controllerDefaultScans[i];
        key.detailScale=1;
        key.expandedLegends=YES;
        key.titleLabel.textAlignment=NSTextAlignmentCenter;
        key.userInteractionEnabled=NO;
        key.accessibilityLabel=labels[i];
        [key setTitle:labels[i] forState:UIControlStateNormal];
        [key setTitleColor:PC98Plastic(.20) forState:UIControlStateNormal];
        __weak PC98Keyboard* weak=self;
        __weak PC98KeyButton* weakKey=key;
        key.activate=^BOOL {
            PC98Keyboard* keyboard=weak;
            PC98KeyButton* button=weakKey;
            if(!keyboard || !button) return NO;
            [keyboard updateKey:button down:YES];
            [keyboard updateKey:button down:NO];
            return YES;
        };
        [self addSubview:key];
        [buttons addObject:key];
    }
    self.controllerKeys=buttons;
    self.stickKnob=[UIView new];
    self.stickKnob.userInteractionEnabled=NO;
    self.stickKnob.backgroundColor=PC98Plastic(.55);
    self.stickKnob.layer.borderWidth=2;
    self.stickKnob.layer.borderColor=PC98Plastic(.40).CGColor;
    [self addSubview:self.stickKnob];

    self.controllerPause=[UIButton buttonWithType:UIButtonTypeSystem];
    self.controllerPause.backgroundColor=PC98Plastic(.96);
    self.controllerPause.layer.cornerRadius=6;
    self.controllerPause.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [self.controllerPause addTarget:self action:@selector(tapControllerPause) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.controllerPause];
    [self updateControllerPause:NO enabled:NO];
    self.controllerSettings=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.controllerSettings setTitle:@"キー設定" forState:UIControlStateNormal];
    self.controllerSettings.backgroundColor=PC98Plastic(.96);
    self.controllerSettings.layer.cornerRadius=6;
    self.controllerSettings.showsMenuAsPrimaryAction=YES;
    [self.controllerSettings addTarget:self action:@selector(openControllerSettings) forControlEvents:UIControlEventMenuActionTriggered];
    [self addSubview:self.controllerSettings];
    [self updateControllerMenu];
}
- (void)buildTouchpad {
    // パッド面はパネル自身が描画・タッチ処理し、クリックボタンだけ実ボタンにする（ポーズボタンと同じ扱い）
    NSArray<NSString*>* titles=@[@"左クリック",@"右クリック"];
    NSMutableArray<UIButton*>* buttons=[NSMutableArray new];
    for(NSUInteger i=0;i<titles.count;++i) {
        UIButton* button=[UIButton buttonWithType:UIButtonTypeSystem];
        button.tag=(NSInteger)i+1;   // マウスボタン番号（1=左、2=右）
        [button setTitle:titles[i] forState:UIControlStateNormal];
        [button setTitleColor:PC98Plastic(.20) forState:UIControlStateNormal];
        button.titleLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        button.backgroundColor=PC98Plastic(.96);
        button.layer.cornerRadius=6;
        button.layer.borderWidth=1;
        button.layer.borderColor=PC98Plastic(.55).CGColor;
        [button addTarget:self action:@selector(tapTouchpadButton:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:button];
        [buttons addObject:button];
    }
    self.touchpadButtons=buttons;
}
- (void)tapTouchpadButton:(UIButton*)sender {
    if(self.mouseClicked) self.mouseClicked((int)sender.tag);
}
- (CGFloat)touchpadHeaderBottom {
    // 上端の帯はモード表示に使う（三本指の切替スワイプはパッド面の上からでも可能）
    return self.touchpadTopInset+MAX(1,MIN(28,self.bounds.size.height*.12));
}
- (void)layoutTouchpad {
    CGFloat width=self.bounds.size.width, height=self.bounds.size.height, margin=8;
    CGFloat top=[self touchpadHeaderBottom];
    CGFloat buttonHeight=MAX(1,MIN(52,height*.2));
    CGFloat buttonY=height-margin-buttonHeight;
    touchpadFrame=CGRectMake(margin,top,MAX(1,width-margin*2),MAX(1,buttonY-margin-top));
    CGFloat buttonWidth=MAX(1,(width-margin*3)/2);
    self.touchpadButtons[0].frame=CGRectMake(margin,buttonY,buttonWidth,buttonHeight);
    self.touchpadButtons[1].frame=CGRectMake(margin*2+buttonWidth,buttonY,buttonWidth,buttonHeight);
}
- (void)drawTouchpad {
    PC98Gradient(CGRectInset(self.bounds,1,1),PC98Plastic(.91),PC98Plastic(.69),10);
    PC98Gradient(touchpadFrame,PC98Plastic(.42),PC98Plastic(.58),8);
    NSMutableParagraphStyle* centered=[NSMutableParagraphStyle new];
    centered.alignment=NSTextAlignmentCenter;
    CGFloat headerTop=self.touchpadTopInset, headerHeight=[self touchpadHeaderBottom]-headerTop;
    NSDictionary* header=@{NSFontAttributeName:[UIFont systemFontOfSize:MAX(6,MIN(11,headerHeight*.45)) weight:UIFontWeightMedium],
        NSForegroundColorAttributeName:PC98Plastic(.30),NSParagraphStyleAttributeName:centered};
    [@"タッチパッド　◀ 三本指スワイプで切替" drawInRect:CGRectMake(0,headerTop+headerHeight*.25,self.bounds.size.width,headerHeight*.75) withAttributes:header];
    NSDictionary* hint=@{NSFontAttributeName:[UIFont systemFontOfSize:11],
        NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:.45],NSParagraphStyleAttributeName:centered};
    [@"ドラッグでカーソル移動・タップで左クリック" drawInRect:CGRectMake(touchpadFrame.origin.x,CGRectGetMidY(touchpadFrame)-7,touchpadFrame.size.width,16) withAttributes:hint];
}
- (void)moveTouchpadTouch:(UITouch*)touch {
    CGPoint point=[touch locationInView:self];
    if(!touchpadTouchTravelled) {
        // タップ判定中の小さなぶれではカーソルを動かさない。超えたら開始点からの移動量をまとめて送る
        if(std::hypot(point.x-touchpadTouchStart.x,point.y-touchpadTouchStart.y)<8) return;
        touchpadTouchTravelled=YES;
        touchpadTouchLast=touchpadTouchStart;
    }
    CGPoint delta=CGPointMake(point.x-touchpadTouchLast.x,point.y-touchpadTouchLast.y);
    touchpadTouchLast=point;
    if(self.mouseMoved) self.mouseMoved(delta);
}
- (void)openControllerSettings {
    if(self.controllerSettingsOpening) self.controllerSettingsOpening();
}
- (void)tapControllerPause {
    if(self.pauseChanged) self.pauseChanged();
}
- (void)updateControllerPause:(BOOL)paused enabled:(BOOL)enabled {
    if(!self.controllerPause) return;
    self.controllerPause.accessibilityLabel=paused?@"再開":@"一時停止";
    NSString* title=self.outlinesOnly ? (paused?@"▶":@"Ⅱ") : (paused?@"▶ 再開":@"Ⅱ ポーズ");
    if(![self.controllerPause.currentTitle isEqualToString:title])
        [self.controllerPause setTitle:title forState:UIControlStateNormal];
    self.controllerPause.enabled=enabled;
}
- (void)loadControllerBindingsForGame:(NSString*)identifier {
    NSUserDefaults* defaults=NSUserDefaults.standardUserDefaults;
    self.controllerBindingsKey=[@"PC98ControllerBindings." stringByAppendingString:identifier];
    self.controllerBindings=pc98_controller_bindings([defaults arrayForKey:self.controllerBindingsKey]
        ?: [defaults arrayForKey:@"PC98TouchControllerBindings"]);
    [self applyControllerBindings];
}
- (void)applyControllerBindings {
    for(NSUInteger i=0;i<self.controllerKeys.count;++i)
        self.controllerKeys[i].tag=self.controllerBindings[i].intValue;
    [self updateControllerMenu];
}
- (void)updateControllerMenu {
    if(!self.controllerSettings) return;
    NSMutableArray<NSString*>* names=[NSMutableArray new];
    __weak PC98Keyboard* weak=self;
    self.controllerSettings.menu=pc98_controller_binding_menu(pc98_controller_bindings(self.controllerBindings),names,^(NSArray<NSNumber*>* bindings) {
        PC98Keyboard* keyboard=weak;
        if(!keyboard) return;
        [keyboard releaseAll];
        keyboard.controllerBindings=bindings;
        [NSUserDefaults.standardUserDefaults setObject:bindings forKey:keyboard.controllerBindingsKey ?: @"PC98TouchControllerBindings"];
        [keyboard applyControllerBindings];
    });
    for(NSUInteger i=0;i<self.controllerKeys.count;++i)
        self.controllerKeys[i].accessibilityValue=names[i];
}
- (void)layoutController {
    CGFloat width=self.bounds.size.width, height=self.bounds.size.height;
    CGFloat controlsTop=self.landscapeEdgeControls ? 44 : 0;
    CGFloat unit=MAX(1,MIN(74,MIN((height-controlsTop-12)/3,(width-30)/6)));
    CGFloat left=self.landscapeEdgeControls ? 6 : MAX(6,(width*.28-1.5*unit));
    CGFloat top=controlsTop+(height-controlsTop-3*unit)/2;
    stickFrame=CGRectMake(left,top,3*unit,3*unit);
    CGFloat knob=unit*.63;
    self.stickKnob.bounds=CGRectMake(0,0,knob,knob);
    self.stickKnob.layer.cornerRadius=knob/2;
    self.stickKnob.center=CGPointMake(CGRectGetMidX(stickFrame),CGRectGetMidY(stickFrame));
    const int cols[]={1,0,2,1}, lines[]={0,1,1,2};
    for(int i=0;i<4;++i)
        self.controllerKeys[i].frame=CGRectInset(CGRectMake(left+cols[i]*unit,top+lines[i]*unit,unit,unit),2,2);
    CGFloat right=width-(self.landscapeEdgeControls ? 6 : MAX(8,width*.09));
    self.controllerKeys[4].frame=CGRectInset(CGRectMake(right-2*unit,top+1.5*unit,unit,unit),2,2);
    self.controllerKeys[5].frame=CGRectInset(CGRectMake(right-unit,top+.8*unit,unit,unit),2,2);
    CGRect a=self.controllerKeys[4].frame, b=self.controllerKeys[5].frame;
    CGFloat chordX=(CGRectGetMidX(a)+CGRectGetMidX(b))/2;
    CGFloat chordY=(CGRectGetMidY(a)+CGRectGetMidY(b))/2;
    actionChordFrame=CGRectMake(chordX-.34*unit,chordY-.30*unit,.68*unit,.60*unit);
    CGFloat toolbarButtonWidth=MAX(1,MIN(82,(width-22)/2));
    // ツールバーと状態表示がパネル上端に重なる配置では、その帯の下にポーズ／キー設定を置く（タッチパッドと同じ扱い）。
    // 全画面の輪郭表示ではツールバー自体が無いので従来どおり上端に置く。
    CGFloat buttonsTop=self.outlinesOnly ? 5 : 5+self.controllerTopInset;
    CGFloat toolbarButtonHeight=MAX(1,MIN(38,top+.8*unit-3-buttonsTop));
    CGFloat settingsX=width-8-toolbarButtonWidth;
    self.controllerSettings.frame=CGRectMake(settingsX,buttonsTop,toolbarButtonWidth,toolbarButtonHeight);
    self.controllerPause.frame=CGRectMake(settingsX-6-toolbarButtonWidth,buttonsTop,toolbarButtonWidth,toolbarButtonHeight);
}
- (unsigned)actionButtonsAt:(CGPoint)point {
    if(CGRectContainsPoint(actionChordFrame,point)) return 3;
    if(CGRectContainsPoint(self.controllerKeys[4].frame,point)) return 1;
    if(CGRectContainsPoint(self.controllerKeys[5].frame,point)) return 2;
    return 0;
}
// 操作子の輪郭だけでなく周囲 margin ポイントまでを「操作子の近傍」とみなす（全画面時の誤ダブルタップ防止用）
// アクションボタンは連打で外しやすいため、専用の actionMargin（広め）を適用する
- (BOOL)isNearControllerControls:(CGPoint)point margin:(CGFloat)margin {
    return [self isNearControllerControls:point margin:margin actionMargin:margin];
}
- (BOOL)isNearControllerControls:(CGPoint)point margin:(CGFloat)margin actionMargin:(CGFloat)actionMargin {
    if(!self.controllerMode) return NO;
    if(CGRectContainsPoint(CGRectInset(stickFrame,-margin,-margin),point)) return YES;
    if(CGRectContainsPoint(CGRectInset(actionChordFrame,-actionMargin,-actionMargin),point)) return YES;
    for(int i=4;i<6;++i)
        if(CGRectContainsPoint(CGRectInset(self.controllerKeys[i].frame,-actionMargin,-actionMargin),point)) return YES;
    return !self.controllerPause.hidden &&
        CGRectContainsPoint(CGRectInset(self.controllerPause.frame,-margin,-margin),point);
}
- (void)changeActionButtonsFrom:(unsigned)previous to:(unsigned)next {
    for(unsigned index=0;index<2;++index) {
        unsigned bit=1u<<index;
        if((next & ~previous) & bit) [self updateKey:self.controllerKeys[4+index] down:YES];
    }
    for(unsigned index=0;index<2;++index) {
        unsigned bit=1u<<index;
        if((previous & ~next) & bit) [self updateKey:self.controllerKeys[4+index] down:NO];
    }
}
- (void)moveStickTo:(CGPoint)point {
    CGFloat cx=CGRectGetMidX(stickFrame), cy=CGRectGetMidY(stickFrame);
    CGFloat dx=point.x-cx, dy=point.y-cy;
    CGFloat distance=std::hypot(dx,dy), radius=stickFrame.size.width/2;
    CGFloat travel=radius*.35;
    CGFloat scale=distance>travel ? travel/distance : 1;
    self.stickKnob.center=CGPointMake(cx+dx*scale,cy+dy*scale);
    unsigned next=0;
    if(distance>=radius*.23) {
        constexpr CGFloat diagonal=0.41421356;
        if(std::abs(dy)>=std::abs(dx)*diagonal) next|=dy<0 ? 1u : 8u;
        if(std::abs(dx)>=std::abs(dy)*diagonal) next|=dx<0 ? 2u : 4u;
    }
    for(int i=0;i<4;++i) if((stickDirections & ~next) & (1u<<i))
        [self updateKey:self.controllerKeys[i] down:NO cancelled:YES];
    NSMutableArray* pressed=[NSMutableArray new];
    for(int i=0;i<4;++i) if((next & ~stickDirections) & (1u<<i))
        [pressed addObject:self.controllerKeys[i]];
    stickDirections=next;
    [self pressKeys:pressed];
}
- (void)setHardwareLayout:(BOOL)value {
    if(_hardwareLayout==value) return;
    [self releaseAll]; _hardwareLayout=value; [self setNeedsLayout]; [self setNeedsDisplay];
}
- (CGRect)hardwareFrame {
    CGRect available=CGRectInset(self.bounds,2,4);
    // A portrait outer display or side pane must not stretch the six rows into
    // thin vertical strips. Use the full width and keep a keyboard-like height.
    CGFloat height=MAX(1,MIN(available.size.height,available.size.width*.44));
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
    if(self.outlinesOnly) return;
    if(self.controllerMode) {
        PC98Gradient(CGRectInset(self.bounds,1,1),PC98Plastic(.91),PC98Plastic(.69),10);
        [PC98Plastic(.61) setFill];
        [[UIBezierPath bezierPathWithOvalInRect:stickFrame] fill];
        [[UIBezierPath bezierPathWithRoundedRect:actionChordFrame cornerRadius:5] fill];
        return;
    }
    if(self.touchpadMode) { [self drawTouchpad]; return; }
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
    CGRect caseFrame=self.controllerMode || self.touchpadMode || !self.hardwareLayout ? CGRectInset(self.bounds,1,1) : [self hardwareFrame];
    self.layer.shadowPath=[UIBezierPath bezierPathWithRoundedRect:caseFrame cornerRadius:10].CGPath;
    self.controllerSettings.hidden=!self.controllerMode || self.outlinesOnly;
    self.controllerPause.hidden=!self.controllerMode;
    self.stickKnob.hidden=!self.controllerMode;
    for(PC98KeyButton* key in self.controllerKeys) {
        key.hidden=!self.controllerMode;
        key.isAccessibilityElement=self.controllerMode;
    }
    for(UIButton* button in self.touchpadButtons) button.hidden=!self.touchpadMode;
    if(self.touchpadMode) {
        for(NSArray* row in self.keys) for(UIButton* key in row) {
            key.hidden=YES;
            key.isAccessibilityElement=NO;
        }
        [self layoutTouchpad];
        [self setNeedsDisplay];
        return;
    }
    if(self.controllerMode) {
        for(NSArray* row in self.keys) for(UIButton* key in row) {
            key.hidden=YES;
            key.isAccessibilityElement=NO;
        }
        [self layoutController];
        return;
    }
    for(size_t r=0;r<rows.size();++r) for(size_t i=0;i<rows[r].size();++i) {
        PC98KeyButton* key=(PC98KeyButton*)self.keys[r][i]; const Key& definition=rows[r][i];
        key.hidden=NO; key.isAccessibilityElement=YES; key.steppedReturn=NO; key.detailScale=1; key.expandedLegends=NO;
        [key setTitle:[NSString stringWithUTF8String:definition.name] forState:UIControlStateNormal];
        key.modifier=(definition.scan==0 || definition.scan==14 || definition.scan==15 || definition.scan==28 || definition.scan==0x60 || definition.scan==0x61 || definition.scan>=0x70 || definition.scan==0x51 || definition.scan==0x35 || definition.scan==0x34);
    }
    if(self.hardwareLayout) { [self layoutHardwareKeys]; return; }
    CGFloat gap=3, left=10, top=48, usable=self.bounds.size.width-20;
    CGRect bank=[self vfBankFrame];
    CGFloat vfWidth=(bank.size.width-gap*4)/5;
    for(NSUInteger i=0;i<5;++i)
        self.keys[0][i].frame=CGRectMake(bank.origin.x+i*(vfWidth+gap),bank.origin.y,vfWidth,bank.size.height);
    CGFloat h=(self.bounds.size.height-top-12-gap*(rows.size()-2))/(rows.size()-1);
    for(size_t r=1;r<rows.size();++r) {
        float units=0; for(auto k:rows[r]) units+=k.width;
        CGFloat unit=(usable-gap*(rows[r].size()-1))/units, x=left;
        for(size_t c=0;c<rows[r].size();++c) {
            CGFloat w=unit*rows[r][c].width;
            PC98KeyButton* key=self.keys[r][c];
            key.frame=CGRectMake(x,top+(r-1)*(h+gap),w,MAX(1,h));
            if(key.alignedLegend) [key setNeedsLayout];
            x+=w+gap;
        }
    }
    // The two row slots form one tall Return key; the numeric Return stays separate.
    UIButton* upperReturn=self.keys[3].lastObject;
    UIButton* lowerReturn=self.keys[4].lastObject;
    upperReturn.frame=CGRectUnion(upperReturn.frame,lowerReturn.frame);
    [upperReturn setNeedsLayout];
    [upperReturn setNeedsDisplay];
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
        button.steppedReturn=spec.scan==28 && spec.h>40;
        button.frame=[self hardwareRect:CGRectMake(spec.x,spec.y,spec.w,spec.h)];
        if(button.alignedLegend) [button setNeedsLayout];
        if(spec.scan==0x34) [button setTitle:@"" forState:UIControlStateNormal];
        if(spec.scan>=0x52 && spec.scan<=0x6B) button.modifier=YES;
        [button setNeedsDisplay];
    }
    [self setNeedsDisplay];
}
- (BOOL)isLatch:(int)scan { return scan==0x70 || scan==0x71 || scan==0x72 || scan==0x73 || scan==0x74; }
- (BOOL)isHoldModifier:(int)scan { return scan==0x70 || scan==0x73 || scan==0x74; }
- (void)updateKey:(UIButton*)key down:(BOOL)down { [self updateKey:key down:down cancelled:NO]; }
- (void)updateKey:(UIButton*)key down:(BOOL)down cancelled:(BOOL)cancelled {
    if(down) {
        if(!self.keyFeedback) self.keyFeedback=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [self.keyFeedback impactOccurred]; [self.keyFeedback prepare];
    }
    int scan=(int)key.tag;
    BOOL hold=[self isHoldModifier:scan];
    if(down) {
        if(hold && !counts[scan]) modifierChords.erase(scan);
        for(const auto& state:counts) if(state.second>0 && state.first!=scan) {
            if([self isHoldModifier:state.first]) modifierChords.insert(state.first);
            if(hold) modifierChords.insert(scan);
        }
    }
    if([self isLatch:scan] && !hold) {
        // CAPS and kana remain toggle keys, even during a chord.
        if(!down) return;
        if(latched.count(scan)) latched.erase(scan); else latched.insert(scan);
        if(self.keyChanged) self.keyChanged(scan,latched.count(scan)>0);
    } else {
        int previous=counts[scan]; BOOL wasDown=previous>0 || latched.count(scan);
        counts[scan]=std::max(0,previous+(down?1:-1));
        if(hold && previous>0 && !counts[scan] && !down) {
            // A tap latches; using the held modifier with another key does not.
            if(!cancelled && !modifierChords.count(scan)) {
                if(latched.count(scan)) latched.erase(scan); else latched.insert(scan);
            }
            modifierChords.erase(scan);
        }
        if(!hold && !previous && down) repeatAt[scan]=CACurrentMediaTime()+0.45;
        if(!counts[scan]) repeatAt.erase(scan);
        BOOL isDown=counts[scan]>0 || latched.count(scan);
        if(self.keyChanged && wasDown!=isDown) self.keyChanged(scan,isDown);
    }
    for(NSArray* row in self.keys) for(PC98KeyButton* b in row) if(b.tag==scan)
        b.retroPressed=counts[scan]>0 || latched.count(scan);
    for(PC98KeyButton* b in self.controllerKeys) if(b.tag==scan) b.retroPressed=counts[scan]>0;
    if(!self.controllerMode && (scan==0x71 || scan==0x72)) [self setNeedsDisplay];
}
- (void)pressKeys:(NSArray<UIButton*>*)keys {
    // NSSet touch order is unspecified: Shift/Ctrl/GRPH must precede letters.
    NSArray* ordered=[keys sortedArrayUsingComparator:^NSComparisonResult(UIButton* a,UIButton* b) {
        int left=([self isLatch:(int)a.tag]?0:128)+(int)a.tag;
        int right=([self isLatch:(int)b.tag]?0:128)+(int)b.tag;
        return left<right ? NSOrderedAscending : left>right ? NSOrderedDescending : NSOrderedSame;
    }];
    for(UIButton* key in ordered) [self updateKey:key down:YES];
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
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    return [super pointInside:point withEvent:event] && (!self.outlinesOnly || CGRectContainsPoint(stickFrame,point) || [self actionButtonsAt:point]!=0 ||
        (!self.controllerPause.hidden && CGRectContainsPoint(self.controllerPause.frame,point)));
}
// 保留中の指があるか、または確定済みの入力が何も無い状態から着地した指は、切替スワイプの
// 候補として保留する。確定済みの入力（キー保持・スティック操作）がある状態で追加された指は
// コンボ入力として即時に確定する（遅延ゼロ）。
- (BOOL)hasActiveInputTouches { return !touches.empty() || !actionTouches.empty() || stickTouch!=nil; }
- (void)armPendingTimer {
    // 最後に保留へ加わった指から 0.15 秒で確定する（押し続け＝同時長押しとして救済）
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commitPendingTouches) object:nil];
    [self performSelector:@selector(commitPendingTouches) withObject:nil afterDelay:0.15];
}
- (void)commitPendingTouches {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commitPendingTouches) object:nil];
    if(pendingTouches.empty()) return;
    std::map<UITouch*,PendingTouch> pending; pending.swap(pendingTouches);
    [self refreshPendingCandidates];
    NSMutableArray* pressed=[NSMutableArray new];
    for(auto& pair:pending) {
        UITouch* t=pair.first;
        CGPoint point=[t locationInView:self];
        if(self.controllerMode) {
            if(CGRectContainsPoint(stickFrame,point)) {
                if(!stickTouch) { stickTouch=t; [self moveStickTo:point]; }
            } else {
                unsigned buttons=[self actionButtonsAt:point];
                actionTouches[t]=buttons;
                [self changeActionButtonsFrom:0 to:buttons];
            }
            continue;
        }
        UIButton* key=[self keyAtPoint:point];
        touches[t]=key;
        if(key) [pressed addObject:key];
    }
    [self pressKeys:pressed];
}
- (void)discardPendingTouches {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commitPendingTouches) object:nil];
    pendingTouches.clear();
    [self refreshPendingCandidates];
}
// 保留中の指が触れているキー／ボタン／スティックを「候補」表示にする。押下表示（retroPressed）
// とは別の見た目で、「触れているがまだ入力ではない」ことを目で見て分かるようにする。
- (void)refreshPendingCandidates {
    for(NSArray* row in self.keys) for(PC98KeyButton* b in row) b.retroCandidate=NO;
    for(PC98KeyButton* b in self.controllerKeys) b.retroCandidate=NO;
    BOOL stick=NO;
    for(auto& pair:pendingTouches) {
        CGPoint point=[pair.first locationInView:self];
        if(self.controllerMode) {
            if(CGRectContainsPoint(stickFrame,point)) stick=YES;
            else {
                unsigned mask=[self actionButtonsAt:point];
                for(unsigned i=0;i<2;++i) if(mask&(1u<<i)) self.controllerKeys[4+i].retroCandidate=YES;
            }
        } else {
            PC98KeyButton* key=(PC98KeyButton*)[self keyAtPoint:point];
            if(key) key.retroCandidate=YES;
        }
    }
    self.stickKnob.backgroundColor=PC98Plastic(stick ? .72 : .55);
    self.stickKnob.layer.borderColor=(stick ? [UIColor colorWithRed:1 green:.80 blue:.35 alpha:1] : PC98Plastic(.40)).CGColor;
}
- (void)touchesBegan:(NSSet<UITouch*>*)set withEvent:(UIEvent*)event {
    NSMutableArray* pressed=[NSMutableArray new];
    for(UITouch* t in set) {
        CGPoint point=[t locationInView:self];
        if(self.touchpadMode) {
            // 2本目以降の指が触れたらマルチタッチ操作（三本指スワイプ等）の始まりなので、
            // 1本目のタッチをタップ（左クリック）としては扱わない
            if(touchpadTouch && event.allTouches.count>1) touchpadTapCancelled=YES;
            // パッド面の1本目のタッチだけを扱う（上端の帯などパッド外は何もしない）
            if(!touchpadTouch && CGRectContainsPoint(touchpadFrame,point)) {
                touchpadTouch=t;
                touchpadTouchStart=touchpadTouchLast=point;
                touchpadTouchTime=t.timestamp;
                touchpadTouchTravelled=NO;
                touchpadTapCancelled=NO;
            }
            continue;
        }
        if(!pendingTouches.empty() || ![self hasActiveInputTouches]) {
            pendingTouches[t]={point};
            [self armPendingTimer];
            continue;
        }
        if(self.controllerMode) {
            if(CGRectContainsPoint(stickFrame,point)) {
                if(!stickTouch) { stickTouch=t; [self moveStickTo:point]; }
            } else {
                unsigned buttons=[self actionButtonsAt:point];
                actionTouches[t]=buttons;
                [self changeActionButtonsFrom:0 to:buttons];
            }
            continue;
        }
        UIButton* key=[self keyAtPoint:point];
        touches[t]=key;
        if(key) [pressed addObject:key];
    }
    [self pressKeys:pressed];
    [self refreshPendingCandidates];
}
- (void)touchesMoved:(NSSet<UITouch*>*)set withEvent:(UIEvent*)event {
    NSMutableArray* pressed=[NSMutableArray new];
    for(UITouch* t in set) {
        auto pending=pendingTouches.find(t);
        if(pending!=pendingTouches.end()) {
            // 保留が1本だけで大きく動いたらスワイプではなくドラッグ（スティック操作・キーなぞり）
            if(pendingTouches.size()==1) {
                CGPoint point=[t locationInView:self];
                CGFloat dx=point.x-pending->second.start.x, dy=point.y-pending->second.start.y;
                CGFloat threshold=(self.controllerMode && CGRectContainsPoint(stickFrame,pending->second.start)) ? 6 : 10;
                if(dx*dx+dy*dy>=threshold*threshold) [self commitPendingTouches];
                else continue;
            } else continue;
        }
        if(t==touchpadTouch) { [self moveTouchpadTouch:t]; continue; }
        if(t==stickTouch) { [self moveStickTo:[t locationInView:self]]; continue; }
        auto action=actionTouches.find(t);
        if(action!=actionTouches.end()) {
            unsigned next=[self actionButtonsAt:[t locationInView:self]];
            if(action->second!=next) {
                [self changeActionButtonsFrom:action->second to:next];
                action->second=next;
            }
            continue;
        }
        auto it=touches.find(t); if(it==touches.end()) continue;
        UIButton* next=[self keyAtPoint:[t locationInView:self]];
        if(next==it->second) continue;
        if(it->second) [self updateKey:it->second down:NO cancelled:YES];
        it->second=next;
        if(next) [pressed addObject:next];
    }
    [self pressKeys:pressed];
    [self refreshPendingCandidates];
}
- (void)endTouches:(NSSet<UITouch*>*)set cancelled:(BOOL)cancelled {
    if(cancelled) {
        for(UITouch* t in set) pendingTouches.erase(t);
        if(pendingTouches.empty())
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commitPendingTouches) object:nil];
    } else {
        // 保留中の指が離れる＝タップ。先に全ての保留を確定してから通常の終了処理に回すことで、
        // 「修飾キーを保留したまま文字キーを離す」ようなコード入力の順序も保たれる
        for(UITouch* t in set) if(pendingTouches.count(t)) { [self commitPendingTouches]; break; }
    }
    for(UITouch* t in set) {
        if(t==touchpadTouch) {
            // 動かさずに短く離したらタップ＝左クリック
            if(!cancelled && !touchpadTouchTravelled && !touchpadTapCancelled && t.timestamp-touchpadTouchTime<.35 && self.mouseClicked)
                self.mouseClicked(1);
            touchpadTouch=nil;
            touchpadTouchTravelled=NO;
            touchpadTapCancelled=NO;
            continue;
        }
        if(t==stickTouch) {
            [self moveStickTo:CGPointMake(CGRectGetMidX(stickFrame),CGRectGetMidY(stickFrame))];
            stickTouch=nil;
            continue;
        }
        auto action=actionTouches.find(t);
        if(action!=actionTouches.end()) {
            [self changeActionButtonsFrom:action->second to:0];
            actionTouches.erase(action);
            continue;
        }
        auto it=touches.find(t); if(it==touches.end()) continue;
        if(it->second) [self updateKey:it->second down:NO cancelled:cancelled];
        touches.erase(it);
    }
    [self refreshPendingCandidates];
}
- (void)touchesEnded:(NSSet<UITouch*>*)set withEvent:(UIEvent*)event { [self endTouches:set cancelled:NO]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)set withEvent:(UIEvent*)event { [self endTouches:set cancelled:YES]; }
- (void)repeatHeldKeys {
    double now=CACurrentMediaTime();
    for(auto& pair:repeatAt) if(now>=pair.second) { if(self.keyChanged) self.keyChanged(pair.first,YES); pair.second=now+0.05; }
}
#ifdef PC98PLAYER_TESTING
- (BOOL)controllerChordForTesting:(BOOL (^)(int scan))isDown {
    PC98Keyboard* controller=[[PC98Keyboard alloc] initWithFrame:self.bounds];
    controller.keyChanged=self.keyChanged;
    controller.outlinesOnly=self.outlinesOnly;
    if(!controller.controllerKeys) [controller buildController];
    [controller layoutController];
    for(NSUInteger index=0;index<controller.controllerKeys.count;++index)
        controller.controllerKeys[index].tag=controllerDefaultScans[index];

    PC98KeyButton* a=controller.controllerKeys[4];
    PC98KeyButton* b=controller.controllerKeys[5];
    const int right=controllerDefaultScans[2], space=(int)a.tag, enter=(int)b.tag;
    CGRect stick=controller->stickFrame;
    CGPoint center=CGPointMake(CGRectGetMidX(stick),CGRectGetMidY(stick));
    [controller moveStickTo:CGPointMake(CGRectGetMaxX(stick),center.y)];
    [controller pressKeys:@[a,b]];
    BOOL passed=isDown(right) && isDown(space) && isDown(enter);
    [controller updateKey:a down:NO];
    passed=passed && isDown(right) && !isDown(space) && isDown(enter);
    [controller moveStickTo:center];
    passed=passed && !isDown(right) && isDown(enter);
    [controller updateKey:b down:NO];
    passed=passed && !isDown(enter);

    CGPoint actionA=CGPointMake(CGRectGetMidX(a.frame),CGRectGetMidY(a.frame));
    CGPoint actionB=CGPointMake(CGRectGetMidX(b.frame),CGRectGetMidY(b.frame));
    CGPoint midpoint=CGPointMake((actionA.x+actionB.x)/2,(actionA.y+actionB.y)/2);
    unsigned onlyA=[controller actionButtonsAt:actionA];
    unsigned onlyB=[controller actionButtonsAt:actionB];
    unsigned both=[controller actionButtonsAt:midpoint];
    passed=passed && onlyA==1 && onlyB==2 && both==3;
    [controller changeActionButtonsFrom:0 to:onlyA];
    [controller changeActionButtonsFrom:onlyA to:both];
    passed=passed && isDown(space) && isDown(enter);
    [controller changeActionButtonsFrom:both to:onlyB];
    passed=passed && !isDown(space) && isDown(enter);
    [controller changeActionButtonsFrom:onlyB to:0];
    passed=passed && !isDown(enter);

    b.tag=a.tag;
    [controller pressKeys:@[a,b]];
    [controller updateKey:a down:NO];
    passed=passed && isDown(space);
    [controller updateKey:b down:NO];
    return passed && !isDown(space);
}
- (BOOL)controlMarginForTesting {
    PC98Keyboard* probe=[[PC98Keyboard alloc] initWithFrame:CGRectMake(0,0,844,390)];
    probe.outlinesOnly=YES;
    if(!probe.controllerKeys) [probe buildController];
    [probe layoutController];
    const CGFloat margin=20;
    CGRect b=probe.controllerKeys[5].frame, stick=probe->stickFrame;
    CGPoint buttonCenter=CGPointMake(CGRectGetMidX(b),CGRectGetMidY(b));
    CGPoint buttonNear=CGPointMake(CGRectGetMaxX(b)+margin/2,CGRectGetMidY(b));
    CGPoint buttonWide=CGPointMake(CGRectGetMaxX(b)+30,CGRectGetMidY(b));
    CGPoint stickNear=CGPointMake(CGRectGetMinX(stick)-margin/2,CGRectGetMidY(stick));
    CGPoint bottomFar=CGPointMake(CGRectGetMidX(probe.bounds),CGRectGetMaxY(probe.bounds)-2);
    CGPoint cornerFar=CGPointMake(2,2);
    return [probe isNearControllerControls:buttonCenter margin:margin] &&
        [probe isNearControllerControls:buttonNear margin:margin] &&
        [probe isNearControllerControls:stickNear margin:margin] &&
        ![probe isNearControllerControls:buttonNear margin:0] &&
        [probe isNearControllerControls:buttonWide margin:margin actionMargin:50] &&
        ![probe isNearControllerControls:buttonWide margin:margin] &&
        ![probe isNearControllerControls:bottomFar margin:margin] &&
        ![probe isNearControllerControls:cornerFar margin:margin];
}
- (BOOL)touchpadForTesting:(BOOL (^)(int button))isDown {
    PC98Keyboard* probe=[[PC98Keyboard alloc] initWithFrame:self.bounds];
    probe.mouseClicked=self.mouseClicked;
    // 右＝次、左＝前の一方向チェーン：キーボード→ゲームパッド→タッチパッド（端では止まる）→…→キーボード
    const NSInteger steps[]={1,1,1,-1,-1,-1}, expected[]={1,2,2,1,0,0};
    BOOL passed=[probe inputModeIndex]==0;
    // モード切替のパン認識器は三本指専用（一本指のタイピング・パッド操作、二本指の右クリック等と競合しない）
    NSUInteger switchPans=0;
    for(UIGestureRecognizer* gesture in probe.gestureRecognizers) {
        if(![gesture isKindOfClass:UIPanGestureRecognizer.class] || gesture.delegate!=probe) continue;
        UIPanGestureRecognizer* pan=(UIPanGestureRecognizer*)gesture;
        passed=passed && pan.minimumNumberOfTouches==3 && pan.maximumNumberOfTouches==3;
        ++switchPans;
    }
    passed=passed && switchPans==1;
    for(size_t i=0;i<std::size(steps);++i) {
        [probe stepInputMode:steps[i]];
        passed=passed && [probe inputModeIndex]==expected[i];
    }
    [probe stepInputMode:1]; [probe stepInputMode:1];
    [probe setNeedsLayout]; [probe layoutIfNeeded];
    UIButton* left=probe.touchpadButtons.firstObject;
    UIButton* right=probe.touchpadButtons.lastObject;
    CGRect pad=probe->touchpadFrame;
    passed=passed && probe.touchpadMode && !probe.controllerMode && probe.touchpadButtons.count==2 &&
        !left.hidden && !right.hidden && CGRectContainsRect(probe.bounds,pad) &&
        CGRectContainsRect(probe.bounds,left.frame) && CGRectContainsRect(probe.bounds,right.frame) &&
        CGRectGetMinY(left.frame)>=CGRectGetMaxY(pad) && CGRectGetMaxX(left.frame)<=CGRectGetMinX(right.frame) &&
        CGRectGetMinY(pad)>0 && probe.keys[2][1].hidden;
    [left sendActionsForControlEvents:UIControlEventTouchUpInside];
    passed=passed && isDown(1);
    [right sendActionsForControlEvents:UIControlEventTouchUpInside];
    passed=passed && isDown(2);
    // 全画面（枠表示）中はコントローラーに切り替わり、戻るとタッチパッドに復帰する
    probe.outlinesOnly=YES; [probe layoutIfNeeded];
    passed=passed && !probe.touchpadMode && probe.controllerMode && left.hidden && right.hidden;
    probe.outlinesOnly=NO; [probe layoutIfNeeded];
    return passed && probe.touchpadMode && !probe.controllerMode && !left.hidden;
}
- (BOOL)pressScansForTesting:(NSArray<NSNumber*>*)scans {
    NSMutableArray* buttons=[NSMutableArray new];
    for(NSNumber* scan in scans) {
        UIButton* found=nil;
        for(NSArray* row in self.keys) for(UIButton* key in row)
            if(!key.hidden && key.tag==scan.intValue && !found) found=key;
        if(!found) return NO;
        [buttons addObject:found];
    }
    [self pressKeys:buttons]; return YES;
}
- (BOOL)releaseScanForTesting:(int)scan cancelled:(BOOL)cancelled {
    for(NSArray* row in self.keys) for(UIButton* key in row) if(!key.hidden && key.tag==scan) {
        [self updateKey:key down:NO cancelled:cancelled]; return YES;
    }
    return NO;
}
- (BOOL)tapReturnSectionsForTesting {
    [self layoutIfNeeded];
    PC98KeyButton* key=self.keys[3].lastObject;
    [key layoutIfNeeded];
    CGRect legend=key.titleLabel.frame;
    CGFloat expectedX=CGRectGetMidX(key.bounds);
    if(key.steppedReturn) expectedX+=CGRectGetWidth(key.bounds)*6/56;
    if(std::abs(CGRectGetMidX(legend)-expectedX)>.5 ||
       std::abs(CGRectGetMidY(legend)-CGRectGetMidY(key.bounds))>.5) return NO;
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
    BOOL lampsWereOn=latched.count(0x71) || latched.count(0x72);
    std::set<int> down=latched; for(auto pair:counts) if(pair.second) down.insert(pair.first);
    for(int scan:down) if(self.keyChanged) self.keyChanged(scan,NO);
    stickTouch=nil;
    touchpadTouch=nil;
    touchpadTouchTravelled=NO;
    touchpadTapCancelled=NO;
    stickDirections=0;
    self.stickKnob.center=CGPointMake(CGRectGetMidX(stickFrame),CGRectGetMidY(stickFrame));
    actionTouches.clear();
    pendingTouches.clear();
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(commitPendingTouches) object:nil];
    [self refreshPendingCandidates];
    touches.clear(); counts.clear(); latched.clear(); modifierChords.clear(); repeatAt.clear();
    for(NSArray* row in self.keys) for(PC98KeyButton* b in row) b.retroPressed=NO;
    for(PC98KeyButton* key in self.controllerKeys) key.retroPressed=NO;
    if(!self.controllerMode && lampsWereOn) [self setNeedsDisplay];
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

NSArray<NSNumber*>* pc98_controller_bindings(NSArray<NSNumber*>* saved) {
    NSMutableArray<NSNumber*>* bindings=[NSMutableArray new];
    for(NSUInteger i=0;i<std::size(controllerDefaultScans);++i) {
        NSNumber* value=i<saved.count ? saved[i] : nil;
        BOOL valid=[value isKindOfClass:NSNumber.class] && value.intValue>=0 && value.intValue<128;
        [bindings addObject:valid ? value : @(controllerDefaultScans[i])];
    }
    return bindings;
}

UIMenu* pc98_controller_binding_menu(NSArray<NSNumber*>* bindings, NSMutableArray<NSString*>* selectedNames,
                                    void (^changed)(NSArray<NSNumber*>*)) {
    NSMutableArray<NSString*>* letters=[NSMutableArray new];
    for(char c='A';c<='Z';++c) [letters addObject:[NSString stringWithFormat:@"%c",c]];
    NSMutableArray<NSString*>* functions=[NSMutableArray new];
    for(int i=1;i<=10;++i) [functions addObject:[NSString stringWithFormat:@"F%d",i]];
    for(int i=1;i<=5;++i) [functions addObject:[NSString stringWithFormat:@"VF%d",i]];
    NSArray* categories=@[@"アルファベット",@"ファンクションキー",@"数字",@"操作キー"];
    NSArray* names=@[letters,functions,@[@"0",@"1",@"2",@"3",@"4",@"5",@"6",@"7",@"8",@"9"],
                     @[@"Enter",@"Space",@"Esc",@"Tab",@"Backspace",@"←",@"↑",@"↓",@"→"]];
    NSArray<NSString*>* labels=@[@"↑",@"←",@"→",@"↓",@"A",@"B"];
    NSMutableArray* controls=[NSMutableArray new];
    for(NSUInteger index=0;index<labels.count;++index) {
        int selected=bindings[index].intValue;
        NSString* selectedName=@"";
        void (^assign)(int)=^(int scan) {
            NSMutableArray<NSNumber*>* updated=[bindings mutableCopy];
            updated[index]=@(scan);
            changed(updated);
        };
        NSMutableArray* groups=[NSMutableArray new];
        for(NSUInteger category=0;category<categories.count;++category) {
            NSMutableArray* actions=[NSMutableArray new];
            for(NSUInteger i=0;i<[names[category] count];++i) {
                const int special[]={28,0x34,0,15,14,0x3B,0x3A,0x3D,0x3C};
                int scan;
                switch(category) {
                    case 0: scan=pc98_scan_from_hid(4+i); break;
                    case 1: scan=i<10 ? 0x62+(int)i : 0x52+(int)i-10; break;
                    case 2: scan=i ? (int)i : 10; break;
                    default: scan=special[i]; break;
                }
                NSString* name=names[category][i];
                if(selected==scan) selectedName=name;
                UIAction* action=[UIAction actionWithTitle:name image:nil identifier:nil handler:^(__kindof UIAction* sender) { assign(scan); }];
                action.state=selected==scan ? UIMenuElementStateOn : UIMenuElementStateOff;
                [actions addObject:action];
            }
            [groups addObject:[UIMenu menuWithTitle:categories[category] children:actions]];
        }
        [groups addObject:[UIAction actionWithTitle:@"この割り当てを初期値に戻す" image:nil identifier:nil handler:^(__kindof UIAction* action) {
            assign(controllerDefaultScans[index]);
        }]];
        [selectedNames addObject:selectedName];
        NSString* title=[NSString stringWithFormat:@"%@  ·  %@",labels[index],selectedName];
        [controls addObject:[UIMenu menuWithTitle:title children:groups]];
    }
    [controls addObject:[UIAction actionWithTitle:@"すべての割り当てを初期値に戻す" image:nil identifier:nil handler:^(__kindof UIAction* action) {
        changed(pc98_controller_bindings(nil));
    }]];
    return [UIMenu menuWithTitle:@"キー割り当て" children:controls];
}
