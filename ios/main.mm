// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "GameLibrary.h"
#import "Keyboard.h"
#import "RetroHardware.h"
#include "AudioOut.h"
#include "font.h"
#include "player.h"
#include "hostfs.h"
#include <memory>
#include <set>
#include <algorithm>
#ifdef PC98PLAYER_TESTING
#import "AudioCaptureProbe.h"
#endif

// Keep the largest 8:5 display area clear of an OS camera or system occlusion.
static CGRect monitorAvoiding(CGRect panel,CGRect obstacle) {
    CGRect cut=CGRectIntersection(panel,obstacle);
    if(CGRectIsNull(cut) || CGRectIsEmpty(cut)) return panel;
    CGRect candidates[]={
        CGRectMake(panel.origin.x,panel.origin.y,panel.size.width,CGRectGetMinY(cut)-panel.origin.y),
        CGRectMake(panel.origin.x,CGRectGetMaxY(cut),panel.size.width,CGRectGetMaxY(panel)-CGRectGetMaxY(cut)),
        CGRectMake(panel.origin.x,panel.origin.y,CGRectGetMinX(cut)-panel.origin.x,panel.size.height),
        CGRectMake(CGRectGetMaxX(cut),panel.origin.y,CGRectGetMaxX(panel)-CGRectGetMaxX(cut),panel.size.height)};
    CGRect best=CGRectZero; CGFloat bestHeight=-1;
    for(CGRect r:candidates) {
        CGFloat height=MIN(r.size.height,r.size.width/1.6);
        if(height>bestHeight) { best=r; bestHeight=height; }
    }
    return best;
}
// Keep extra width for the full keyboard while retaining the CRT cabinet.
static std::array<CGRect,2> phoneLandscapePanels(CGRect safe) {
    CGFloat gap=12, monitorWidth=(safe.size.width-gap)*.44;
    return {CGRectMake(safe.origin.x,safe.origin.y,monitorWidth,safe.size.height),
        CGRectMake(safe.origin.x+monitorWidth+gap,safe.origin.y+6,safe.size.width-monitorWidth-gap,MAX(1,safe.size.height-12))};
}
static NSString* text(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
static NSURL* area(NSSearchPathDirectory directory,NSString* component) {
    return [[NSFileManager.defaultManager URLsForDirectory:directory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:component isDirectory:YES];
}
static NSString* gameID(NSURL* url) {
    NSData* bytes=[url.URLByStandardizingPath.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,hash);
    NSMutableString* key=[NSMutableString new]; for(unsigned char c:hash) [key appendFormat:@"%02x",c]; return key;
}
static UIImage* frameImage(Player* p) {
    NSData* bytes=[NSData dataWithBytes:p->fb length:sizeof(p->fb)];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=CGImageCreate(640,400,8,32,640*4,colors,kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst,provider,nullptr,false,kCGRenderingIntentDefault);
    UIImage* result=[UIImage imageWithCGImage:image]; CGImageRelease(image); CGColorSpaceRelease(colors); CGDataProviderRelease(provider); return result;
}
@interface FileChooser : UITableViewController
@property NSArray<NSString*>* paths;
@property(copy) void (^selected)(NSString*);
@end
@implementation FileChooser
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return self.paths.count; }
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)index {
    UITableViewCell* cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text=self.paths[index.row]; cell.textLabel.numberOfLines=2; return cell;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)index {
    NSString* path=self.paths[index.row]; [self dismissViewControllerAnimated:YES completion:^{ if(self.selected) self.selected(path); }];
}
@end

@interface GameOptionsController : UITableViewController
@property NSInteger soundBoard;
@property NSInteger videoColors;
@property BOOL manualDuo;
@property(copy) void (^applied)(NSInteger,NSInteger,BOOL);
@property(copy) void (^cancelled)(void);
@end
@implementation GameOptionsController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"オプション";
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"キャンセル" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"適用" style:UIBarButtonItemStyleDone target:self action:@selector(apply)];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView { return 3; }
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return 2; }
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section { return section==0?@"音源":section==1?@"色数":@"表示"; }
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section { return section==1?@"音源・色数の変更はゲームを再起動します。必要な場合は、先にゲーム内で保存してください。":section==2?@"通常は自動判別を使います。Duo上下表示を固定すると、上にモニタ、下にキーボードを配置します。表示だけの変更では再起動しません。":nil; }
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)index {
    UITableViewCell* cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if(index.section==0) {
        cell.textLabel.text=index.row==0?@"OPN":@"OPNA";
        cell.detailTextLabel.text=index.row==0?@"PC-9801-26 / YM2203":@"PC-9801-86 / YM2608";
        cell.accessoryType=(self.soundBoard==(index.row==0?26:86))?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    } else if(index.section==1) {
        cell.textLabel.text=index.row==0?@"16色":@"256色";
        cell.detailTextLabel.text=index.row==0?@"標準グラフィック":@"PC-9821拡張グラフィック";
        cell.accessoryType=(self.videoColors==(index.row==0?16:256))?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    } else {
        cell.textLabel.text=index.row==0?@"自動判別":@"Duo上下表示を固定";
        cell.detailTextLabel.text=index.row==0?@"端末とヒンジの状態に合わせる":@"上にモニタ、下にキーボード";
        cell.accessoryType=(self.manualDuo==(index.row==1))?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    }
    return cell;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)index {
    if(index.section==0) self.soundBoard=index.row==0?26:86;
    else if(index.section==1) self.videoColors=index.row==0?16:256;
    else self.manualDuo=index.row==1;
    [tableView reloadData];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:^{if(self.cancelled) self.cancelled();}]; }
- (void)apply { [self dismissViewControllerAnimated:YES completion:^{if(self.applied) self.applied(self.soundBoard,self.videoColors,self.manualDuo);}]; }
@end

