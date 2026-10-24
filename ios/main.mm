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

@interface PlayerController : UIViewController <UIDocumentPickerDelegate,UIAdaptivePresentationControllerDelegate> {
    std::unique_ptr<Player> player;
    AudioOut audio;
    double nextFrame;
    BOOL paused, fetching, pickerPreviousPause, manualDuo, hingeDuo, duoHardware;
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
@end
@implementation PlayerController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if(self.traitCollection.userInterfaceIdiom==UIUserInterfaceIdiomPhone && !manualDuo && !hingeDuo && !duoHardware)
        return UIInterfaceOrientationMaskPortrait;
    return UIInterfaceOrientationMaskAllButUpsideDown;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=[UIColor colorWithRed:.20 green:.22 blue:.21 alpha:1]; paused=YES;
    manualDuo=[NSUserDefaults.standardUserDefaults boolForKey:@"PC98ManualDuo"];
    self.topPanel=[PC98MonitorCabinet new]; [self.view addSubview:self.topPanel];
    self.monitor=[UIImageView new]; self.monitor.contentMode=UIViewContentModeScaleAspectFit;
    self.monitor.layer.cornerRadius=4; self.monitor.clipsToBounds=YES; self.monitor.backgroundColor=[UIColor colorWithRed:.035 green:.055 blue:.052 alpha:1]; self.monitor.layer.magnificationFilter=kCAFilterNearest; self.monitor.userInteractionEnabled=YES;
    [self.topPanel addSubview:self.monitor];
    UIPanGestureRecognizer* pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveMouse:)]; [self.monitor addGestureRecognizer:pan];
    UITapGestureRecognizer* tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(leftClick:)]; [self.monitor addGestureRecognizer:tap];
    self.status=[UILabel new]; self.status.text=@"ゲームフォルダを選択してください";
    self.status.textColor=[UIColor colorWithWhite:.24 alpha:1]; self.status.font=[UIFont monospacedSystemFontOfSize:8 weight:UIFontWeightRegular]; self.status.numberOfLines=1; self.status.adjustsFontSizeToFitWidth=YES;
    [self.topPanel addSubview:self.status];
    self.toolbar=[UIStackView new]; self.toolbar.axis=UILayoutConstraintAxisHorizontal; self.toolbar.distribution=UIStackViewDistributionFillEqually; self.toolbar.spacing=3;
    NSArray* titles=@[@"開く",@"場所",@"▶︎ / Ⅱ",@"保存",@"読込",@"表示",@"右クリック"];
    SEL actions[]={@selector(openFolder),@selector(showLibrary),@selector(togglePause),@selector(saveSlot),@selector(loadSlot),@selector(layoutMenu),@selector(rightClick)};
    for(NSUInteger i=0;i<titles.count;++i) { UIButton* b=[UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:titles[i] forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; [b setTitleColor:[UIColor colorWithWhite:.18 alpha:1] forState:UIControlStateNormal]; [b setTitleColor:UIColor.grayColor forState:UIControlStateHighlighted]; b.backgroundColor=PC98Plastic(.87); b.layer.cornerRadius=2; b.layer.borderWidth=1; b.layer.borderColor=PC98Plastic(.55).CGColor; b.layer.shadowColor=UIColor.blackColor.CGColor; b.layer.shadowOffset=CGSizeMake(0,1); b.layer.shadowOpacity=.25; b.layer.shadowRadius=0; b.titleLabel.adjustsFontSizeToFitWidth=YES; [b addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside]; [self.toolbar addArrangedSubview:b]; }
    [self.topPanel addSubview:self.toolbar];
    self.keyboard=[PC98Keyboard new]; __weak PlayerController* weak=self;
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
            if(s->hingeDuo!=duo || s->duoHardware!=hardware) { [s releaseKeys]; s->duoHardware=hardware; s->hingeDuo=duo; [s setNeedsUpdateOfSupportedInterfaceOrientations]; [s.view setNeedsLayout]; }
        }];
        [self.view addInteraction:interaction];
    }
#endif
    if([NSProcessInfo.processInfo.arguments containsObject:@"--demo"]) [self demo];
#ifdef PC98PLAYER_TESTING
    if([NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"]) {
        [self demo];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ [weak smokeTest]; });
    }