@interface PlayerController : UIViewController <UIDocumentPickerDelegate,UIAdaptivePresentationControllerDelegate,UIGestureRecognizerDelegate> {
    std::unique_ptr<Player> player;
    AudioOut audio;
    double nextFrame;
    BOOL paused, fetching, pickerPreviousPause, manualDuo, hingeDuo, duoHardware, fullScreen, fullscreenMenuPaused;
    int mouseButtons;
    std::set<NSInteger> physicalKeys;
    std::set<int> touchKeys;
}
@property UIImageView* monitor;
@property PC98MonitorCabinet* topPanel;
@property PC98Keyboard* keyboard;
@property UILabel* status;
@property UIStackView* toolbar;
@property CADisplayLink* displayLink;
@property UIActivityIndicatorView* spinner;
@property NSURL* currentCache;
@property NSString* currentID;
#ifdef PC98PLAYER_TESTING
@property AudioCaptureProbe* audioProbe;
#endif
@end
@implementation PlayerController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if(self.traitCollection.userInterfaceIdiom==UIUserInterfaceIdiomPhone && !manualDuo && !hingeDuo && !duoHardware)
        return UIInterfaceOrientationMaskAllButUpsideDown;
    return UIInterfaceOrientationMaskAll;
}
- (BOOL)prefersStatusBarHidden { return fullScreen || manualDuo || hingeDuo || duoHardware; }
- (BOOL)prefersHomeIndicatorAutoHidden { return fullScreen; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.multipleTouchEnabled=YES; self.view.backgroundColor=PC98Plastic(.84); paused=YES;
    manualDuo=[NSUserDefaults.standardUserDefaults boolForKey:@"PC98ManualDuo"];
    self.topPanel=[PC98MonitorCabinet new]; [self.view addSubview:self.topPanel];
    self.monitor=[UIImageView new]; self.monitor.contentMode=UIViewContentModeScaleAspectFit;
    self.monitor.layer.cornerRadius=4; self.monitor.clipsToBounds=YES; self.monitor.backgroundColor=[UIColor colorWithRed:.035 green:.055 blue:.052 alpha:1]; self.monitor.layer.magnificationFilter=kCAFilterNearest; self.monitor.userInteractionEnabled=YES; self.monitor.multipleTouchEnabled=YES;
    [self.topPanel addSubview:self.monitor];
    UIPanGestureRecognizer* pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveMouse:)];
    pan.maximumNumberOfTouches=1;[self.monitor addGestureRecognizer:pan];
    UILongPressGestureRecognizer* hold=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(fullscreenLongPress:)];
    hold.minimumPressDuration=.5;hold.numberOfTouchesRequired=1;hold.delegate=self;
    [self.monitor addGestureRecognizer:hold];
    UITapGestureRecognizer* twoFingerTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rightClick)];
    twoFingerTap.numberOfTouchesRequired=2;[self.monitor addGestureRecognizer:twoFingerTap];
    UITapGestureRecognizer* doubleTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleFullScreen)];
    doubleTap.numberOfTapsRequired=2;[doubleTap requireGestureRecognizerToFail:twoFingerTap];[self.monitor addGestureRecognizer:doubleTap];
    UITapGestureRecognizer* tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(leftClick:)];
    [tap requireGestureRecognizerToFail:hold];[tap requireGestureRecognizerToFail:doubleTap];[tap requireGestureRecognizerToFail:twoFingerTap];[self.monitor addGestureRecognizer:tap];
    self.status=[UILabel new]; self.status.text=@"ゲームフォルダを選択してください";
    self.status.textColor=[UIColor colorWithWhite:.24 alpha:1]; self.status.font=[UIFont monospacedSystemFontOfSize:8 weight:UIFontWeightRegular]; self.status.numberOfLines=1; self.status.adjustsFontSizeToFitWidth=YES;
    [self.view addSubview:self.status];
    self.toolbar=[UIStackView new]; self.toolbar.axis=UILayoutConstraintAxisHorizontal; self.toolbar.distribution=UIStackViewDistributionFillEqually; self.toolbar.spacing=3;
    NSArray* titles=@[@"開く",@"場所",@"▶︎ / Ⅱ",@"保存",@"読込",@"リセット",@"右クリック"];
    SEL actions[]={@selector(openFolder),@selector(showLibrary),@selector(togglePause),@selector(saveSlot),@selector(loadSlot),@selector(resetGame),@selector(rightClick)};
    for(NSUInteger i=0;i<titles.count;++i) { UIButton* b=[UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:titles[i] forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; [b setTitleColor:[UIColor colorWithWhite:.18 alpha:1] forState:UIControlStateNormal]; [b setTitleColor:UIColor.grayColor forState:UIControlStateHighlighted]; b.backgroundColor=PC98Plastic(.87); b.layer.cornerRadius=2; b.layer.borderWidth=1; b.layer.borderColor=PC98Plastic(.55).CGColor; b.layer.shadowColor=UIColor.blackColor.CGColor; b.layer.shadowOffset=CGSizeMake(0,1); b.layer.shadowOpacity=.25; b.layer.shadowRadius=0; b.titleLabel.adjustsFontSizeToFitWidth=YES; [b addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside]; [self.toolbar addArrangedSubview:b]; }
    [self.view addSubview:self.toolbar];
    self.keyboard=[PC98Keyboard new]; __weak PlayerController* weak=self;
    self.keyboard.optionsRequested=^{ [weak showOptions]; };
    self.keyboard.keyChanged=^(int scan,BOOL down) {
        PlayerController* s=weak; if(!s) return;
        if(down) s->touchKeys.insert(scan); else s->touchKeys.erase(scan);
        [s updateScan:scan];
    };
    [self.view addSubview:self.keyboard];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge]; self.spinner.color=PC98Plastic(.8); [self.topPanel addSubview:self.spinner];
    self.displayLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [NSFileManager.defaultManager createDirectoryAtURL:area(NSDocumentDirectory,@"Games") withIntermediateDirectories:YES attributes:nil error:nil];
#if __has_include(<UIKit/UIHingeInteraction.h>)
    if(@available(iOS 27.1,*)) {
        UIHingeInteraction* interaction=[[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction* interaction,UIHingeInteractionUpdate* update) {
            PlayerController* s=weak; if(!s) return;
            BOOL hardware=update.hinge!=nil;
            BOOL duo=hardware && update.hinge.status==UIHingeStatusPartiallyOpen;
            if(s->hingeDuo!=duo || s->duoHardware!=hardware) { [s releaseKeys]; s->duoHardware=hardware; s->hingeDuo=duo; [s setNeedsUpdateOfSupportedInterfaceOrientations]; [s setNeedsStatusBarAppearanceUpdate]; [s.view setNeedsLayout]; }
        }];
        [self.view addInteraction:interaction];
    }
#endif
    if([NSProcessInfo.processInfo.arguments containsObject:@"--demo"]) [self demo];
#ifdef PC98PLAYER_TESTING
    NSArray<NSString*>* arguments=NSProcessInfo.processInfo.arguments;
    NSUInteger cachedIndex=[arguments indexOfObject:@"--cached-game"];
    if(cachedIndex!=NSNotFound && cachedIndex+1<arguments.count) {
        NSString* identifier=arguments[cachedIndex+1];
        NSCharacterSet* invalid=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet];
        if(identifier.length && [identifier rangeOfCharacterFromSet:invalid].location==NSNotFound) {
            NSURL* cache=area(NSCachesDirectory,[@"PC98Games/" stringByAppendingString:identifier]);
            if([NSFileManager.defaultManager fileExistsAtPath:[cache URLByAppendingPathComponent:@"PC98PLAYER.INI"].path])
                [self openCache:cache identifier:identifier];
            else [self message:@"指定されたゲームのキャッシュがありません。"];
        }
    }
    NSUInteger probeIndex=[arguments indexOfObject:@"--audio-probe"];
    if(probeIndex!=NSNotFound && probeIndex+1<arguments.count) {
        NSString* label=arguments[probeIndex+1];
        if([@[@"before",@"after",@"rotation"] containsObject:label]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ [weak startAudioProbe:label]; });
    }
    if([arguments containsObject:@"--hardware-report"]) {
        [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer* timer) {
            PlayerController* s=weak;if(!s || !s->player) return;
            Machine* m=s->player->m;std::set<uint32_t> colors;
            for(uint32_t pixel:s->player->fb) colors.insert(pixel);
            int peak=0;for(int16_t sample:s->player->audio) peak=std::max(peak,std::abs((int)sample));
            size_t buffered=0;uint64_t underrun=0;{ std::lock_guard<std::mutex> lock(s->audio.mutex);buffered=s->audio.samples.size();underrun=s->audio.underrunFrames; }
            AudioQueueParameterValue ramp=0;if(s->audio.queue) AudioQueueGetParameter(s->audio.queue,kAudioQueueParam_VolumeRampTime,&ramp);
            NSDictionary* report=@{@"game":s.currentID ?: @"",@"running":@(!s->paused),@"guestQuit":@(m->quit),
                @"videoColors":@(m->cfg.video_colors),@"pegcActive":@(m->pegc.enabled),@"screenColorCount":@(colors.size()),
                @"soundBoard":@(m->cfg.sound_board),@"audioPeak":@(peak),@"frame":@(m->frame_count),
                @"audioUnderrunFrames":@(underrun),@"audioVolumeRampSeconds":@(ramp),@"audioQueueGeneration":@(s->audio.generation),@"audioStarted":@(s->audio.started),@"audioPaused":@(s->audio.paused),@"audioQueuedSamples":@(buffered)};
            [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
                writeToURL:area(NSDocumentDirectory,@"hardware-report.json") atomically:YES];
        }];
    }
    if([arguments containsObject:@"--launch-report"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            PlayerController* s=weak; if(!s) return;
            NSDictionary* report=@{@"game":s.currentID ?: @"",@"running":@(s->player && !s->paused),
                @"guestQuit":@(s->player ? s->player->m->quit : -1),@"status":s->player ? text(s->player->m->status) : @"No player"};
            [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
                writeToURL:area(NSDocumentDirectory,@"game-launch.json") atomically:YES];
            UIGraphicsImageRenderer* renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:s.view.bounds];
            UIImage* shot=[renderer imageWithActions:^(UIGraphicsImageRendererContext* context) { [s.view.layer renderInContext:context.CGContext]; }];
            [UIImagePNGRepresentation(shot) writeToURL:area(NSDocumentDirectory,@"game-launch.png") atomically:YES];
        });
    }
    if([NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"]) {
        [self demo];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ [weak smokeTest]; });
    }
#endif
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self becomeFirstResponder]; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self releaseKeys];
#ifdef PC98PLAYER_TESTING
    [self.audioProbe event:@"rotation"];
#endif
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect safe=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);
    BOOL duo=manualDuo || hingeDuo;
    self.keyboard.hardwareLayout=duo || duoHardware;
    self.topPanel.expandedDisplay=duo || duoHardware;
    BOOL phoneLandscape=self.traitCollection.userInterfaceIdiom==UIUserInterfaceIdiomPhone && !duo && !duoHardware && self.view.bounds.size.width>self.view.bounds.size.height;
    CGRect division=CGRectNull;
#if __has_include(<UIKit/UIViewReservedRegion.h>)
    if(@available(iOS 27.1,*)) {
        for(UIViewReservedRegion* region in [self.view reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind]) {
            CGRect intersection=CGRectIntersection(region.frame,safe);
            if(region.isActive && !CGRectIsEmpty(intersection) && !CGRectIsNull(intersection)) { division=intersection; break; }
        }
    }
#endif
    // Use OS geometry, not device names or a guessed pixel resolution.
    BOOL verticalDivision=duo && !CGRectIsNull(division) && division.size.height>division.size.width;
    CGFloat split=duo ? CGRectGetMidY(self.view.bounds) : safe.origin.y+safe.size.height*0.53;
    if(duo && !CGRectIsNull(division) && !verticalDivision) split=CGRectGetMidY(division);
    split=std::clamp(split,safe.origin.y+100,CGRectGetMaxY(safe)-100);
    self.topPanel.frame=CGRectMake(safe.origin.x,safe.origin.y,safe.size.width,split-safe.origin.y-12);
    self.keyboard.frame=CGRectMake(safe.origin.x+6,split+12,safe.size.width-12,MAX(1,CGRectGetMaxY(safe)-split-18));
    if(duo && !CGRectIsNull(division)) {
        if(verticalDivision) {
            self.topPanel.frame=CGRectMake(safe.origin.x,safe.origin.y,MAX(1,CGRectGetMinX(division)-safe.origin.x-8),safe.size.height);
            self.keyboard.frame=CGRectMake(CGRectGetMaxX(division)+8,safe.origin.y,MAX(1,CGRectGetMaxX(safe)-CGRectGetMaxX(division)-8),safe.size.height);
        } else {
            self.topPanel.frame=CGRectMake(safe.origin.x,safe.origin.y,safe.size.width,MAX(1,CGRectGetMinY(division)-safe.origin.y-8));
            self.keyboard.frame=CGRectMake(safe.origin.x,CGRectGetMaxY(division)+8,safe.size.width,MAX(1,CGRectGetMaxY(safe)-CGRectGetMaxY(division)-8));
        }
    }
    if(phoneLandscape) {
        auto panels=phoneLandscapePanels(safe);
        self.topPanel.frame=panels[0];self.keyboard.frame=panels[1];
    }
    CGRect fullscreenAvailable=safe;
    NSMutableArray* occlusions=[NSMutableArray new];
#if __has_include(<UIKit/UIViewReservedRegion.h>)
    if(@available(iOS 27.1,*)) {
        for(UIViewReservedRegion* region in [self.view reservedRegionsOfKind:UIViewReservedRegionKind.occlusionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive]) {
            [occlusions addObject:@{@"frame":@[@(region.frame.origin.x),@(region.frame.origin.y),@(region.frame.size.width),@(region.frame.size.height)],@"active":@(region.isActive)}];
            if(!region.isActive) continue;
            self.topPanel.frame=monitorAvoiding(self.topPanel.frame,region.frame);
            fullscreenAvailable=monitorAvoiding(fullscreenAvailable,region.frame);
        }
    }
#endif
    CGFloat w=self.topPanel.bounds.size.width,h=self.topPanel.bounds.size.height;
    // Move controls into spare space above the keyboard when a horizontal fold permits it.
    CGFloat keyboardSlack=(self.keyboard.bounds.size.height-MIN(self.keyboard.bounds.size.height-8,(self.keyboard.bounds.size.width-4)*.44))/2;
    BOOL separateControls=duo && !verticalDivision && keyboardSlack>=54;
    self.topPanel.separateControls=separateControls;
    if(separateControls) {
        CGRect lower=self.keyboard.frame;
        self.toolbar.frame=CGRectMake(lower.origin.x+12,lower.origin.y+4,lower.size.width-24,32);
        self.status.frame=CGRectMake(lower.origin.x+15,lower.origin.y+40,lower.size.width-30,10);
    } else {
        self.status.frame=[self.topPanel convertRect:[self.topPanel statusFrame] toView:self.view];
        self.toolbar.frame=[self.topPanel convertRect:[self.topPanel controlsFrame] toView:self.view];
    }
    [self.view bringSubviewToFront:self.toolbar];
    [self.view bringSubviewToFront:self.status];
    if(fullScreen) {
        CGFloat width=MAX(1,MIN(fullscreenAvailable.size.width,fullscreenAvailable.size.height*1.6));
        self.monitor.frame=CGRectMake(CGRectGetMidX(fullscreenAvailable)-width/2,CGRectGetMidY(fullscreenAvailable)-width/3.2,width,width/1.6);
    } else self.monitor.frame=[self.topPanel screenFrame];
    self.spinner.center=CGPointMake(w/2,h/2);
    [self.topPanel setNeedsDisplay];
#ifdef PC98PLAYER_TESTING
    if([NSProcessInfo.processInfo.arguments containsObject:@"--layout-report"]) {
        auto rect=[](CGRect r)->id { if(CGRectIsNull(r)) return NSNull.null; return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]; };
        UIScreen* screen=self.view.window.windowScene.screen;
        NSDictionary* report=@{@"viewBounds":rect(self.view.bounds),@"safeBounds":rect(safe),
            @"screenBounds":rect(screen.bounds),@"screenNativeBounds":rect(screen.nativeBounds),
            @"displayScale":@(self.traitCollection.displayScale),@"nativeScale":@(screen.nativeScale),
            @"divisionRegion":rect(division),@"monitorPanel":rect(self.topPanel.frame),
            @"keyboardPanel":rect(self.keyboard.frame),@"hardwareKeyboard":@(self.keyboard.hardwareLayout),@"phoneLandscape":@(phoneLandscape),
            @"hingeAvailable":@(duoHardware),@"hingePartial":@(hingeDuo),@"manualDuo":@(manualDuo),@"statusBarHidden":@(self.prefersStatusBarHidden),
            @"occlusions":occlusions,@"fullScreen":@(fullScreen),
            @"monitorScreen":rect([self.monitor.superview convertRect:self.monitor.frame toView:self.view])};
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
            writeToURL:area(NSDocumentDirectory,@"layout-report.json") atomically:YES];
    }