#endif
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self becomeFirstResponder]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect safe=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);
    BOOL duo=manualDuo || hingeDuo;
    self.keyboard.hardwareLayout=duo || duoHardware;
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
    CGFloat w=self.topPanel.bounds.size.width,h=self.topPanel.bounds.size.height;
    self.status.frame=[self.topPanel statusFrame]; self.toolbar.frame=[self.topPanel controlsFrame];
    self.monitor.frame=[self.topPanel screenFrame]; self.spinner.center=CGPointMake(w/2,h/2);
    [self.topPanel setNeedsDisplay];
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
- (void)leftClick:(id)sender { [self click:1]; }
- (void)rightClick { [self click:2]; }
- (void)tick:(CADisplayLink*)link {
    if(!player || paused || fetching) return;
    constexpr double seconds=(double)FRAME_TICKS/MASTER_CLOCK;
    double now=CACurrentMediaTime(); if(now-nextFrame>seconds*3) nextFrame=now;
    [self.keyboard repeatHeldKeys];
    int frames=0;
    while(now>=nextFrame && frames++<3) {
        player->run_frame(); audio.push(player->audio); nextFrame+=seconds;
        if(player->m->quit) { paused=YES; [self releaseKeys]; audio.close(); self.status.text=player->m->quit==2 ? text(player->m->status) : @"実行が終了しました"; break; }
    }
    self.monitor.image=frameImage(player.get());
}
- (void)stopGame {
    paused=YES; [self releaseKeys]; audio.close();
    if(player) { player->shutdown(); player.reset(); }
    hostfs::set_overlay("","");
}
- (void)togglePause {
    if(!player || fetching || player->m->quit) return;
    [self releaseKeys]; paused=!paused;
    if(paused) { audio.close(); self.status.text=@"一時停止"; }
    else { [self startAudio]; nextFrame=CACurrentMediaTime(); self.status.text=@"実行中"; }
}
- (void)startAudio {
    NSError* error=nil; AVAudioSession* session=AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback error:&error]; [session setActive:YES error:&error];
    if(error || !audio.open(player->ps.sample_rate)) self.status.text=@"音声を開始できませんでした（映像のみ）";
}
- (void)suspend {
    [self releaseKeys]; paused=YES; audio.close();
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
            if(![manager fileExistsAtPath:destination.path]) {
                NSURL* temporary=[destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
                [manager createDirectoryAtURL:temporary.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
                if(!error) {
                    NSFileCoordinator* coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
                    __block NSError* copyError=nil;
                    [coordinator coordinateReadingItemAtURL:source options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL* readable) {
                        [manager copyItemAtURL:readable toURL:temporary error:&copyError];
                    }];
                    if(copyError) error=copyError;
                    // A complete copy is published atomically; interrupted staging folders are disposable.
                    if(!error) [manager moveItemAtURL:temporary toURL:destination error:&error];
                    if(error) [manager removeItemAtURL:temporary error:nil];
                }
            }
            if(scoped) [source stopAccessingSecurityScopedResource];
            dispatch_async(dispatch_get_main_queue(),^{
                PlayerController* s=weak; if(!s) return;
                s->fetching=NO; [s.spinner stopAnimating];
                if(error) { s.status.text=@"取得できませんでした。接続と空き容量を確認してください。"; [s message:error.localizedDescription]; }
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
- (void)layoutMenu {
    UIAlertController* menu=[UIAlertController alertControllerWithTitle:@"表示" message:@"Duo上下：上にモニタ、下にPC-98キーボード。iOS 27.1以降では半開きに自動追従します。" preferredStyle:UIAlertControllerStyleAlert];
    __weak PlayerController* weak=self;
    for(NSNumber* choice in @[@NO,@YES]) [menu addAction:[UIAlertAction actionWithTitle:choice.boolValue?@"Duo上下表示を固定":@"自動／通常表示" style:UIAlertActionStyleDefault handler:^(UIAlertAction* a) {
        PlayerController* s=weak; if(!s) return; [s releaseKeys]; s->manualDuo=choice.boolValue; [s setNeedsUpdateOfSupportedInterfaceOrientations];
        [NSUserDefaults.standardUserDefaults setBool:s->manualDuo forKey:@"PC98ManualDuo"]; [s.view setNeedsLayout];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)showLibrary {
    if(fetching) return;
    UIAlertController* menu=[UIAlertController alertControllerWithTitle:@"ゲームデータの場所" message:@"「開く」から、このiPhone内／ファイルで接続したNASのフォルダを選べます。元データは書き換えません。" preferredStyle:UIAlertControllerStyleAlert];
    __weak PlayerController* weak=self;
    for(NSDictionary* entry in GameLibrary.entries) [menu addAction:[UIAlertAction actionWithTitle:entry[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction* a) {
        NSURL* original=[NSURL fileURLWithPath:entry[@"path"] isDirectory:YES];
        NSString* identifier=gameID(original);
        NSURL* cached=area(NSCachesDirectory,[@"PC98Games/" stringByAppendingString:identifier]);
        if([NSFileManager.defaultManager fileExistsAtPath:cached.path]) { [weak openCache:cached identifier:identifier]; return; }
        NSError* error=nil; NSURL* source=[GameLibrary resolveEntry:entry error:&error];
        if(source) [weak cacheSource:source]; else [weak message:@"場所へのアクセスを復元できません。「開く」で再選択してください。"];
    }]];
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
    std::string error; bool saved=player->save_state(7,&error);
    uint8_t previous=player->m->ram[0x90000]; player->m->ram[0x90000]=previous^0xFF;
    bool loaded=player->load_state(7,&error);
    result[@"stateRoundtrip"]=@(saved && loaded && player->m->ram[0x90000]==previous);
    manualDuo=NO; hingeDuo=NO; duoHardware=NO; [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    result[@"phonePortraitOrientation"]=@(self.traitCollection.userInterfaceIdiom!=UIUserInterfaceIdiomPhone || self.supportedInterfaceOrientations==UIInterfaceOrientationMaskPortrait);
    result[@"phoneKeyboardBelowMonitor"]=@(CGRectGetMinY(self.keyboard.frame)>CGRectGetMaxY(self.topPanel.frame));
    UIGraphicsImageRenderer* portraitRenderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.view.bounds];
    self.monitor.image=frameImage(player.get());
    UIImage* portrait=[portraitRenderer imageWithActions:^(UIGraphicsImageRendererContext* context) { [self.view.layer renderInContext:context.CGContext]; }];
    [UIImagePNGRepresentation(portrait) writeToURL:area(NSDocumentDirectory,@"portrait-smoke.png") atomically:YES];
    manualDuo=YES; [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    result[@"duoPhysicalKeyboard"]=@([self.keyboard hardwareLayoutForTesting]);
    bool adaptive=true;
    for(CGSize size : {CGSizeMake(400,360),CGSizeMake(900,300)}) {
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