#endif
}
- (void)toggleFullScreen {
    if(fetching || self.presentedViewController) return;
    [self releaseKeys];fullScreen=!fullScreen;
    if(!fullScreen) fullscreenMenuPaused=NO;
#ifdef PC98PLAYER_TESTING
    [self.audioProbe event:fullScreen?@"fullscreen-enter":@"fullscreen-exit"];
#endif
    self.topPanel.hidden=fullScreen;self.keyboard.hidden=fullScreen;
    self.toolbar.hidden=fullScreen;self.status.hidden=fullScreen;
    self.view.backgroundColor=fullScreen?UIColor.blackColor:PC98Plastic(.84);
    self.monitor.layer.cornerRadius=fullScreen?0:4;
    [self.monitor removeFromSuperview];
    if(fullScreen) [self.view addSubview:self.monitor];else [self.topPanel addSubview:self.monitor];
    [self setNeedsStatusBarAppearanceUpdate];[self setNeedsUpdateOfHomeIndicatorAutoHidden];
    [self.view setNeedsLayout];[self.view layoutIfNeeded];
}
- (void)message:(NSString*)message {
    UIAlertController* a=[UIAlertController alertControllerWithTitle:@"PC98PLAYER" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil];
}
- (void)updateScan:(int)scan {
    if(!player || paused) return;
    BOOL down=touchKeys.count(scan)>0;
    for(NSInteger u:physicalKeys) if(pc98_scan_from_hid(u)==scan) down=YES;
    machine_key(player->m,(uint8_t)scan,down);
}
- (void)releaseKeys {
    [self.keyboard releaseAll]; touchKeys.clear(); physicalKeys.clear(); mouseButtons=0;
    if(player) { for(int i=0;i<128;++i) if(player->m->kb_down[i]) machine_key(player->m,i,false); machine_mouse(player->m,0,0,0); }
}
- (void)pressesBegan:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
    if(fullScreen) return;
    NSMutableSet* unhandled=[presses mutableCopy];
    for(UIPress* p in presses) if(p.key) { int sc=pc98_scan_from_hid(p.key.keyCode); if(sc>=0) { physicalKeys.insert(p.key.keyCode); [self updateScan:sc]; [unhandled removeObject:p]; } }
    if(unhandled.count) [super pressesBegan:unhandled withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
    for(UIPress* p in presses) if(p.key) { physicalKeys.erase(p.key.keyCode); int sc=pc98_scan_from_hid(p.key.keyCode); if(sc>=0) [self updateScan:sc]; }
}
- (void)pressesCancelled:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event { [self releaseKeys]; }
- (void)moveMouse:(UIPanGestureRecognizer*)pan {
    CGPoint delta=[pan translationInView:self.monitor]; [pan setTranslation:CGPointZero inView:self.monitor];
    CGFloat scale=MIN(self.monitor.bounds.size.width/640,self.monitor.bounds.size.height/400);
    if(player && !paused && scale>0) machine_mouse(player->m,(int)(delta.x/scale),(int)(delta.y/scale),mouseButtons);
}
- (void)click:(int)button {
    if(!player || paused) return;
    machine_mouse(player->m,0,0,button);
    __weak PlayerController* weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ PlayerController* s=weak; if(s && s->player) machine_mouse(s->player->m,0,0,0); });
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    if([gesture isKindOfClass:UILongPressGestureRecognizer.class])
        return fullScreen && player && !fetching && !player->m->quit && !self.presentedViewController;
    return YES;
}
- (void)pauseFromFullscreenMenu {
    if(!fullScreen || !player || fetching || player->m->quit) return;
    if(!paused) [self togglePause];
    fullscreenMenuPaused=YES;
    self.status.text=@"一時停止 — 画面をタップして再開";
}
- (UIAlertController*)fullscreenMenu {
    UIAlertController* menu=[UIAlertController alertControllerWithTitle:@"操作" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak PlayerController* weak=self;
    [menu addAction:[UIAlertAction actionWithTitle:@"一時停止" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [weak pauseFromFullscreenMenu];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"リセット" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        PlayerController* s=weak;if(!s) return;
        [s dismissViewControllerAnimated:YES completion:^{ [weak resetGame]; }];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    return menu;
}
- (void)fullscreenLongPress:(UILongPressGestureRecognizer*)gesture {
    if(gesture.state!=UIGestureRecognizerStateBegan || ![self gestureRecognizerShouldBegin:gesture]) return;
    [self releaseKeys];
    UIAlertController* menu=[self fullscreenMenu];
    if(menu.popoverPresentationController) {
        CGPoint point=[gesture locationInView:self.monitor];
        menu.popoverPresentationController.sourceView=self.monitor;
        menu.popoverPresentationController.sourceRect=CGRectMake(point.x,point.y,1,1);
    }
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)leftClick:(id)sender {
    if(fullScreen && fullscreenMenuPaused && paused) { [self togglePause];return; }
    [self click:1];
}
- (void)rightClick { [self click:2]; }
- (void)tick:(CADisplayLink*)link {
    self.topPanel.playbackState=(!player || player->m->quit)?PC98PlaybackStateInactive:paused?PC98PlaybackStatePaused:PC98PlaybackStateRunning;
    if(!player || paused || fetching) return;
    constexpr double seconds=(double)FRAME_TICKS/MASTER_CLOCK;
    double now=CACurrentMediaTime(); if(now-nextFrame>seconds*3) nextFrame=now;
    [self.keyboard repeatHeldKeys];
    int frames=0;BOOL audioClock=audio.queue!=nullptr;
    while((audioClock?audio.needsFrames():now>=nextFrame) && frames++<(audioClock?8:3)) {
        player->run_frame();
#ifdef PC98PLAYER_TESTING
        [self.audioProbe appendReference:player->audio rate:player->ps.sample_rate];
#endif
        audio.push(player->audio); nextFrame+=seconds;
        if(player->m->quit) { paused=YES; [self releaseKeys]; audio.close(); self.status.text=player->m->quit==2 ? text(player->m->status) : @"実行が終了しました"; break; }
    }
    if(audioClock) nextFrame=now;
    self.monitor.image=frameImage(player.get());
}
- (void)stopGame {
    fullscreenMenuPaused=NO; paused=YES; [self releaseKeys]; audio.close();
    if(player) { player->shutdown(); player.reset(); }
    hostfs::set_overlay("","");
}
- (void)togglePause {
    if(!player || fetching || player->m->quit) return;
    [self releaseKeys]; paused=!paused;
    if(!paused) fullscreenMenuPaused=NO;
#ifdef PC98PLAYER_TESTING
    [self.audioProbe event:paused?@"pause":@"resume"];
#endif
    if(paused) { audio.pause(); self.status.text=@"一時停止"; }
    else { [self startAudio]; nextFrame=CACurrentMediaTime(); self.status.text=@"実行中"; }
}
- (void)startAudio {
    NSError* error=nil; AVAudioSession* session=AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback error:&error]; [session setActive:YES error:&error];
    if(error || !audio.open(player->ps.sample_rate)) self.status.text=@"音声を開始できませんでした（映像のみ）";
}
- (void)suspend {
    [self releaseKeys]; paused=YES; audio.pause();
    self.status.text=@"一時停止 — ▶︎で再開";
}
- (void)openFolder {
    if(fetching) return;
    pickerPreviousPause=paused; [self suspend];
    UIDocumentPickerViewController* picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate=self; picker.allowsMultipleSelection=NO;
    picker.directoryURL=area(NSDocumentDirectory,@"Games");
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
    paused=pickerPreviousPause; if(player && !paused) [self startAudio]; nextFrame=CACurrentMediaTime();
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if(urls.count) [self cacheSource:urls.firstObject];
}
- (void)cacheSource:(NSURL*)source {
    if(fetching) return;
    fetching=YES; [self suspend]; [self.spinner startAnimating]; self.status.text=@"ゲームデータをキャッシュしています…";
    BOOL scoped=[source startAccessingSecurityScopedResource];
    NSError* bookmarkError=nil;
    [GameLibrary rememberURL:source name:source.lastPathComponent error:&bookmarkError];
    NSString* identifier=gameID(source);
    NSURL* destination=area(NSCachesDirectory,[@"PC98Games/" stringByAppendingString:identifier]);
    __weak PlayerController* weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            NSError* error=nil;
            NSFileManager* manager=NSFileManager.defaultManager;
            if(![GameLibrary isUsableCacheAtURL:destination]) {
                // Keep invalid legacy caches recoverable; game saves live in a separate directory.
                if([manager fileExistsAtPath:destination.path]) {
                    NSURL* rejected=area(NSCachesDirectory,@"PC98Rejected");
                    [manager createDirectoryAtURL:rejected withIntermediateDirectories:YES attributes:nil error:&error];
                    if(!error) [manager moveItemAtURL:destination toURL:[rejected URLByAppendingPathComponent:NSUUID.UUID.UUIDString] error:&error];
                }
                NSURL* temporary=[destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
                if(!error) [manager createDirectoryAtURL:temporary.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
                BOOL copied=NO;
                if(!error) copied=[GameLibrary copyFolderFromURL:source toURL:temporary error:&error];
                if(!copied && !error) error=[NSError errorWithDomain:@"PC98GameCache" code:6 userInfo:@{NSLocalizedDescriptionKey:@"NASからゲームを取得できませんでした。"}];
                if(copied) {
                    if(![GameLibrary isUsableCacheAtURL:temporary]) error=[NSError errorWithDomain:@"PC98GameCache" code:1 userInfo:@{NSLocalizedDescriptionKey:@"ゲームの中身を取得できませんでした。Games内の作品フォルダーを選び直してください。NASのファイル一覧が表示されるまで待ってから「開く」を押してください。"}];
                    if(!error) [manager moveItemAtURL:temporary toURL:destination error:&error];
                }
                if(error) [manager removeItemAtURL:temporary error:nil];
            }
            if(scoped) [source stopAccessingSecurityScopedResource];
            dispatch_async(dispatch_get_main_queue(),^{
                PlayerController* s=weak; if(!s) return;
                s->fetching=NO; [s.spinner stopAnimating];
#if defined(PC98PLAYER_TESTING)
                NSDictionary* report=@{@"sourceName":source.lastPathComponent ?: @"", @"scoped":@(scoped), @"identifier":identifier, @"error":error.localizedDescription ?: @"", @"domain":error.domain ?: @"", @"code":@(error.code), @"usableCache":@([GameLibrary isUsableCacheAtURL:destination])};
                [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:area(NSDocumentDirectory,@"cache-import-report.json") atomically:YES];
#endif
                if(error) { s.status.text=error.localizedDescription; [s message:error.localizedDescription]; }
                else [s openCache:destination identifier:identifier];
            });
        }
    });
}
- (void)openCache:(NSURL*)cache identifier:(NSString*)identifier {
    [self stopGame]; self.currentCache=cache; self.currentID=identifier;
    NSString* saves=[@"PC98Saves/" stringByAppendingString:identifier];
    NSURL* saved=area(NSApplicationSupportDirectory,[saves stringByAppendingPathComponent:@"files"]);
    NSError* error=nil;
    if(![NSFileManager.defaultManager createDirectoryAtURL:saved withIntermediateDirectories:YES attributes:nil error:&error]) { [self message:error.localizedDescription]; return; }
    hostfs::set_overlay(cache.fileSystemRepresentation,saved.fileSystemRepresentation);
    Ini ini; ini.load([[cache URLByAppendingPathComponent:@"PC98PLAYER.INI"] fileSystemRepresentation]);
    NSString* configured=text(ini.get("PC98PLAYER.ROOT"));
    NSURL* root=cache;
    if(configured.length) {
        configured=[configured stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        root=[cache URLByAppendingPathComponent:configured isDirectory:YES].URLByStandardizingPath;
        if(configured.isAbsolutePath || ![root.path hasPrefix:[cache.path stringByAppendingString:@"/"]]) {
            [self message:@"iOSではRoot=にゲームフォルダ内の相対パスを指定してください。"]; return;
        }
    }
    PlayerSettings ps; player_settings_from_ini(ini,root.fileSystemRepresentation,&ps);
    NSNumber* sound=[NSUserDefaults.standardUserDefaults objectForKey:@"PC98SoundBoard"];
    NSNumber* colors=[NSUserDefaults.standardUserDefaults objectForKey:@"PC98VideoColors"];
    if(sound) ps.cfg.sound_board=sound.integerValue==26?26:86;
    if(colors) ps.cfg.video_colors=colors.integerValue==256?256:16;
    ps.cfg.midi=0; ps.cfg.trace=0; ps.sample_rate=std::clamp(ps.sample_rate,8000,192000);
    if(ps.cfg.start.empty() && !ps.cfg.boot_fd) { [self chooseProgram:root settings:ps]; return; }
    [self launchSettings:ps];
}
- (void)chooseProgram:(NSURL*)root settings:(PlayerSettings)settings {
    NSMutableArray* programs=[NSMutableArray new];
    NSDirectoryEnumerator* e=[NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for(NSURL* url in e) {
        if([@[@"bat",@"com",@"exe"] containsObject:url.pathExtension.lowercaseString]) {
            NSNumber* regular=nil; [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            if(regular.boolValue) [programs addObject:[url.path substringFromIndex:root.path.length+1]];
        }
    }
    if(!programs.count) { [self message:@"起動ファイルがありません。ゲームフォルダとINIのStart=を確認してください。"]; return; }
    [programs sortUsingSelector:@selector(localizedStandardCompare:)];
    FileChooser* chooser=[FileChooser new]; chooser.title=@"起動するプログラム"; chooser.paths=programs;
    __weak PlayerController* weak=self;
    chooser.selected=^(NSString* selected) { PlayerSettings s=settings; s.cfg.start=hostfs::to_sjis(selected.UTF8String); [weak launchSettings:s]; };
    UINavigationController* navigation=[[UINavigationController alloc] initWithRootViewController:chooser];
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)launchSettings:(PlayerSettings)settings {
    player=std::make_unique<Player>(); mac_install_font(settings.font_name,settings.font_shift); std::string error;
    if(!player->init(settings,&error)) { [self stopGame]; [self message:text(error)]; return; }
    paused=NO; nextFrame=CACurrentMediaTime(); self.status.text=@"実行中 — ゲーム本体はキャッシュ、保存データは別領域";
    [self startAudio]; [self becomeFirstResponder];
    NSString* warnings=@"";
    for(auto* e:{&player->floppy_error,&player->cd_error,&player->rhythm_error}) if(!e->empty()) warnings=[warnings stringByAppendingFormat:@"%@\n",text(*e)];
    if(warnings.length) [self message:warnings];
}
- (void)slots:(BOOL)load {
    if(!player || fetching) return;
    [self releaseKeys]; audio.clear();
    UIAlertController* menu=[UIAlertController alertControllerWithTitle:load?@"ステート読込":@"ステート保存" message:nil preferredStyle:UIAlertControllerStyleAlert];
    __weak PlayerController* weak=self;
    for(int slot=0;slot<STATE_SLOTS;++slot) [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"スロット %d",slot+1] style:UIAlertActionStyleDefault handler:^(UIAlertAction* a) {
        PlayerController* s=weak; if(!s || !s->player) return;
        std::string error; BOOL ok=load?s->player->load_state(slot,&error):s->player->save_state(slot,&error);
        [s releaseKeys]; s->audio.clear(); s->nextFrame=CACurrentMediaTime();
        if(!ok) [s message:text(error)]; else s.status.text=load?@"ステートを読み込みました":@"ステートを保存しました";
        if(s->player) s.monitor.image=frameImage(s->player.get());
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)saveSlot { [self slots:NO]; }
- (void)loadSlot { [self slots:YES]; }
- (void)showOptions {
    if(fetching || self.presentedViewController) return;
    BOOL previousPause=paused;[self suspend];
    GameOptionsController* options=[[GameOptionsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    options.soundBoard=player?player->m->cfg.sound_board:([NSUserDefaults.standardUserDefaults objectForKey:@"PC98SoundBoard"]? [NSUserDefaults.standardUserDefaults integerForKey:@"PC98SoundBoard"]:86);
    options.videoColors=player?player->m->cfg.video_colors:([NSUserDefaults.standardUserDefaults objectForKey:@"PC98VideoColors"]? [NSUserDefaults.standardUserDefaults integerForKey:@"PC98VideoColors"]:16);
    __weak PlayerController* weak=self;
    options.manualDuo=manualDuo;
    options.cancelled=^{ PlayerController* s=weak;if(!s) return;s->paused=previousPause;if(s->player && !s->paused) [s startAudio];s->nextFrame=CACurrentMediaTime(); };
    options.applied=^(NSInteger sound,NSInteger colors,BOOL duo) {
        PlayerController* s=weak;if(!s) return;
        BOOL restart=s->player && (s->player->m->cfg.sound_board!=sound || s->player->m->cfg.video_colors!=colors);
        [s releaseKeys];s->manualDuo=duo;
        [NSUserDefaults.standardUserDefaults setBool:duo forKey:@"PC98ManualDuo"];
        [s setNeedsUpdateOfSupportedInterfaceOrientations];[s setNeedsStatusBarAppearanceUpdate];[s.view setNeedsLayout];
        [NSUserDefaults.standardUserDefaults setInteger:sound forKey:@"PC98SoundBoard"];
        [NSUserDefaults.standardUserDefaults setInteger:colors forKey:@"PC98VideoColors"];
        if(restart && s.currentCache && s.currentID) [s openCache:s.currentCache identifier:s.currentID];
        else if(s->player) { s->paused=previousPause;if(!s->paused) [s startAudio];s->nextFrame=CACurrentMediaTime(); }
        else s.status.text=@"オプションを保存しました。ゲームフォルダーを選択してください。";
    };
    UINavigationController* nav=[[UINavigationController alloc] initWithRootViewController:options];nav.modalInPresentation=YES;
    if(nav.sheetPresentationController) nav.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.largeDetent];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)resetGame {
    if(!player || fetching || self.presentedViewController || !self.currentCache || !self.currentID) return;
    BOOL previousPause=paused;[self suspend];
    UIAlertController* alert=[UIAlertController alertControllerWithTitle:@"ゲームをリセット" message:@"現在のゲームを最初から起動し直します。未保存の進行は失われます。保存済みデータは残ります。" preferredStyle:UIAlertControllerStyleAlert];
    __weak PlayerController* weak=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action) {
        PlayerController* s=weak;if(!s) return;s->paused=previousPause;if(s->player && !s->paused) [s startAudio];s->nextFrame=CACurrentMediaTime();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"リセット" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        PlayerController* s=weak;if(s) [s openCache:s.currentCache identifier:s.currentID];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showLibrary {
    if(fetching) return;
    UIAlertController* menu=[UIAlertController alertControllerWithTitle:@"ゲームデータの場所" message:@"「開く」から、このiPhone内／ファイルで接続したNASのフォルダを選べます。元データは書き換えません。" preferredStyle:UIAlertControllerStyleAlert];
    __weak PlayerController* weak=self;
    for(NSDictionary* entry in GameLibrary.entries) [menu addAction:[UIAlertAction actionWithTitle:entry[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction* a) {
        NSURL* original=[NSURL fileURLWithPath:entry[@"path"] isDirectory:YES];
        NSString* identifier=gameID(original);
        NSURL* cached=area(NSCachesDirectory,[@"PC98Games/" stringByAppendingString:identifier]);
        if([GameLibrary isUsableCacheAtURL:cached]) { [weak openCache:cached identifier:identifier]; return; }
        NSError* error=nil; NSURL* source=[GameLibrary resolveEntry:entry error:&error];
        if(source) [weak cacheSource:source]; else [weak message:@"場所へのアクセスを復元できません。「開く」で再選択してください。"];
    }]];
    // Also expose complete caches staged for device testing; the originals stay on Mac/NAS.
    NSMutableSet<NSString*>* registered=[NSMutableSet new];
    for(NSDictionary* entry in GameLibrary.entries)
        [registered addObject:gameID([NSURL fileURLWithPath:entry[@"path"] isDirectory:YES])];
    NSArray<NSURL*>* caches=[NSFileManager.defaultManager contentsOfDirectoryAtURL:area(NSCachesDirectory,@"PC98Games")
        includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    for(NSURL* cache in [caches sortedArrayUsingComparator:^NSComparisonResult(NSURL* a,NSURL* b) { return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent]; }]) {
        NSString* identifier=cache.lastPathComponent; NSNumber* directory=nil;
        [cache getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if(!directory.boolValue || [identifier isEqualToString:@"demo"] || [registered containsObject:identifier]) continue;
        NSURL* iniURL=[cache URLByAppendingPathComponent:@"PC98PLAYER.INI"];
        if(![NSFileManager.defaultManager fileExistsAtPath:iniURL.path]) continue;
        Ini ini; ini.load(iniURL.fileSystemRepresentation);
        NSString* title=text(ini.get("PC98PLAYER.TITLE"));
        if(!title.length) title=identifier;
        [menu addAction:[UIAlertAction actionWithTitle:[title stringByAppendingString:@"（キャッシュ）"] style:UIAlertActionStyleDefault
            handler:^(UIAlertAction* a) { [weak openCache:cache identifier:identifier]; }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"オリジナルDOSデモ" style:UIAlertActionStyleDefault handler:^(UIAlertAction* a) { [weak demo]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"ゲーム本体のキャッシュを消去" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* a) { [weak clearCache]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)clearCache {
    [self stopGame]; self.monitor.image=nil;
    NSError* error=nil; NSURL* root=area(NSCachesDirectory,@"PC98Games");
    if([NSFileManager.defaultManager fileExistsAtPath:root.path]) [NSFileManager.defaultManager removeItemAtURL:root error:&error];
    self.status.text=error?error.localizedDescription:@"本体キャッシュを消去しました。保存データは保持しています。";
}
- (void)demo {
    if(fetching) return;
    NSURL* root=area(NSCachesDirectory,@"PC98Games/demo");
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    const uint8_t code[]={0xBA,0x13,0x01,0xB4,0x09,0xCD,0x21,0xB4,0x08,0xCD,0x21,0xB4,0x02,0x88,0xC2,0xCD,0x21,0xEB,0xF4};
    NSMutableData* com=[NSMutableData dataWithBytes:code length:sizeof(code)];
    std::string message=hostfs::to_sjis("PC98PLAYER for iOS\r\n\r\n日本語 / PC-98 キーボード\r\n\r\nTouch keys below. SHIFT / CTRL / GRPH latch.\r\n$");
    [com appendBytes:message.data() length:message.size()]; [com writeToURL:[root URLByAppendingPathComponent:@"DEMO.COM"] atomically:YES];
    [@"[PC98PLAYER]\nStart=DEMO.COM\nMIDI=0\nRhythmROM=0\n" writeToURL:[root URLByAppendingPathComponent:@"PC98PLAYER.INI"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self openCache:root identifier:@"demo"];
}
#ifdef PC98PLAYER_TESTING
- (void)startAudioProbe:(NSString*)label {
    self.audioProbe=[[AudioCaptureProbe alloc] initWithDirectory:area(NSDocumentDirectory,[@"audio-probe-" stringByAppendingString:label])];
    __weak PlayerController* weak=self;
    [self.audioProbe start:^(NSError* error) {
        PlayerController* s=weak;if(!s) return;
        if(error) { [s message:error.localizedDescription];return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            PlayerController* s=weak;if(!s) return;
            if(s->paused && s->player) [s togglePause];
            [s.audioProbe event:@"measurement-start"];
            if([label isEqualToString:@"rotation"]) {
                s.status.text=@"録音中：縦・横へ回転してください";
                NSURL* stopFlag=area(NSDocumentDirectory,@"audio-probe-rotation/stop.flag");
                [NSFileManager.defaultManager removeItemAtURL:stopFlag error:nil];
                double deadline=CACurrentMediaTime()+180;
                [NSTimer scheduledTimerWithTimeInterval:.25 repeats:YES block:^(NSTimer* timer) {
                    PlayerController* s=weak;
                    if(!s) { [timer invalidate];return; }
                    if(CACurrentMediaTime()>=deadline || [NSFileManager.defaultManager fileExistsAtPath:stopFlag.path]) {
                        [timer invalidate];[s.audioProbe stop:^{ s.status.text=@"回転時の音声録音完了"; }];
                    }
                }];
                return;
            }
            const double times[]={2.317,3.117,5.231,6.031,8.113,8.913};
            for(int i=0;i<6;++i) {
                BOOL targetPause=(i%2)==0;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(times[i]*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                    PlayerController* s=weak;if(s && s->paused!=targetPause) [s togglePause];
                });
            }
            for(double time:{10.1,11.2}) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(time*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                PlayerController* s=weak;if(!s) return;if(s->paused) [s togglePause];[s toggleFullScreen];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,14*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                PlayerController* s=weak;if(s) [s.audioProbe stop:^{ s.status.text=@"音声波形の測定完了"; }];
            });
        });
    }];
}
- (void)smokeTest {
    NSMutableDictionary* result=[NSMutableDictionary new];
    [self suspend]; paused=NO;
    for(int i=0;i<8;++i) player->run_frame();
    result[@"touchKeyDispatch"]=@([self.keyboard tapScanForTesting:29]); // A key, plain 'a'
    for(int i=0;i<4;++i) player->run_frame();
    [self.keyboard tapScanForTesting:0x70];
    result[@"shiftLatched"]=@(player->m->kb_down[0x70]!=0);
    [self.keyboard tapScanForTesting:29];
    for(int i=0;i<4;++i) player->run_frame();
    [self.keyboard tapScanForTesting:0x70];
    result[@"shiftReleased"]=@(player->m->kb_down[0x70]==0);
    bool lowercase=false,uppercase=false;
    for(int i=0;i<2000;++i) { if(player->m->tvram[i*2]=='a') lowercase=true; if(player->m->tvram[i*2]=='A') uppercase=true; }
    result[@"guestLowercase"]=@(lowercase); result[@"guestUppercase"]=@(uppercase);
    bool vfKeys=true;
    for(int scan=0x52;scan<=0x56;++scan) {
        size_t queued=player->m->kb_queue.size();
        vfKeys &= [self.keyboard tapScanForTesting:scan];
        vfKeys &= player->m->kb_queue.size()==queued+2 && !player->m->kb_down[scan];
        if(player->m->kb_queue.size()==queued+2)
            vfKeys &= player->m->kb_queue[queued]==scan && player->m->kb_queue[queued+1]==(scan|0x80);
    }
    result[@"vfKeysMakeBreak"]=@(vfKeys);
    size_t beforeReturn=player->m->kb_queue.size();
    bool joinedReturn=[self.keyboard tapReturnSectionsForTesting];
    joinedReturn &= player->m->kb_queue.size()==beforeReturn+6 && !player->m->kb_down[28];
    if(player->m->kb_queue.size()==beforeReturn+6)
        for(size_t i=0;i<6;++i) joinedReturn &= player->m->kb_queue[beforeReturn+i]==(i%2 ? 0x9C : 0x1C);
    result[@"joinedReturnInput"]=@(joinedReturn);
    [self.keyboard tapScanForTesting:0x74]; [self.keyboard tapScanForTesting:0x73];
    result[@"ctrlAndGrphLatched"]=@(player->m->kb_down[0x74] && player->m->kb_down[0x73]);
    [self releaseKeys];
    result[@"modifiersReleased"]=@(!player->m->kb_down[0x70] && !player->m->kb_down[0x74] && !player->m->kb_down[0x73]);
    bool controls=[self.keyboard pressScansForTesting:@[@31,@0x74,@0x73]];
    controls &= player->m->kb_down[31] && player->m->kb_down[0x74] && player->m->kb_down[0x73];
    [self.keyboard releaseScanForTesting:0x74 cancelled:NO];
    controls &= !player->m->kb_down[0x74] && player->m->kb_down[0x73] && player->m->kb_down[31];
    [self.keyboard releaseScanForTesting:31 cancelled:NO];
    [self.keyboard releaseScanForTesting:0x73 cancelled:NO];
    result[@"heldCtrlGrphChord"]=@(controls && !player->m->kb_down[31] && !player->m->kb_down[0x73]);
    size_t beforeChord=player->m->kb_queue.size();
    bool chord=[self.keyboard pressScansForTesting:@[@29,@0x70]];
    chord &= player->m->kb_down[29] && player->m->kb_down[0x70];
    chord &= player->m->kb_queue.size()==beforeChord+2;
    if(player->m->kb_queue.size()==beforeChord+2)
        chord &= player->m->kb_queue[beforeChord]==0x70 && player->m->kb_queue[beforeChord+1]==29;
    [self.keyboard releaseScanForTesting:29 cancelled:NO];
    chord &= !player->m->kb_down[29] && player->m->kb_down[0x70];
    [self.keyboard releaseScanForTesting:0x70 cancelled:NO];
    result[@"heldShiftChord"]=@(chord && !player->m->kb_down[0x70]);
    bool overlap=[self.keyboard pressScansForTesting:@[@0x3A,@0x3B,@0x34]];
    overlap &= player->m->kb_down[0x3A] && player->m->kb_down[0x3B] && player->m->kb_down[0x34];
    [self.keyboard releaseScanForTesting:0x3B cancelled:NO];
    overlap &= player->m->kb_down[0x3A] && !player->m->kb_down[0x3B] && player->m->kb_down[0x34];
    [self.keyboard releaseScanForTesting:0x3A cancelled:NO];
    [self.keyboard releaseScanForTesting:0x34 cancelled:NO];
    result[@"threeKeyOverlap"]=@(overlap && !player->m->kb_down[0x3A] && !player->m->kb_down[0x34]);
    [self.keyboard pressScansForTesting:@[@29,@29]];
    [self.keyboard releaseScanForTesting:29 cancelled:NO];
    bool shared=player->m->kb_down[29];
    [self.keyboard releaseScanForTesting:29 cancelled:NO];
    result[@"sharedKeyTouches"]=@(shared && !player->m->kb_down[29]);
    [self.keyboard pressScansForTesting:@[@0x70]];
    [self.keyboard releaseScanForTesting:0x70 cancelled:YES];
    result[@"cancelledModifierReleased"]=@(!player->m->kb_down[0x70]);
    [self releaseKeys];
    std::string error; bool saved=player->save_state(7,&error);
    uint8_t previous=player->m->ram[0x90000]; player->m->ram[0x90000]=previous^0xFF;
    bool loaded=player->load_state(7,&error);
    result[@"stateRoundtrip"]=@(saved && loaded && player->m->ram[0x90000]==previous);
    manualDuo=NO; hingeDuo=NO; duoHardware=NO; [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    result[@"phoneRotationSupported"]=@((self.supportedInterfaceOrientations & UIInterfaceOrientationMaskPortrait) && (self.supportedInterfaceOrientations & UIInterfaceOrientationMaskLandscapeLeft) && (self.supportedInterfaceOrientations & UIInterfaceOrientationMaskLandscapeRight));
    bool landscape=true;
    for(CGRect safe : {CGRectMake(59,0,814,409),CGRectMake(59,0,734,369),CGRectMake(0,0,608,354)}) {
        auto panels=phoneLandscapePanels(safe);
        PC98MonitorCabinet* probe=[[PC98MonitorCabinet alloc] initWithFrame:panels[0]];
        CGRect screen=[probe screenFrame];
        landscape &= CGRectContainsRect(safe,panels[0]) && CGRectContainsRect(safe,panels[1]) && CGRectGetMaxX(panels[0])<CGRectGetMinX(panels[1]);
        landscape &= CGRectContainsRect(probe.bounds,screen) && fabs(screen.size.width/screen.size.height-1.6)<.001 && panels[1].size.width>panels[0].size.width;
    }
    result[@"phoneLandscapePanels"]=@(landscape);
    result[@"phoneKeyboardBelowMonitor"]=@(CGRectGetMinY(self.keyboard.frame)>CGRectGetMaxY(self.topPanel.frame));
    UIGraphicsImageRenderer* portraitRenderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.view.bounds];
    self.monitor.image=frameImage(player.get());
    UIImage* portrait=[portraitRenderer imageWithActions:^(UIGraphicsImageRendererContext* context) { [self.view.layer renderInContext:context.CGContext]; }];
    [UIImagePNGRepresentation(portrait) writeToURL:area(NSDocumentDirectory,@"portrait-smoke.png") atomically:YES];
    BOOL hasTwoFingerTap=NO,hasSingleFingerDoubleTap=NO;
    for(UIGestureRecognizer* gesture in self.monitor.gestureRecognizers) if([gesture isKindOfClass:UITapGestureRecognizer.class]) {
        UITapGestureRecognizer* tap=(UITapGestureRecognizer*)gesture;
        hasTwoFingerTap |= tap.numberOfTouchesRequired==2 && tap.numberOfTapsRequired==1;
        hasSingleFingerDoubleTap |= tap.numberOfTouchesRequired==1 && tap.numberOfTapsRequired==2;
    }
    result[@"monitorTwoFingerGesture"]=@(self.monitor.multipleTouchEnabled && hasTwoFingerTap && hasSingleFingerDoubleTap);
    [self rightClick];result[@"monitorRightClick"]=@(player->m->mouse.buttons==2);[self releaseKeys];
    UILongPressGestureRecognizer* hold=nil;
    for(UIGestureRecognizer* gesture in self.monitor.gestureRecognizers)
        if([gesture isKindOfClass:UILongPressGestureRecognizer.class]) hold=(UILongPressGestureRecognizer*)gesture;
    result[@"normalViewRejectsLongPress"]=@(hold && ![self gestureRecognizerShouldBegin:hold]);
    CGRect previousMonitor=self.monitor.frame;
    [self.keyboard pressScansForTesting:@[@0x70,@29]];
    [self toggleFullScreen];
    result[@"fullscreenHidesControls"]=@(fullScreen && self.topPanel.hidden && self.keyboard.hidden && self.toolbar.hidden && self.status.hidden && self.monitor.superview==self.view && self.prefersStatusBarHidden);
    CGRect fullscreenSafe=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);
    result[@"fullscreenAspectFit"]=@(CGRectContainsRect(fullscreenSafe,self.monitor.frame) && fabs(self.monitor.frame.size.width/self.monitor.frame.size.height-1.6)<.001);
    result[@"fullscreenReleasesKeys"]=@(!player->m->kb_down[0x70] && !player->m->kb_down[29]);
    [self rightClick];result[@"fullscreenRightClick"]=@(player->m->mouse.buttons==2);[self releaseKeys];
    result[@"fullscreenAcceptsLongPress"]=@(hold && [self gestureRecognizerShouldBegin:hold]);
    UIAlertController* menu=[self fullscreenMenu];
    result[@"fullscreenMenuActions"]=@(menu.actions.count==3 && [menu.actions[0].title isEqualToString:@"一時停止"] && [menu.actions[1].title isEqualToString:@"リセット"]);
    [self pauseFromFullscreenMenu];
    result[@"fullscreenMenuPauses"]=@(paused && fullscreenMenuPaused && audio.paused);
    [self rightClick];
    result[@"rightClickDoesNotResume"]=@(paused && player->m->mouse.buttons==0);
    [self leftClick:nil];
    result[@"fullscreenTapResumesWithoutGuestClick"]=@(!paused && !fullscreenMenuPaused && player->m->mouse.buttons==0);
    [self leftClick:nil];
    result[@"fullscreenNextTapClicks"]=@(player->m->mouse.buttons==1);[self releaseKeys];
    [self pauseFromFullscreenMenu];
    [self toggleFullScreen];
    [self leftClick:nil];
    result[@"normalViewDoesNotTapResume"]=@(paused && !fullscreenMenuPaused);
    [self togglePause];
    result[@"fullscreenRestoresLayout"]=@(!fullScreen && !self.topPanel.hidden && !self.keyboard.hidden && !self.toolbar.hidden && !self.status.hidden && self.monitor.superview==self.topPanel && CGRectEqualToRect(previousMonitor,self.monitor.frame));
    manualDuo=YES; [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    CGRect camera=CGRectMake(540,0,129,82), panel=CGRectMake(0,0,669,448);
    CGRect clear=monitorAvoiding(panel,camera);
    result[@"monitorAvoidsCamera"]=@(CGRectContainsRect(panel,clear) && !CGRectIntersectsRect(clear,camera) && clear.size.width>0 && clear.size.height>0 && CGRectEqualToRect(monitorAvoiding(panel,CGRectMake(0,600,80,80)),panel));
    result[@"duoPhysicalKeyboard"]=@([self.keyboard hardwareLayoutForTesting]);
    CGRect monitor=[self.topPanel screenFrame];
    CGFloat usableMonitorHeight=MIN(self.topPanel.bounds.size.height-48,(self.topPanel.bounds.size.width-16)/1.6);
    result[@"duoLargeMonitor"]=@(CGRectContainsRect(self.topPanel.bounds,monitor) && monitor.size.height>=usableMonitorHeight*.9 && fabs(monitor.size.width/monitor.size.height-1.6)<.001);
    bool adaptive=true;
    for(CGSize size : {CGSizeMake(400,360),CGSizeMake(900,300),CGSizeMake(669,413.5),CGSizeMake(855,280.45)}) {
        PC98Keyboard* probe=[[PC98Keyboard alloc] initWithFrame:CGRectMake(0,0,size.width,size.height)];
        probe.hardwareLayout=YES;
        adaptive &= [probe hardwareLayoutForTesting];
    }
    result[@"duoAdaptiveSizing"]=@(adaptive);
    CGFloat mid=CGRectGetMidY(self.view.bounds);
    result[@"duoMonitorAboveFold"]=@(CGRectGetMaxY(self.topPanel.frame)<mid);
    result[@"duoKeyboardBelowFold"]=@(CGRectGetMinY(self.keyboard.frame)>mid);
    result[@"hardwareArrows"]=@(pc98_scan_from_hid(82)==0x3A && pc98_scan_from_hid(80)==0x3B);
    paused=YES; audio.close(); self.monitor.image=frameImage(player.get()); self.status.text=@"Duo上下表示・PC98入力・ステート検証完了";
    UIGraphicsImageRenderer* renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.view.bounds];
    UIImage* image=[renderer imageWithActions:^(UIGraphicsImageRendererContext* context) { [self.view.layer renderInContext:context.CGContext]; }];
    [UIImagePNGRepresentation(image) writeToURL:area(NSDocumentDirectory,@"duo-smoke.png") atomically:YES];
    bool success=true; for(NSNumber* value in result.allValues) if(!value.boolValue) success=false;
    result[@"passed"]=@(success);
    NSData* report=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [report writeToURL:area(NSDocumentDirectory,@"smoke-result.json") atomically:YES];
    NSLog(@"PC98 IOS SMOKE %@",success?@"PASS":@"FAIL");
}
#endif
- (void)dealloc { [self.displayLink invalidate]; [self stopGame]; }
@end

@interface PlayerSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow* window;
@property PlayerController* controller;
@end
@implementation PlayerSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.controller=[PlayerController new]; self.window.rootViewController=self.controller; [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene*)scene { [self.controller suspend]; }
@end
@interface PlayerAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation PlayerAppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    extern std::string g_app_dir; g_app_dir=NSBundle.mainBundle.resourcePath.fileSystemRepresentation;
    return YES;
}
@end
int main(int argc,char** argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(PlayerAppDelegate.class)); } }
