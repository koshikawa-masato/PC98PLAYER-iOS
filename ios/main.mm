// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "GameLibrary.h"
#import "FeedbackForm.h"
#include "FeedbackErrorPolicy.h"
#import "Keyboard.h"
#include "DuoPresentation.h"
#import "RetroHardware.h"
#include "AudioOut.h"
#include "MidiSynth.h"
#include "MidiOut.h"
#include "font.h"
#include "floppy.h"
#include "player.h"
#include "StartupPath.h"
#include "GraphicsSettings.h"
#import "ContentFilter.h"
#include "hostfs.h"
#include <bitset>
#include <deque>
#include <memory>
#include <set>
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <pthread.h>
#include <algorithm>
#ifdef PC98PLAYER_TESTING
#import "AudioCaptureProbe.h"
#endif

// Keep the largest display area clear of an OS camera or system occlusion.
static CGRect monitorAvoiding(CGRect panel,CGRect obstacle,CGFloat ratio=640.0/400.0) {
    CGRect cut=CGRectIntersection(panel,obstacle);
    if(CGRectIsNull(cut) || CGRectIsEmpty(cut)) return panel;
    CGRect candidates[]={
        CGRectMake(panel.origin.x,panel.origin.y,panel.size.width,CGRectGetMinY(cut)-panel.origin.y),
        CGRectMake(panel.origin.x,CGRectGetMaxY(cut),panel.size.width,CGRectGetMaxY(panel)-CGRectGetMaxY(cut)),
        CGRectMake(panel.origin.x,panel.origin.y,CGRectGetMinX(cut)-panel.origin.x,panel.size.height),
        CGRectMake(CGRectGetMaxX(cut),panel.origin.y,CGRectGetMaxX(panel)-CGRectGetMaxX(cut),panel.size.height)};
    CGRect best=CGRectZero; CGFloat bestHeight=-1;
    for(CGRect r:candidates) {
        CGFloat height=MIN(r.size.height,r.size.width/ratio);
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
// アプリ内で作ったディスク（空のディスク）の置き場。ゲームごとに PC98UserDisks/<identifier>（nil = ゲームが無い）
static NSURL* userDiskDirectory(NSString* identifier) {
    if(!identifier.length) return nil;
    return area(NSApplicationSupportDirectory,[@"PC98UserDisks/" stringByAppendingString:identifier]);
}
// パスがそのゲームの PC98UserDisks の下か（コピーではなく実ファイルを入れているので、取り出す前に書き戻す）
static BOOL isUserDiskPath(const std::string& path,NSString* identifier) {
    NSURL* directory=userDiskDirectory(identifier);
    if(!directory || path.empty()) return NO;
    std::string base=directory.fileSystemRepresentation;
    while(base.size()>1 && base.back()=='/') base.pop_back();
    base+='/';
    return path.size()>base.size() && path.compare(0,base.size(),base)==0;
}
static NSString* gameIDForURLString(NSString* urlString) {
    NSData* bytes=[urlString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,hash);
    NSMutableString* key=[NSMutableString new]; for(unsigned char c:hash) [key appendFormat:@"%02x",c]; return key;
}
static NSString* gameID(NSURL* url) {
    return gameIDForURLString(url.URLByStandardizingPath.absoluteString);
}
static NSString* sourceIDKey(NSURL* source) {
    return [@"PC98LibrarySourceID." stringByAppendingString:source.path];
}
static NSString* registeredGameID(NSURL* original) {
    NSString* stored=[NSUserDefaults.standardUserDefaults stringForKey:sourceIDKey(original)];
    if(stored.length) return stored;
    NSString* originalID=gameID(original);
    NSString* path=original.path;
    // Older builds hashed the picker URL. Its /var prefix can differ from
    // the /private/var path in the saved bookmark entry.
    NSMutableArray<NSString*>* candidates=[NSMutableArray arrayWithObject:originalID];
    NSMutableArray<NSString*>* paths=[NSMutableArray arrayWithObject:path];
    if([path hasPrefix:@"/private/var/"]) [paths addObject:[path substringFromIndex:8]];
    if([path hasPrefix:@"/var/"]) [paths addObject:[@"/private" stringByAppendingString:path]];
    for(NSString* candidate in paths) {
        for(NSNumber* directory in @[@YES,@NO]) {
            NSURL* url=[NSURL fileURLWithPath:candidate isDirectory:directory.boolValue];
            [candidates addObject:gameIDForURLString(url.absoluteString)];
        }
    }
    for(NSString* identifier in candidates) {
        NSURL* cache=area(NSCachesDirectory,[@"PC98Games/" stringByAppendingString:identifier]);
        NSURL* saves=area(NSApplicationSupportDirectory,[@"PC98Saves/" stringByAppendingString:identifier]);
        if([NSFileManager.defaultManager fileExistsAtPath:cache.path] ||
           [NSFileManager.defaultManager fileExistsAtPath:saves.path]) return identifier;
    }
    return originalID;
}
static UIImage* frameImage(Player* p) {
    NSData* bytes=[NSData dataWithBytes:p->fb length:640*p->fb_h*sizeof(uint32_t)];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=CGImageCreate(640,p->fb_h,8,32,640*4,colors,kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst,provider,nullptr,false,kCGRenderingIntentDefault);
    UIImage* result=[UIImage imageWithCGImage:image]; CGImageRelease(image); CGColorSpaceRelease(colors); CGDataProviderRelease(provider); return result;
}
// Match guest pixels before filtering, but only export the image shown to the user.
static NSData* titleFrameDigest(const void* pixels, size_t length) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(pixels, (CC_LONG)length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}
static NSString* const defaultClockKey=@"PC98DefaultClockMHz";
static constexpr NSInteger minimumClockMHz=5;
static constexpr NSInteger maximumClockMHz=433;
static constexpr NSInteger clockPresets[]={0,16,66,133};

static BOOL validClockMHz(NSInteger clock) {
    return clock>=minimumClockMHz && clock<=maximumClockMHz;
}

// MIDI の送り先（0 = 内蔵シンセ、1 = 外部 MIDI OUT）。グローバル設定のみ（ゲームごとではない）
static NSString* const midiModeKey=@"PC98MidiMode";
static NSString* const midiDestinationIDKey=@"PC98MidiDestinationID";
static NSString* const midiDestinationNameKey=@"PC98MidiDestinationName";
static BOOL midiUsesExternalOut(void) {
    return [NSUserDefaults.standardUserDefaults integerForKey:midiModeKey]==1;
}
// Player の MIDI 出口から、設定に応じて内蔵シンセか外部 MIDI OUT へ渡す
struct MidiDispatch {
    MidiSynth* synth=nullptr;
    MidiOut* out=nullptr;
    BOOL external=NO;
    void handleMessage(const uint8_t* msg, int len) {
        if(external) { if(out) out->handleMessage(msg, len); }
        else if(synth) synth->handleMessage(msg, len);
    }
};
static void MidiSinkTrampoline(void* user, const uint8_t* msg, int len) { static_cast<MidiDispatch*>(user)->handleMessage(msg, len); }
static NSString* gameClockKey(NSString* identifier) {
    return [@"PC98GameClockMHz." stringByAppendingString:identifier];
}
// 画面モード（0 = 自動、1 = 31kHz、2 = 24kHz）。ゲームごとの値が無ければデフォルトを使う
static NSString* const displayModeKey=@"PC98DisplayMode";
static NSString* gameDisplayModeKey(NSString* identifier) {
    return [@"PC98GameDisplayMode." stringByAppendingString:identifier];
}
static NSInteger displayModeForGame(NSString* identifier) {
    NSNumber* game=identifier.length ? [NSUserDefaults.standardUserDefaults objectForKey:gameDisplayModeKey(identifier)] : nil;
    NSInteger mode=game ? game.integerValue : [NSUserDefaults.standardUserDefaults integerForKey:displayModeKey];
    return mode==1 || mode==2 ? mode : 0;
}
static NSString* const displayModeLabels[]={@"自動",@"31kHz（640×480）",@"24kHz（640×400）"};
static NSString* titleReferenceKey(NSString* identifier) {
    return [@"PC98TitleFrame." stringByAppendingString:identifier];
}
static NSURL* titleScreenshotURL(NSString* identifier) {
    return [area(NSDocumentDirectory, @"TitleScreenshots")
        URLByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"png"]];
}
static BOOL writeTitleScreenshot(UIImage* image, NSString* identifier) {
    NSData* png=UIImagePNGRepresentation(image);
    if(!png) return NO;
    NSURL* url=titleScreenshotURL(identifier);
    if(![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    return [png writeToURL:url options:NSDataWritingAtomic error:nil];
}
@interface FileChooser : UITableViewController
@property NSArray<NSString*>* paths;
@property NSString* explanation;
@property(copy) void (^selected)(NSString*);
@end
@implementation FileChooser
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section { return self.explanation; }
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return self.paths.count; }
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)index {
    UITableViewCell* cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text=self.paths[index.row]; cell.textLabel.numberOfLines=2; return cell;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)index {
    NSString* path=self.paths[index.row]; [self dismissViewControllerAnimated:YES completion:^{ if(self.selected) self.selected(path); }];
}
@end

@interface LegalTextController : UIViewController
@property(copy) NSString* resource;
@end
@implementation LegalTextController
- (void)loadView {
    UITextView* textView=[UITextView new];textView.editable=NO;textView.alwaysBounceVertical=YES;
    textView.backgroundColor=UIColor.systemBackgroundColor;textView.textColor=UIColor.labelColor;
    textView.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];textView.adjustsFontForContentSizeCategory=YES;
    textView.textContainerInset=UIEdgeInsetsMake(20,16,20,16);
    NSError* error=nil;
    NSString* content=[NSString stringWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:self.resource] encoding:NSUTF8StringEncoding error:&error];
    if([self.resource isEqualToString:@"LICENSE"]) {
        NSString* third=[NSString stringWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"THIRD-PARTY-ymfm-LICENSE.txt"] encoding:NSUTF8StringEncoding error:nil];
        if(third) content=[content stringByAppendingFormat:@"\n\nymfm\n%@",third];
        NSString* models=[NSString stringWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"THIRD-PARTY-content-models.txt"] encoding:NSUTF8StringEncoding error:nil];
        if(models)content=[content stringByAppendingFormat:@"\n\n%@",models];
    }
    textView.text=content ?: @"文書を読み込めませんでした。";textView.dataDetectorTypes=UIDataDetectorTypeLink;
    self.view=textView;
}
@end

static NSString* libraryTitleKey(NSString* identifier) {
    return [@"PC98LibraryTitle." stringByAppendingString:identifier];
}

static NSString* libraryHiddenKey(NSString* identifier) {
    return [@"PC98LibraryHidden." stringByAppendingString:identifier];
}

static NSString* catalogNameForFolder(NSURL* folder) {
    Ini ini;
    ini.load([folder URLByAppendingPathComponent:@"PC98PLAYER.INI"].fileSystemRepresentation);
    NSURL* root=[GameLibrary gameRootAtURL:folder relativePath:text(ini.get("PC98PLAYER.ROOT")) error:nil];
    return root ? [GameLibrary verifiedDisplayNameInFolder:root] : nil;
}

static NSString* const libraryThumbnailModeKey=@"PC98LibraryThumbnailMode";

@interface GameThumbnailCell : UICollectionViewCell
@property(strong) UIImageView* screenshot;
@property(strong) UIImageView* cacheBadge;
@property(strong) UIButton* infoButton;
@property(strong) UIButton* gameButton;
@property(copy) void (^showInfo)(void);
@property(copy) void (^launchGame)(void);
@end

@implementation GameThumbnailCell
- (instancetype)initWithFrame:(CGRect)frame {
    if(!(self=[super initWithFrame:frame])) return nil;
    self.contentView.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
    self.contentView.layer.cornerRadius=8;
    self.contentView.clipsToBounds=YES;

    self.screenshot=[UIImageView new];
    self.screenshot.contentMode=UIViewContentModeScaleAspectFit;
    self.screenshot.tintColor=UIColor.secondaryLabelColor;
    self.gameButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.gameButton addTarget:self action:@selector(openGame) forControlEvents:UIControlEventTouchUpInside];
    self.cacheBadge=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"internaldrive.fill"]];
    self.cacheBadge.contentMode=UIViewContentModeCenter;
    self.cacheBadge.tintColor=UIColor.whiteColor;
    self.cacheBadge.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:0.75];
    self.cacheBadge.layer.cornerRadius=13;

    self.infoButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.infoButton setImage:[UIImage systemImageNamed:@"info.circle.fill"] forState:UIControlStateNormal];
    self.infoButton.tintColor=UIColor.whiteColor;
    self.infoButton.accessibilityLabel=@"作品情報";
    [self.infoButton addTarget:self action:@selector(openInfo) forControlEvents:UIControlEventTouchUpInside];
    UIView* infoBackground=[UIView new];
    infoBackground.userInteractionEnabled=NO;
    infoBackground.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:0.75];
    infoBackground.layer.cornerRadius=14;
    for(UIView* item in @[self.screenshot,self.cacheBadge,self.gameButton,infoBackground,self.infoButton]) {
        item.translatesAutoresizingMaskIntoConstraints=NO;
        [self.contentView addSubview:item];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.screenshot.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.screenshot.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.screenshot.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.screenshot.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [self.gameButton.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.gameButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.gameButton.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.gameButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [self.cacheBadge.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:8],
        [self.cacheBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [self.cacheBadge.widthAnchor constraintEqualToConstant:26],
        [self.cacheBadge.heightAnchor constraintEqualToConstant:26],
        [self.infoButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.infoButton.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.infoButton.widthAnchor constraintEqualToConstant:44],
        [self.infoButton.heightAnchor constraintEqualToConstant:44],
        [infoBackground.centerXAnchor constraintEqualToAnchor:self.infoButton.centerXAnchor],
        [infoBackground.centerYAnchor constraintEqualToAnchor:self.infoButton.centerYAnchor],
        [infoBackground.widthAnchor constraintEqualToConstant:28],
        [infoBackground.heightAnchor constraintEqualToConstant:28],
    ]];
    return self;
}
- (void)openInfo { if(self.showInfo) self.showInfo(); }
- (void)openGame { if(self.launchGame) self.launchGame(); }
@end

@interface GameLocationsController : UIViewController <UITableViewDataSource,UITableViewDelegate,UICollectionViewDataSource,UICollectionViewDelegateFlowLayout>
@property(copy) NSString* message;
@property(copy) void (^demoAction)(void);
@property(strong) NSMutableArray<NSDictionary*>* choices;
@property(strong) UITableView* tableView;
@property(strong) UICollectionView* grid;
@property(strong) UILabel* emptyGrid;
@property BOOL showsThumbnails;
- (void)addGame:(NSString*)title identifier:(NSString*)identifier cached:(BOOL)cached action:(void (^)(void))action
           info:(void (^)(void))info remove:(void (^)(void))remove;
@end
@implementation GameLocationsController
- (instancetype)init { if((self=[super init])) self.choices=[NSMutableArray new];return self; }
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"ゲーム一覧";
    self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"閉じる" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"デモ" style:UIBarButtonItemStylePlain target:self action:@selector(openDemo)];
    self.showsThumbnails=[NSUserDefaults.standardUserDefaults boolForKey:libraryThumbnailModeKey];
    UISegmentedControl* mode=[[UISegmentedControl alloc] initWithItems:@[@"リスト",@"サムネイル"]];
    mode.selectedSegmentIndex=self.showsThumbnails ? 1 : 0;
    mode.accessibilityLabel=@"ゲーム一覧の表示形式";
    [mode addTarget:self action:@selector(changeLibraryMode:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView=mode;

    self.tableView=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource=self;self.tableView.delegate=self;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=72;

    UICollectionViewFlowLayout* layout=[UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing=8;
    layout.minimumLineSpacing=8;
    layout.sectionInset=UIEdgeInsetsMake(8,8,8,8);
    self.grid=[[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.grid.backgroundColor=UIColor.clearColor;
    self.grid.dataSource=self;self.grid.delegate=self;
    [self.grid registerClass:GameThumbnailCell.class forCellWithReuseIdentifier:@"GameThumbnail"];
    self.emptyGrid=[UILabel new];
    self.emptyGrid.text=self.message ?: @"ゲームが登録されていません。";
    self.emptyGrid.textColor=UIColor.secondaryLabelColor;
    self.emptyGrid.textAlignment=NSTextAlignmentCenter;
    self.emptyGrid.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyGrid.adjustsFontForContentSizeCategory=YES;
    self.emptyGrid.numberOfLines=0;
    self.grid.backgroundView=self.emptyGrid;

    UILayoutGuide* safe=self.view.safeAreaLayoutGuide;
    for(UIScrollView* scroll in @[self.tableView,self.grid]) {
        scroll.translatesAutoresizingMaskIntoConstraints=NO;
        [self.view addSubview:scroll];
        [NSLayoutConstraint activateConstraints:@[
            [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
            [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        ]];
    }
    [self updateLibraryMode];
}
- (void)updateLibraryMode {
    self.tableView.hidden=self.showsThumbnails;
    self.grid.hidden=!self.showsThumbnails;
    self.emptyGrid.hidden=self.choices.count>0;
}
- (void)changeLibraryMode:(UISegmentedControl*)control {
    self.showsThumbnails=control.selectedSegmentIndex==1;
    [NSUserDefaults.standardUserDefaults setBool:self.showsThumbnails forKey:libraryThumbnailModeKey];
    [self updateLibraryMode];
}
- (void)openDemo { [self dismissViewControllerAnimated:YES completion:self.demoAction]; }
- (NSInteger)collectionView:(UICollectionView*)view numberOfItemsInSection:(NSInteger)section {
    return self.choices.count;
}
- (CGSize)collectionView:(UICollectionView*)view layout:(UICollectionViewLayout*)layout sizeForItemAtIndexPath:(NSIndexPath*)index {
    CGFloat available=MAX(1,view.bounds.size.width-16);
    NSInteger columns=MAX(2,(NSInteger)floor((available+8)/168));
    CGFloat width=MAX(1,floor((available-(columns-1)*8)/columns));
    return CGSizeMake(width,floor(width*400/640));
}
- (UICollectionViewCell*)collectionView:(UICollectionView*)view cellForItemAtIndexPath:(NSIndexPath*)index {
    GameThumbnailCell* cell=[view dequeueReusableCellWithReuseIdentifier:@"GameThumbnail" forIndexPath:index];
    NSDictionary* choice=self.choices[index.item];
    UIImage* screenshot=[UIImage imageWithContentsOfFile:titleScreenshotURL(choice[@"identifier"]).path];
    cell.screenshot.image=screenshot ?: [UIImage systemImageNamed:@"photo"];
    cell.screenshot.contentMode=screenshot ? UIViewContentModeScaleAspectFit : UIViewContentModeCenter;
    BOOL cached=[choice[@"cached"] boolValue];
    cell.cacheBadge.hidden=!cached;
    cell.gameButton.accessibilityLabel=cached ? [choice[@"title"] stringByAppendingString:@"、キャッシュあり"] : choice[@"title"];
    cell.infoButton.accessibilityLabel=[choice[@"title"] stringByAppendingString:@"の作品情報"];
    cell.showInfo=choice[@"info"];
    __weak GameLocationsController* weak=self;
    void (^action)(void)=choice[@"action"];
    cell.launchGame=^{ [weak dismissViewControllerAnimated:YES completion:action]; };
    return cell;
}
- (void)collectionView:(UICollectionView*)view didSelectItemAtIndexPath:(NSIndexPath*)index {
    [self openChoice:index.item];
}
- (void)openChoice:(NSInteger)index {
    void (^action)(void)=self.choices[index][@"action"];
    [self dismissViewControllerAnimated:YES completion:action];
}
- (void)addGame:(NSString*)title identifier:(NSString*)identifier cached:(BOOL)cached action:(void (^)(void))action
           info:(void (^)(void))info remove:(void (^)(void))remove {
    [self.choices addObject:@{@"title":title,@"identifier":identifier,@"cached":@(cached),@"action":[action copy],
                              @"info":[info copy],@"remove":[remove copy]}];
}
- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView
 trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)index {
    NSDictionary* choice=self.choices[index.row];
    void (^remove)(void)=choice[@"remove"];
    if(!remove) return nil;
    NSString* identifier=choice[@"identifier"];
    UIContextualAction* trash=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"一覧から削除" handler:^(UIContextualAction* action, UIView* view, void (^completion)(BOOL)) {
        remove();
        NSIndexSet* rows=[self.choices indexesOfObjectsPassingTest:^BOOL(NSDictionary* row, NSUInteger i, BOOL* stop) {
            return [row[@"identifier"] isEqualToString:identifier];
        }];
        [self.choices removeObjectsAtIndexes:rows];
        NSMutableArray* paths=[NSMutableArray new];
        [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL* stop) {
            [paths addObject:[NSIndexPath indexPathForRow:row inSection:0]];
        }];
        [tableView deleteRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationAutomatic];
        [self.grid reloadData];
        [self updateLibraryMode];
        completion(YES);
    }];
    trash.image=[UIImage systemImageNamed:@"trash"];
    trash.backgroundColor=UIColor.systemRedColor;
    UISwipeActionsConfiguration* config=[UISwipeActionsConfiguration configurationWithActions:@[trash]];
    config.performsFirstActionWithFullSwipe=NO;
    return config;
}
- (void)tableView:(UITableView*)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath*)index {
    void (^info)(void)=self.choices[index.row][@"info"];
    if(info) info();
}
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return self.choices.count; }
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section { return self.message; }
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)index {
    UITableViewCell* cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSDictionary* choice=self.choices[index.row];cell.textLabel.text=choice[@"title"];cell.textLabel.numberOfLines=0;
    cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];cell.textLabel.adjustsFontForContentSizeCategory=YES;
    cell.textLabel.textColor=[choice[@"destructive"] boolValue]?UIColor.systemRedColor:UIColor.labelColor;
    if([choice[@"cached"] boolValue]) {
        NSTextAttachment* badge=[NSTextAttachment new];
        badge.image=[[UIImage systemImageNamed:@"internaldrive.fill"
            withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleBody]]
            imageWithTintColor:UIColor.secondaryLabelColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        NSMutableAttributedString* label=[[NSMutableAttributedString alloc] initWithString:[choice[@"title"] stringByAppendingString:@"  "]];
        [label appendAttributedString:[NSAttributedString attributedStringWithAttachment:badge]];
        cell.textLabel.attributedText=label;
        cell.textLabel.accessibilityLabel=[choice[@"title"] stringByAppendingString:@"、キャッシュあり"];
    }
    NSString* identifier=choice[@"identifier"];
    if(identifier.length) {
        UIListContentConfiguration* content=[UIListContentConfiguration cellConfiguration];
        if([choice[@"cached"] boolValue]) content.attributedText=cell.textLabel.attributedText;
        else content.text=choice[@"title"];
        content.textProperties.numberOfLines=0;
        content.image=[UIImage imageWithContentsOfFile:titleScreenshotURL(identifier).path]
            ?: [UIImage systemImageNamed:@"photo"];
        content.imageProperties.maximumSize=CGSizeMake(88,55);
        content.imageProperties.reservedLayoutSize=CGSizeMake(88,55);
        content.imageProperties.cornerRadius=6;
        content.imageProperties.tintColor=UIColor.tertiaryLabelColor;
        cell.contentConfiguration=content;
        cell.accessibilityLabel=[choice[@"cached"] boolValue] ? [choice[@"title"] stringByAppendingString:@"、キャッシュあり"] : choice[@"title"];
    }
    cell.accessoryType=choice[@"info"] ? UITableViewCellAccessoryDetailButton : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)index {
    [self openChoice:index.row];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

static NSString* const cacheOnLaunchKey=@"PC98CacheOnLaunch";
static BOOL usesGameCache(void) {
    NSNumber* enabled=[NSUserDefaults.standardUserDefaults objectForKey:cacheOnLaunchKey];
    return enabled ? enabled.boolValue : YES;
}
static NSString* const portraitEdgeToEdgeKey=@"PC98PortraitEdgeToEdge";
static BOOL usesPortraitEdgeToEdge(void) {
    NSNumber* enabled=[NSUserDefaults.standardUserDefaults objectForKey:portraitEdgeToEdgeKey];
    return enabled ? enabled.boolValue : YES;
}
static NSString* const landscapeControllerDefaultKey=@"PC98LandscapeControllerDefault";
static BOOL showsLandscapeControllerByDefault(void) {
    NSNumber* enabled=[NSUserDefaults.standardUserDefaults objectForKey:landscapeControllerDefaultKey];
    return enabled ? enabled.boolValue : YES;
}
static NSString* const launchFullscreenKey=@"PC98LaunchFullscreen";
static NSString* const bluetoothBindingsKey=@"PC98BluetoothControllerBindings";

static void presentCustomClock(UIViewController* presenter, NSInteger clock, void (^selected)(NSInteger)) {
    NSString* message=[NSString stringWithFormat:@"%ld〜%ld MHzの整数を入力してください。",(long)minimumClockMHz,(long)maximumClockMHz];
    UIAlertController* alert=[UIAlertController alertControllerWithTitle:@"任意の周波数" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.keyboardType=UIKeyboardTypeNumberPad;
        field.text=clock ? [NSString stringWithFormat:@"%ld",(long)clock] : @"";
        field.placeholder=@"MHz";
        field.accessibilityLabel=@"CPUクロック（MHz）";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController* weakAlert=alert;
    UIAlertAction* choose=[UIAlertAction actionWithTitle:@"設定" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        NSInteger value=weakAlert.textFields.firstObject.text.integerValue;
        if(validClockMHz(value)) selected(value);
    }];
    UITextField* field=alert.textFields.firstObject;
    __weak UIAlertAction* weakChoose=choose;
    void (^validate)(UITextField*)=^(UITextField* input) {
        NSString* text=input.text;
        NSCharacterSet* invalid=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
        weakChoose.enabled=text.length>0 && text.length<=3 &&
            [text rangeOfCharacterFromSet:invalid].location==NSNotFound && validClockMHz(text.integerValue);
    };
    validate(field);
    [field addAction:[UIAction actionWithHandler:^(__kindof UIAction* action) {
        validate((UITextField*)action.sender);
    }] forControlEvents:UIControlEventEditingChanged];
    [alert addAction:choose];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@interface GameOptionsController : UITableViewController
@property(nonatomic, strong) UIImage* issueScreenshot;
@property(nonatomic, copy) NSDictionary* issueDiagnostics;
@property NSInteger soundBoard;
@property NSInteger midiMode;
@property NSInteger midiDestinationID;
@property(copy) NSString* midiDestinationName;
@property NSInteger videoColors;
@property NSInteger displayMode;
@property NSInteger clockMHz;
@property BOOL manualDuo;
@property BOOL bossMode;
@property BOOL launchFullscreen;
@property BOOL landscapeControllerDefault;
@property BOOL portraitEdgeToEdge;
@property BOOL cacheOnLaunch;
@property(copy) NSArray<NSNumber*>* bluetoothBindings;
@property content_filter::Settings filterSettings;
@property(copy) void (^willApply)(content_filter::Settings);
@property(copy) void (^applied)(NSInteger,NSInteger,NSInteger,BOOL,BOOL,content_filter::Settings);
@property(copy) void (^cancelled)(void);
@end
@implementation GameOptionsController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"オプション";
    self.bluetoothBindings=pc98_controller_bindings([NSUserDefaults.standardUserDefaults arrayForKey:bluetoothBindingsKey]);
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"キャンセル" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"適用" style:UIBarButtonItemStyleDone target:self action:@selector(apply)];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView { return 7; }
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return section==0?5:section==2?7:section==3?6:section==4?1:section==5?5:section==6?3:section==1?5:2; }
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section { return @[@"音源",@"色数・画面モード",@"表示",@"コンテンツフィルター",@"Bluetoothコントローラー",@"CPUクロックのデフォルト",@"このアプリについて"][section]; }
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    if(section==0)return @"MIDIは内蔵シンセか外部出力のどちらかへ送ります。外部出力は、他の音源アプリの仮想ポートやBluetooth／USB／ネットワークMIDI機器が対象です。MIDIの変更は次回のゲーム起動から適用します。";
    if(section==1)return @"変更を適用するとゲームが再起動します。必要な場合は、先にゲーム内で保存してください。";
    if(section==2)return @"通常は自動判別を使います。Duo上下表示を固定すると、上にモニタ、下にキーボードを配置します。表示だけの変更では再起動しません。「ボスがきた」モードはDuoを閉じると一時停止し、アウターのアプリ画面を黒くします。開き直しても自動再生せず、▶︎で再開します。端末の画面電源やシステム表示は変更しません。";
    if(section==5)return @"次回のゲーム起動から適用します。一覧のⓘでゲームごとの設定を保存できます。";
    if(section==3)return @"画像を端末内AIで判定し、推定した領域を隠します。画面を外部へ送信しません。判定中は直前の保護済み画像を保持するため、表示が遅れることがあります。誤検出・見逃しがあり、文章は判定しません。残酷描写は流血・損傷の特徴を推定する試験的な機能です。";
    return nil;
}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)index {
    UITableViewCell* cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.detailTextLabel.numberOfLines=0;
    if(index.section==0) {
        if(index.row<2) {
            cell.textLabel.text=index.row==0?@"OPN":@"OPNA";
            cell.detailTextLabel.text=index.row==0?@"YM2203":@"YM2608";
            cell.accessoryType=(self.soundBoard==(index.row==0?26:86))?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
        } else if(index.row==2) {
            cell.textLabel.text=@"MIDI：内蔵シンセ";
            cell.detailTextLabel.text=@"サウンドフォント（GeneralUser GS）で再生";
            cell.accessoryType=self.midiMode==0?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
        } else if(index.row==3) {
            cell.textLabel.text=@"MIDI：外部へ出力";
            cell.detailTextLabel.text=@"他の音源アプリやMIDI機器へ送る（MIDI OUT）";
            cell.accessoryType=self.midiMode==1?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.text=@"外部MIDIの送り先";
            cell.detailTextLabel.text=self.midiDestinationName.length?self.midiDestinationName:@"自動（最初に見つかったポート）";
            cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if(index.section==1) {
        cell.textLabel.text=index.row==0?@"16色":@"256色";
        cell.detailTextLabel.text=index.row==0?@"標準グラフィック":@"拡張グラフィック";
        cell.accessoryType=(self.videoColors==(index.row==0?16:256))?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
        if(index.row>=2) {   // 画面モード
            cell.textLabel.text=displayModeLabels[index.row-2];
            cell.detailTextLabel.text=index.row==2?@"画面モード: ソフトに合わせる":index.row==3?@"画面モード: 480 ラインで始める":@"画面モード: 400 ラインに固定";
            cell.accessoryType=self.displayMode==index.row-2?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
        }
    } else if(index.section==2) {
        cell.textLabel.text=index.row==0?@"自動判別":index.row==1?@"Duo上下表示を固定":@"ボスがきた";
        cell.detailTextLabel.text=index.row==0?@"端末とヒンジの状態に合わせる":index.row==1?@"上にモニタ、下にキーボード":@"Duoを閉じると一時停止・アウターを非表示";
        if(index.row==6) {
            cell.textLabel.text=@"横画面の全画面でコントローラーを表示";
            cell.textLabel.numberOfLines=0;
            cell.detailTextLabel.text=@"プレイ中は長押しメニューで切り替え";
            UISwitch* toggle=[UISwitch new];
            toggle.on=self.landscapeControllerDefault;
            toggle.accessibilityLabel=cell.textLabel.text;
            [toggle addTarget:self action:@selector(changeLandscapeControllerDefault:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=toggle;
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
        } else if(index.row==5) {
            cell.textLabel.text=@"縦画面で横幅いっぱいに表示";
            cell.detailTextLabel.text=@"iPhoneの縦画面でモニターの枠を外す";
            UISwitch* toggle=[UISwitch new];
            toggle.on=self.portraitEdgeToEdge;
            toggle.accessibilityLabel=cell.textLabel.text;
            [toggle addTarget:self action:@selector(changePortraitEdgeToEdge:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=toggle;
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
        } else if(index.row==4) {
            cell.textLabel.text=@"キャッシュを作って起動";
            cell.detailTextLabel.text=@"オフの場合は元フォルダから直接読み込み";
            UISwitch* toggle=[UISwitch new];
            toggle.on=self.cacheOnLaunch;
            toggle.accessibilityLabel=cell.textLabel.text;
            [toggle addTarget:self action:@selector(changeCacheOnLaunch:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=toggle;
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
        } else if(index.row>=2) {
            BOOL startup=index.row==2;
            if(startup) {
                cell.textLabel.text=@"起動時に最大化で表示";
                cell.detailTextLabel.text=@"次回のアプリ起動時に適用";
            }
            UISwitch* toggle=[UISwitch new];
            toggle.on=startup ? self.launchFullscreen : self.bossMode;
            toggle.accessibilityLabel=cell.textLabel.text;
            [toggle addTarget:self action:startup ? @selector(changeLaunchFullscreen:) : @selector(changeBossMode:)
                forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=toggle;
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
        } else cell.accessoryType=(self.manualDuo==(index.row==1))?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    } else if(index.section==3) {
        if(index.row<2) {
            cell.textLabel.text=index.row==0?@"成人向け表現を隠す":@"残酷描写を隠す";
            cell.detailTextLabel.text=index.row==0?@"成人向け画像の推定":@"流血・損傷の推定（試験的）";
            UISwitch* toggle=[UISwitch new];toggle.tag=index.row;toggle.on=index.row==0?self.filterSettings.adult:self.filterSettings.harm;
            toggle.accessibilityLabel=cell.textLabel.text;[toggle addTarget:self action:@selector(changeFilter:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=toggle;cell.selectionStyle=UITableViewCellSelectionStyleNone;
        } else if(index.row<5) {
            cell.textLabel.text=@[@"黒塗り",@"ぼかし",@"モザイク"][index.row-2];
            BOOL selected=(int)self.filterSettings.effect==index.row-2;
            cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
            cell.isAccessibilityElement=YES;cell.accessibilityLabel=cell.textLabel.text;
            cell.accessibilityTraits=UIAccessibilityTraitButton|(selected?UIAccessibilityTraitSelected:0);
        } else {
            cell.textLabel.text=@"検出感度";
            UISegmentedControl* level=[[UISegmentedControl alloc] initWithItems:@[@"低",@"標準",@"高"]];level.selectedSegmentIndex=self.filterSettings.sensitivity;
            level.accessibilityLabel=@"検出感度";[level addTarget:self action:@selector(changeSensitivity:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView=level;cell.selectionStyle=UITableViewCellSelectionStyleNone;
        }
    } else if(index.section==4) {
        cell.textLabel.text=@"デフォルトのキー割り当て";
        UIButton* button=[UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:@"変更" forState:UIControlStateNormal];
        button.accessibilityLabel=@"Bluetoothコントローラーのキー割り当てを変更";
        button.showsMenuAsPrimaryAction=YES;
        __weak GameOptionsController* weak=self;
        button.menu=pc98_controller_binding_menu(self.bluetoothBindings,nil,^(NSArray<NSNumber*>* bindings) {
            GameOptionsController* options=weak;
            options.bluetoothBindings=bindings;
            [options.tableView reloadData];
        });
        [button sizeToFit];
        cell.accessoryView=button;
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    } else if(index.section==5) {
        if(index.row<4) {
            NSInteger clock=clockPresets[index.row];
            cell.textLabel.text=clock ? [NSString stringWithFormat:@"%ld MHz",(long)clock] : @"INIの設定を使用";
            if(self.clockMHz==clock) cell.accessoryType=UITableViewCellAccessoryCheckmark;
        } else {
            BOOL custom=validClockMHz(self.clockMHz) && self.clockMHz!=16 && self.clockMHz!=66 && self.clockMHz!=133;
            cell.textLabel.text=@"任意の周波数";
            cell.detailTextLabel.text=custom ? [NSString stringWithFormat:@"%ld MHz",(long)self.clockMHz] :
                [NSString stringWithFormat:@"%ld〜%ld MHz",(long)minimumClockMHz,(long)maximumClockMHz];
            cell.accessoryType=custom ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryDisclosureIndicator;
        }
    } else if(index.row==2) {
        cell.textLabel.text=@"バージョン";
        cell.detailTextLabel.text=[PC98FeedbackAppVersion() stringByAppendingString:@" · 不具合を報告"];
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text=index.row==0?@"プライバシーポリシー":@"ライセンス";
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)index {
    if(index.section==4) return;
    if(index.section==5) {
        [tableView deselectRowAtIndexPath:index animated:YES];
        if(index.row==4) [self editClock];
        else { self.clockMHz=clockPresets[index.row]; [tableView reloadData]; }
        return;
    }
    if(index.section==6) {
        [tableView deselectRowAtIndexPath:index animated:YES];
        if(index.row==2) {
            [self reportIssue];
            return;
        }
        LegalTextController* document=[LegalTextController new];document.title=index.row==0?@"プライバシーポリシー":@"ライセンス";
        document.resource=index.row==0?@"privacy-policy.txt":@"LICENSE";[self.navigationController pushViewController:document animated:YES];return;
    }
    if(index.section==0 && index.row<2)self.soundBoard=index.row==0?26:86;
    else if(index.section==0 && index.row==2)self.midiMode=0;
    else if(index.section==0 && index.row==3)self.midiMode=1;
    else if(index.section==0 && index.row==4) { [self chooseMidiDestinationFromCell:[tableView cellForRowAtIndexPath:index]]; return; }
    else if(index.section==1 && index.row>=2)self.displayMode=index.row-2;
    else if(index.section==1)self.videoColors=index.row==0?16:256;
    else if(index.section==2 && index.row<2)self.manualDuo=index.row==1;
    else if(index.section==3 && index.row>=2 && index.row<5) { auto settings=self.filterSettings;settings.effect=(content_filter::Effect)(index.row-2);self.filterSettings=settings; }
    [tableView reloadData];
}
- (void)chooseMidiDestinationFromCell:(UITableViewCell*)cell {
    [self.tableView deselectRowAtIndexPath:self.tableView.indexPathForSelectedRow animated:YES];
    auto destinations=MidiOut::destinations();
    if(destinations.empty()) {
        UIAlertController* none=[UIAlertController alertControllerWithTitle:@"外部MIDIの送り先"
            message:@"MIDIの送り先が見つかりません。音源アプリを起動するか、MIDI機器を接続してから選び直してください。送り先を「自動」にしておくと、ゲーム起動時に最初に見つかったポートへ送ります。"
            preferredStyle:UIAlertControllerStyleAlert];
        [none addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:none animated:YES completion:nil];
        return;
    }
    UIAlertController* picker=[UIAlertController alertControllerWithTitle:@"外部MIDIの送り先" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak GameOptionsController* weak=self;
    [picker addAction:[UIAlertAction actionWithTitle:@"自動（最初に見つかったポート）" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        GameOptionsController* options=weak; if(!options) return;
        options.midiDestinationID=0; options.midiDestinationName=@""; options.midiMode=1;
        [options.tableView reloadData];
    }]];
    for(auto& entry : destinations) {
        NSString* name=[NSString stringWithUTF8String:entry.second.c_str()] ?: @"(名称なし)";
        NSInteger uniqueID=entry.first;
        [picker addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            GameOptionsController* options=weak; if(!options) return;
            options.midiDestinationID=uniqueID; options.midiDestinationName=name; options.midiMode=1;
            [options.tableView reloadData];
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    if(picker.popoverPresentationController && cell) {
        picker.popoverPresentationController.sourceView=cell;
        picker.popoverPresentationController.sourceRect=cell.bounds;
    }
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)reportIssue {
    UIViewController* form=PC98FeedbackFormWithContext(PC98FeedbackAppVersion(),self.issueScreenshot,self.issueDiagnostics,nil,nil);
    [self.navigationController pushViewController:form animated:YES];
}
- (void)editClock {
    __weak GameOptionsController* weak=self;
    presentCustomClock(self,self.clockMHz,^(NSInteger value) {
        weak.clockMHz=value;
        [weak.tableView reloadData];
    });
}
- (void)changeCacheOnLaunch:(UISwitch*)sender { self.cacheOnLaunch=sender.on; }
- (void)changePortraitEdgeToEdge:(UISwitch*)sender { self.portraitEdgeToEdge=sender.on; }
- (void)changeLandscapeControllerDefault:(UISwitch*)sender { self.landscapeControllerDefault=sender.on; }
- (void)changeLaunchFullscreen:(UISwitch*)sender { self.launchFullscreen=sender.on; }
- (void)changeBossMode:(UISwitch*)sender { self.bossMode=sender.on; }
- (void)changeFilter:(UISwitch*)sender { auto settings=self.filterSettings;if(sender.tag==0)settings.adult=sender.on;else settings.harm=sender.on;self.filterSettings=settings; }
- (void)changeSensitivity:(UISegmentedControl*)sender { auto settings=self.filterSettings;settings.sensitivity=(int)sender.selectedSegmentIndex;self.filterSettings=settings; }
- (void)cancel { [self dismissViewControllerAnimated:YES completion:^{if(self.cancelled)self.cancelled();}]; }
- (void)apply {
    [NSUserDefaults.standardUserDefaults setObject:self.bluetoothBindings forKey:bluetoothBindingsKey];
    [NSUserDefaults.standardUserDefaults setBool:self.landscapeControllerDefault forKey:landscapeControllerDefaultKey];
    [NSUserDefaults.standardUserDefaults setBool:self.launchFullscreen forKey:launchFullscreenKey];
    [NSUserDefaults.standardUserDefaults setBool:self.portraitEdgeToEdge forKey:portraitEdgeToEdgeKey];
    [NSUserDefaults.standardUserDefaults setBool:self.cacheOnLaunch forKey:cacheOnLaunchKey];
    [NSUserDefaults.standardUserDefaults setInteger:self.clockMHz forKey:defaultClockKey];
    [NSUserDefaults.standardUserDefaults setInteger:self.midiMode forKey:midiModeKey];
    [NSUserDefaults.standardUserDefaults setInteger:self.midiDestinationID forKey:midiDestinationIDKey];
    if(self.midiDestinationName.length) [NSUserDefaults.standardUserDefaults setObject:self.midiDestinationName forKey:midiDestinationNameKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:midiDestinationNameKey];
    if(self.willApply)self.willApply(self.filterSettings);[self dismissViewControllerAnimated:YES completion:^{if(self.applied)self.applied(self.soundBoard,self.videoColors,self.displayMode,self.manualDuo,self.bossMode,self.filterSettings);}]; }
@end

@interface PlayerController : UIViewController <UIDocumentPickerDelegate,UIAdaptivePresentationControllerDelegate,UIGestureRecognizerDelegate> {
    std::unique_ptr<Player> player;
    AudioOut audio;
    MidiSynth midiSynth;
    MidiOut midiOut;
    MidiDispatch midiDispatch;
    BOOL midiFontLoaded;
    BOOL midiExternal;
    std::atomic<double> nextFrame;
    double fpsSampleStart;
    int fpsSampleFrames;
    struct FPSSample {
        double elapsed;
        int frames;
    };
    std::deque<FPSSample> fpsHistory;
    BOOL bossMode;
    std::atomic<bool> hingeClosed;
    std::atomic<bool> paused, fetching;
    BOOL pickerPreviousPause, manualDuo, hingeDuo, duoHardware, fullScreen, fullscreenMenuPaused;
    int mouseButtons;
    int filterFrameHeight;
    CFTimeInterval lastMonitorCapture;
    std::thread producerThread;
    std::mutex playerMutex;
    std::atomic<bool> producerStop;
    std::atomic<bool> manualDrive;
    std::atomic<uint64_t> producedFrames;
    uint64_t lastProducedSeen;
    std::set<NSInteger> physicalKeys;
    std::set<int> touchKeys;
    std::bitset<128> controllerKeys;
}
@property UIView* bossShield;
@property(nonatomic,weak) UIDocumentPickerViewController* floppyPicker;
@property(nonatomic) int floppyPickerUnit;
@property(nonatomic,strong) NSNumber* fullscreenControllerOverride;
@property id<UIInteraction> hingeInteraction;
@property UIImageView* monitor;
@property UIImage* displayedSourceFrame;
@property NSData* titleReference;
@property BOOL titleCaptureAttempted;
@property PC98ContentFilter* contentFilter;
@property PC98MonitorCabinet* topPanel;
@property PC98Keyboard* keyboard;
@property UILabel* status;
@property UILabel* fpsLabel;
@property(copy) NSArray<NSNumber*>* bluetoothBindings;
@property UIStackView* statusRow;
@property UIStackView* toolbar;
@property CADisplayLink* displayLink;
@property UIActivityIndicatorView* spinner;
@property NSURL* currentCache;
@property NSURL* scopedGameFolder;
@property BOOL readingOriginal;
@property NSString* currentID;
@property(copy) NSDictionary* launchDiagnostics;
@property(copy) NSDictionary* pendingFeedbackError;
@property(strong) UIImage* pendingFeedbackImage;
@property(strong) NSMutableSet<NSString*>* reportedErrorCodes;
@property BOOL guestTerminationHandled;
@property BOOL feedbackRestorePlayback;
@property NSUInteger feedbackGeneration;
@property uint64_t displayedFrameNumber;
#ifdef PC98PLAYER_TESTING
@property AudioCaptureProbe* audioProbe;
#endif
@end
@interface PlayerController (Producer)
- (void)producerMain;
- (void)startProducer;
- (void)stopProducer;
@end
static void PC98ProducerEntry(void* context) {
    [(__bridge PlayerController*)context producerMain];
}
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
    // MIDI 音源のサウンドフォントは同梱されている場合だけ読む（標本化周波数はゲーム起動時に合わせ直す）
    NSString* soundFont=[[NSBundle mainBundle] pathForResource:@"GeneralUser-GS" ofType:@"sf2"];
    NSData* soundFontData=soundFont?[NSData dataWithContentsOfFile:soundFont]:nil;
    midiFontLoaded=soundFontData && midiSynth.load(soundFontData.bytes,(int)soundFontData.length,44100);
    manualDuo=[NSUserDefaults.standardUserDefaults boolForKey:@"PC98ManualDuo"];
    bossMode=[NSUserDefaults.standardUserDefaults boolForKey:@"PC98BossMode"];
    self.contentFilter=[PC98ContentFilter new];
    content_filter::Settings filter;
    NSUserDefaults* defaults=NSUserDefaults.standardUserDefaults;
    filter.adult=[defaults boolForKey:@"PC98AdultFilter"];filter.harm=[defaults boolForKey:@"PC98HarmFilter"];
    filter.effect=(content_filter::Effect)std::clamp((int)[defaults integerForKey:@"PC98FilterEffect"],0,2);
    filter.sensitivity=[defaults objectForKey:@"PC98FilterSensitivity"]?std::clamp((int)[defaults integerForKey:@"PC98FilterSensitivity"],0,2):1;
    [self.contentFilter configure:filter];
    self.topPanel=[PC98MonitorCabinet new]; [self.view addSubview:self.topPanel];
    self.monitor=[UIImageView new]; self.monitor.contentMode=UIViewContentModeScaleAspectFit;
    self.monitor.layer.cornerRadius=4; self.monitor.clipsToBounds=YES; self.monitor.backgroundColor=[UIColor colorWithRed:.035 green:.055 blue:.052 alpha:1]; self.monitor.layer.magnificationFilter=kCAFilterNearest; self.monitor.userInteractionEnabled=YES; self.monitor.multipleTouchEnabled=YES;
    [self.topPanel addSubview:self.monitor];
    UIPanGestureRecognizer* pan=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(moveMouse:)];
    pan.maximumNumberOfTouches=1;[self.monitor addGestureRecognizer:pan];
    UILongPressGestureRecognizer* hold=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(fullscreenLongPress:)];
    hold.minimumPressDuration=.5;hold.numberOfTouchesRequired=1;hold.delegate=self;
    [self.view addGestureRecognizer:hold];
    UITapGestureRecognizer* twoFingerTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rightClick)];
    twoFingerTap.numberOfTouchesRequired=2;[self.monitor addGestureRecognizer:twoFingerTap];
    UITapGestureRecognizer* doubleTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleFullScreen)];
    doubleTap.numberOfTapsRequired=2;doubleTap.delegate=self;[doubleTap requireGestureRecognizerToFail:twoFingerTap];[self.monitor addGestureRecognizer:doubleTap];
    UITapGestureRecognizer* tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(leftClick:)];
    [tap requireGestureRecognizerToFail:hold];[tap requireGestureRecognizerToFail:doubleTap];[tap requireGestureRecognizerToFail:twoFingerTap];[self.monitor addGestureRecognizer:tap];
    self.status=[UILabel new]; self.status.text=@"ゲームフォルダを選択してください";
    self.status.textColor=[UIColor colorWithWhite:.24 alpha:1]; self.status.font=[UIFont monospacedSystemFontOfSize:8 weight:UIFontWeightRegular]; self.status.numberOfLines=1; self.status.adjustsFontSizeToFitWidth=YES;
    self.fpsLabel=[UILabel new];
    self.fpsLabel.font=self.status.font;
    self.fpsLabel.textColor=self.status.textColor;
    self.fpsLabel.hidden=YES;
    [self.fpsLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    self.statusRow=[[UIStackView alloc] initWithArrangedSubviews:@[self.status,self.fpsLabel,[UIView new]]];
    self.statusRow.spacing=4;
    [self.view addSubview:self.statusRow];
    self.toolbar=[UIStackView new]; self.toolbar.axis=UILayoutConstraintAxisHorizontal; self.toolbar.distribution=UIStackViewDistributionFillEqually; self.toolbar.spacing=3;
    NSArray* titles=@[@"オプション",@"開く",@"一覧",@"▶︎ / Ⅱ",@"保存",@"読込",@"リセット",@"FDD",@"右クリック"];
    SEL actions[]={@selector(showOptions),@selector(openFolder),@selector(showLibrary),@selector(togglePause),@selector(saveSlot),@selector(loadSlot),@selector(resetGame),@selector(showFloppyDrives),@selector(rightClick)};
    for(NSUInteger i=0;i<titles.count;++i) { UIButton* b=[UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:titles[i] forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; [b setTitleColor:[UIColor colorWithWhite:.18 alpha:1] forState:UIControlStateNormal]; [b setTitleColor:UIColor.grayColor forState:UIControlStateHighlighted]; b.backgroundColor=PC98Plastic(.87); b.layer.cornerRadius=2; b.layer.borderWidth=1; b.layer.borderColor=PC98Plastic(.55).CGColor; b.layer.shadowColor=UIColor.blackColor.CGColor; b.layer.shadowOffset=CGSizeMake(0,1); b.layer.shadowOpacity=.25; b.layer.shadowRadius=0; b.titleLabel.adjustsFontSizeToFitWidth=YES; [b addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside]; [self.toolbar addArrangedSubview:b]; }
    [self.view addSubview:self.toolbar];
    self.keyboard=[PC98Keyboard new]; __weak PlayerController* weak=self;
    self.keyboard.keyChanged=^(int scan,BOOL down) {
        PlayerController* s=weak; if(!s) return;
        if(down) s->touchKeys.insert(scan); else s->touchKeys.erase(scan);
        [s updateScan:scan];
    };
    self.keyboard.pauseChanged=^{ [weak togglePause]; };
    // タッチパッドモード：既存のモニタ操作と同じマウス注入経路を使う
    self.keyboard.mouseMoved=^(CGPoint delta) { [weak moveMouseBy:delta]; };
    self.keyboard.mouseClicked=^(int button) {
        PlayerController* s=weak; if(!s) return;
        if(button==2) [s rightClick]; else [s leftClick:nil];
    };
    self.keyboard.controllerSettingsOpening=^{
        PlayerController* controller=weak;
        if(controller && !controller->paused) [controller togglePause];
    };
    self.bluetoothBindings=pc98_controller_bindings([NSUserDefaults.standardUserDefaults arrayForKey:bluetoothBindingsKey]);
    [self.keyboard loadControllerBindingsForGame:@"demo"];
    // モード切替スワイプでは、ゲーム画面（モニタのキャビネット）もパネルと一緒にスライドする
    self.keyboard.swipeCompanionView=self.topPanel;
    [self.view addSubview:self.keyboard];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge]; self.spinner.color=PC98Plastic(.8); [self.topPanel addSubview:self.spinner];
    self.displayLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [NSFileManager.defaultManager createDirectoryAtURL:area(NSDocumentDirectory,@"Games") withIntermediateDirectories:YES attributes:nil error:nil];
#if TARGET_OS_SIMULATOR
    // The simulator can read the Mac's mounted NAS without an iOS SMB provider.
    // Persist only its root path; credentials remain managed by macOS.
    NSArray<NSString*>* simulatorArguments=NSProcessInfo.processInfo.arguments;
    NSUInteger nasIndex=[simulatorArguments indexOfObject:@"--simulator-nas-root"];
    if(nasIndex!=NSNotFound && nasIndex+1<simulatorArguments.count) {
        NSString* root=simulatorArguments[nasIndex+1].stringByStandardizingPath;BOOL directory=NO;
        if(root.isAbsolutePath && [NSFileManager.defaultManager fileExistsAtPath:root isDirectory:&directory] && directory) {
            [NSUserDefaults.standardUserDefaults setObject:root forKey:@"PC98SimulatorNASRoot"];
            self.status.text=@"NASを登録しました。「一覧」からゲームを選べます。";
        } else self.status.text=@"NASのフォルダーが見つかりません。Macの共有接続を確認してください。";
    }
#endif

#if __has_include(<UIKit/UIHingeInteraction.h>)
    if(@available(iOS 27.1,*)) {
        UIHingeInteraction* interaction=[[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction* interaction,UIHingeInteractionUpdate* update) {
            PlayerController* s=weak; if(!s) return;
            BOOL hardware=update.hinge!=nil;
            if(hardware) s->hingeClosed=update.hinge.status==UIHingeStatusClosed;
            else if(s->duoHardware && s->bossMode) s->hingeClosed=YES;
            [s updateBossShield];
            BOOL duo=hardware && update.hinge.status==UIHingeStatusPartiallyOpen;
            if(s->hingeDuo!=duo || s->duoHardware!=hardware) { [s releaseKeys]; s->duoHardware=hardware; s->hingeDuo=duo; [s setNeedsUpdateOfSupportedInterfaceOrientations]; [s setNeedsStatusBarAppearanceUpdate]; [s.view setNeedsLayout]; }
        }];
        self.hingeInteraction=interaction;[self.view addInteraction:interaction];
    }
#endif
    [self setFullScreenPresentation:[defaults boolForKey:launchFullscreenKey]];
    if([NSProcessInfo.processInfo.arguments containsObject:@"--demo"]) [self demo];
#ifdef PC98PLAYER_TESTING
    NSArray<NSString*>* arguments=NSProcessInfo.processInfo.arguments;
    if([arguments containsObject:@"--store-portrait"] || [arguments containsObject:@"--store-landscape"]) {
        BOOL landscape=[arguments containsObject:@"--store-landscape"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            UIWindowScene* scene=self.view.window.windowScene;
            UIWindowSceneGeometryPreferencesIOS* preference=[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:landscape?UIInterfaceOrientationMaskLandscapeLeft:UIInterfaceOrientationMaskPortrait];
            [scene requestGeometryUpdateWithPreferences:preference errorHandler:^(NSError* error) {
                [error.localizedDescription writeToURL:area(NSDocumentDirectory,@"store-capture-error.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }];
        });
    }

    NSUInteger cachedIndex=[arguments indexOfObject:@"--cached-game"];
    if(cachedIndex!=NSNotFound && cachedIndex+1<arguments.count) {
        NSString* identifier=arguments[cachedIndex+1];
        NSCharacterSet* invalid=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"] invertedSet];
        if(identifier.length && [identifier rangeOfCharacterFromSet:invalid].location==NSNotFound) {
            NSURL* cache=area(NSCachesDirectory,[@"PC98Games/" stringByAppendingString:identifier]);
            if([NSFileManager.defaultManager fileExistsAtPath:[cache URLByAppendingPathComponent:@"PC98PLAYER.INI"].path])
                [self openCache:cache identifier:identifier];
            else [self reportError:@"指定されたゲームのキャッシュがありません。" code:@"cache_missing" summary:@"ゲームのキャッシュを開けませんでした"];
        }
    }
    NSUInteger verifyIndex=[arguments indexOfObject:@"--verify-game-frames"];
    if(verifyIndex!=NSNotFound && verifyIndex+1<arguments.count && player) {
        int count=std::clamp(arguments[verifyIndex+1].intValue,60,18000);
        dispatch_async(dispatch_get_main_queue(),^{ [weak verifyGameFrames:count]; });
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
            for(int i=0;i<640*s->player->fb_h;++i) colors.insert(s->player->fb[i]);
            int peak=0;for(int16_t sample:s->player->audio) peak=std::max(peak,std::abs((int)sample));
            size_t buffered=0;uint64_t underrun=0;{ std::lock_guard<std::mutex> lock(s->audio.mutex);buffered=s->audio.samples.size();underrun=s->audio.underrunFrames; }
            AudioQueueParameterValue ramp=0;if(s->audio.queue) AudioQueueGetParameter(s->audio.queue,kAudioQueueParam_VolumeRampTime,&ramp);
            NSDictionary* report=@{@"game":s.currentID ?: @"",@"running":@(!s->paused),@"guestQuit":@(m->quit),
                @"videoColors":@(m->cfg.video_colors),@"pegcActive":@(m->pegc.on),@"crtMode":@(m->cfg.crt_mode),@"crt31":@(m->pegc.crt31),@"screenColorCount":@(colors.size()),@"framebufferHeight":@(s->player->fb_h),
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
    if([NSProcessInfo.processInfo.arguments containsObject:@"--content-filter-smoke"])
        dispatch_async(dispatch_get_main_queue(),^{ [weak contentFilterSmoke]; });
    if([NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"]) {
        [self demo];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ [weak smokeTest]; });
    }
    if([arguments containsObject:@"--feedback-error-fixture"] || [arguments containsObject:@"--feedback-normal-exit-fixture"]) {
        BOOL normal=[arguments containsObject:@"--feedback-normal-exit-fixture"];
        dispatch_async(dispatch_get_main_queue(),^{
            NSURL* fixture=area(NSCachesDirectory,@"FeedbackErrorFixture");
            [NSFileManager.defaultManager createDirectoryAtURL:fixture withIntermediateDirectories:YES attributes:nil error:nil];
            const uint8_t exitProgram[]={0xb8,0x00,0x4c,0xcd,0x21};
            [[NSData dataWithBytes:exitProgram length:sizeof(exitProgram)] writeToURL:[fixture URLByAppendingPathComponent:@"EXIT.COM"] atomically:YES];
            NSString* ini=normal?@"[PC98PLAYER]\nStart=EXIT.COM\n":@"[PC98PLAYER]\nStart=MISSING.EXE\n";
            [ini writeToURL:[fixture URLByAppendingPathComponent:@"PC98PLAYER.INI"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [weak openCache:fixture identifier:@"feedback-fixture"];
        });
    }
#endif
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self becomeFirstResponder]; [self updateBossShield]; }
- (void)updateBossShield {
    BOOL concealed=bossMode && hingeClosed;
    if(concealed) {
        [self suspend];
        if(!self.bossShield) {
            self.bossShield=[UIView new];self.bossShield.backgroundColor=UIColor.blackColor;
            self.bossShield.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
            self.bossShield.isAccessibilityElement=YES;self.bossShield.accessibilityLabel=@"ボスがきた — 一時停止中";
            self.bossShield.accessibilityViewIsModal=YES;
        }
        // Cover the window, including any presented options or file picker.
        UIWindow* window=self.view.window;
        if(window) { self.bossShield.frame=window.bounds;[window addSubview:self.bossShield]; }
    } else [self.bossShield removeFromSuperview];
}
- (void)prepareForInactive {
    // Hide before the system takes its snapshot or switches to the outer display.
    if(bossMode && duoHardware) { hingeClosed=YES;[self updateBossShield]; }
    [self suspend];
}
- (void)refreshHingeAfterActivation {
#if __has_include(<UIKit/UIHingeInteraction.h>)
    if(@available(iOS 27.1,*)) {
        UIHingeInteraction* interaction=(UIHingeInteraction*)self.hingeInteraction;
        interaction.enabled=NO;interaction.enabled=YES;
    }
#endif
    [self updateBossShield];
}
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
    CGFloat screenRatio=640.0/(player ? player->fb_h : 400);
    self.topPanel.screenAspectRatio=screenRatio;
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
    BOOL wideDuo=duoNeedsFullscreenInset(duoHardware,verticalDivision,hingeClosed,safe.size.width,safe.size.height);
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
    CGRect fullscreenAvailable=wideDuo ? CGRectInset(safe,8,8) : safe;
    NSMutableArray* occlusions=[NSMutableArray new];
#if __has_include(<UIKit/UIViewReservedRegion.h>)
    if(@available(iOS 27.1,*)) {
        for(UIViewReservedRegion* region in [self.view reservedRegionsOfKind:UIViewReservedRegionKind.occlusionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive]) {
            [occlusions addObject:@{@"frame":@[@(region.frame.origin.x),@(region.frame.origin.y),@(region.frame.size.width),@(region.frame.size.height)],@"active":@(region.isActive)}];
            if(!region.isActive) continue;
            self.topPanel.frame=monitorAvoiding(self.topPanel.frame,region.frame,screenRatio);
            fullscreenAvailable=monitorAvoiding(fullscreenAvailable,region.frame,screenRatio);
        }
    }
#endif
    CGFloat w=self.topPanel.bounds.size.width,h=self.topPanel.bounds.size.height;
    // Move controls into spare space above the keyboard when a horizontal fold permits it.
    CGFloat keyboardSlack=(self.keyboard.bounds.size.height-MIN(self.keyboard.bounds.size.height-8,(self.keyboard.bounds.size.width-4)*.44))/2;
    BOOL separateControls=duo && !verticalDivision && keyboardSlack>=54;
    self.topPanel.separateControls=separateControls;
    // ツールバーと状態表示がパネル上端に重なる配置では、タッチパッド面をその下から始める
    self.keyboard.touchpadTopInset=separateControls ? 54 : 0;
    // 同じ配置ではコントローラーのポーズ／キー設定ボタンも帯の下に置く（全画面ではツールバーが無いので対象外）
    self.keyboard.controllerTopInset=(separateControls && !fullScreen) ? 54 : 0;
    BOOL phonePortrait=self.traitCollection.userInterfaceIdiom==UIUserInterfaceIdiomPhone &&
        self.view.bounds.size.width<self.view.bounds.size.height;
    self.topPanel.framelessDisplay=phonePortrait && !verticalDivision && usesPortraitEdgeToEdge();
    self.monitor.layer.cornerRadius=(fullScreen || self.topPanel.framelessDisplay)?0:4;
    if(separateControls) {
        CGRect lower=self.keyboard.frame;
        self.toolbar.frame=CGRectMake(lower.origin.x+12,lower.origin.y+4,lower.size.width-24,32);
        self.statusRow.frame=CGRectMake(lower.origin.x+15,lower.origin.y+40,lower.size.width-30,10);
    } else {
        self.statusRow.frame=[self.topPanel convertRect:[self.topPanel statusFrame] toView:self.view];
        self.toolbar.frame=[self.topPanel convertRect:[self.topPanel controlsFrame] toView:self.view];
    }
    [self.view bringSubviewToFront:self.toolbar];
    [self.view bringSubviewToFront:self.statusRow];
    BOOL landscape=self.view.bounds.size.width>self.view.bounds.size.height;
    self.keyboard.hidden=fullScreen && !(self.fullscreenControllerOverride
        ? self.fullscreenControllerOverride.boolValue
        : (!landscape || showsLandscapeControllerByDefault()));
    BOOL duoLandscape=landscape && (duo || duoHardware) && !hingeClosed;
    self.keyboard.landscapeEdgeControls=duoLandscape || (fullScreen && phoneLandscape);
    if(fullScreen) {
        // On the open Duo, keep the normal controller frame so the overlay
        // changes appearance without moving any touch targets.
        if(!duoLandscape) {
            CGFloat availableWidth=CGRectGetWidth(safe)-12;
            CGFloat keyboardWidth=MAX(1,self.keyboard.landscapeEdgeControls?availableWidth:MIN(availableWidth,760));
            CGFloat keyboardHeight=MIN(200,MIN(keyboardWidth*.48,CGRectGetHeight(safe)*.42));
            self.keyboard.frame=CGRectMake(CGRectGetMidX(safe)-keyboardWidth/2,
                CGRectGetMaxY(safe)-keyboardHeight-4,keyboardWidth,keyboardHeight);
        }
        CGFloat width=MAX(1,MIN(fullscreenAvailable.size.width,fullscreenAvailable.size.height*screenRatio));
        CGFloat height=width/screenRatio;
        self.monitor.frame=CGRectMake(CGRectGetMidX(fullscreenAvailable)-width/2,CGRectGetMidY(fullscreenAvailable)-height/2,width,height);
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
    [self setFullScreenPresentation:!fullScreen];
    [self.view setNeedsLayout];[self.view layoutIfNeeded];
}
- (void)setFullScreenPresentation:(BOOL)value {
    if(fullScreen==value) return;
    [self releaseKeys];fullScreen=value;
    if(!fullScreen) fullscreenMenuPaused=NO;
#ifdef PC98PLAYER_TESTING
    [self.audioProbe event:fullScreen?@"fullscreen-enter":@"fullscreen-exit"];
#endif
    self.topPanel.hidden=fullScreen;
    self.keyboard.outlinesOnly=fullScreen;
    self.toolbar.hidden=fullScreen;self.statusRow.hidden=fullScreen;
    self.view.backgroundColor=fullScreen?UIColor.blackColor:PC98Plastic(.84);
    self.monitor.layer.cornerRadius=fullScreen?0:4;
    [self.monitor removeFromSuperview];
    if(fullScreen) {
        [self.view insertSubview:self.monitor belowSubview:self.keyboard];
    } else [self.topPanel addSubview:self.monitor];
    [self setNeedsStatusBarAppearanceUpdate];[self setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (void)message:(NSString*)message {
    UIAlertController* a=[UIAlertController alertControllerWithTitle:@"RetroDOS Player" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil];
}
- (void)resetFeedbackErrors {
    self.reportedErrorCodes=[NSMutableSet new];
    self.pendingFeedbackError=nil;self.pendingFeedbackImage=nil;
    self.feedbackRestorePlayback=NO;self.guestTerminationHandled=NO;
    ++self.feedbackGeneration;
}
- (NSDictionary*)feedbackDiagnostics:(NSString*)event {
    auto rect=[](CGRect r)->id { return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]; };
    NSMutableDictionary* result=[@{@"schema_version":@1,@"capture_id":NSUUID.UUID.UUIDString,
        @"captured_at":[[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
        @"event":event,@"app_version":PC98FeedbackAppVersion(),@"os_version":UIDevice.currentDevice.systemVersion,
        @"device_class":UIDevice.currentDevice.model,@"paused":@(paused.load()),@"import_in_progress":@(fetching.load()),
        @"source_mode":self.currentCache?(self.readingOriginal?@"direct":@"cache"):@"none",
        @"view_points":rect(self.view.bounds),@"monitor_points":rect([self.monitor convertRect:self.monitor.bounds toView:self.view]),
        @"display_scale":@(self.traitCollection.displayScale),@"fullscreen":@(fullScreen),
        @"hardware_keyboard_layout":@(self.keyboard.hardwareLayout),@"hinge_closed":@(hingeClosed.load()),
        @"controller_count":@(GCController.controllers.count),
        @"thermal_state":@(NSProcessInfo.processInfo.thermalState),
        @"low_power_mode":@(NSProcessInfo.processInfo.lowPowerModeEnabled)} mutableCopy];
    // Only booleans/numbers/fixed classifications: never serialize an INI,
    // source URL, bookmark, title, filename, user defaults or guest memory.
    if(self.launchDiagnostics) result[@"launch"]=self.launchDiagnostics;
    if(player && player->m) {
        Machine* m=player->m;
        result[@"runtime"]=@{@"cpu_mhz":@(m->cfg.cpu_mhz),@"sound_board":@(m->cfg.sound_board),
            @"video_colors":@(m->cfg.video_colors),@"pc9821":@(m->cfg.pc9821),@"pegc_active":@(m->pegc.on),
            @"framebuffer_pixels":@[@640,@(player->fb_h)],@"frame":@(m->frame_count),
            @"displayed_frame":@(self.displayedFrameNumber),@"guest_exit":@(m->quit),
            @"cpu_frame_ms":@(player->perf_cpu_ms),@"audio_frame_ms":@(player->perf_audio_ms)};
    }
    double elapsed=0;int frames=0;
    for(const auto& sample:fpsHistory) { elapsed+=sample.elapsed;frames+=sample.frames; }
    result[@"performance"]=@{@"fps_sample_seconds":@(elapsed),@"fps":elapsed>0?@(frames/elapsed):NSNull.null,
        @"target_fps":@((double)MASTER_CLOCK/FRAME_TICKS)};
    { std::lock_guard<std::mutex> lock(audio.mutex);
        result[@"audio"]=@{@"sample_rate":@(audio.sampleRate),@"queued_samples":@(audio.samples.size()),
            @"underrun_frames":@(audio.underrunFrames),@"started":@(audio.started),@"paused":@(audio.paused)}; }
    result[@"midi"]=@{@"fontLoaded":@(midiFontLoaded),@"mpuEnabled":@(player ? player->ps.cfg.midi : 0),
        @"messages":@(midiSynth.messageCount),@"noteOns":@(midiSynth.noteOnCount),
        @"externalOut":@(midiExternal),@"outConnected":@(midiOut.connected()),
        @"outDestination":midiOut.connectedName.empty()?@"":@(midiOut.connectedName.c_str()),
        @"outMessages":@(midiOut.messageCount),@"outSent":@(midiOut.sentCount),@"outErrors":@(midiOut.errorCount)};
    auto filter=self.contentFilter.settings;
    result[@"filter"]=@{@"adult":@(filter.adult),@"harm":@(filter.harm),@"effect":@((int)filter.effect),
        @"sensitivity":@(filter.sensitivity),@"last_processing_ms":@(self.contentFilter.lastProcessingTime*1000),
        @"has_error":@(self.contentFilter.lastError.length>0)};
    return result;
}
- (void)reportError:(NSString*)message code:(NSString*)code summary:(NSString*)summary {
    if(!self.reportedErrorCodes) self.reportedErrorCodes=[NSMutableSet new];
    if(self.pendingFeedbackError || [self.reportedErrorCodes containsObject:code]) return;
    [self.reportedErrorCodes addObject:code];
    // Freeze diagnostic values BEFORE pausing or closing audio. The image is
    // exactly the displayed, filtered image; never attach an unfiltered frame.
    BOOL runtimeContext=[code hasPrefix:@"guest_"] || [code hasPrefix:@"state_"] ||
        [code hasPrefix:@"floppy_"] || [code hasPrefix:@"title_"] || [code isEqualToString:@"media_load"];
    self.pendingFeedbackImage=runtimeContext && !(bossMode && hingeClosed)?self.monitor.image:nil;
    NSMutableDictionary* diagnostics=[[self feedbackDiagnostics:code] mutableCopy];
    if(!runtimeContext) {
        [diagnostics removeObjectForKey:@"runtime"];
        diagnostics[@"source_mode"]=usesGameCache()?@"selected_folder_cache":@"selected_folder_direct";
    }
    self.pendingFeedbackError=@{@"message":message?:summary,@"summary":summary,
        @"diagnostics":diagnostics,@"generation":@(self.feedbackGeneration)};
#ifdef PC98PLAYER_TESTING
    if([NSProcessInfo.processInfo.arguments containsObject:@"--feedback-error-fixture"])
        [[NSJSONSerialization dataWithJSONObject:diagnostics options:NSJSONWritingPrettyPrinted error:nil]
            writeToURL:area(NSDocumentDirectory,@"feedback-error-captured.json") atomically:YES];
#endif
    self.feedbackRestorePlayback=player && player->m && !player->m->quit && !paused;
    if(player && player->m && !player->m->quit) [self suspend];
    [self presentPendingFeedbackError];
}
- (void)finishErrorFeedback {
    BOOL resume=self.feedbackRestorePlayback;self.feedbackRestorePlayback=NO;
    if(resume && player && player->m && !player->m->quit && !(bossMode && hingeClosed)) {
        paused=NO;[self startAudio];nextFrame=CACurrentMediaTime();self.status.text=@"実行中";
    }
}
- (void)presentPendingFeedbackError {
    if(!self.pendingFeedbackError || self.presentedViewController || self.isBeingDismissed ||
       !self.view.window || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive ||
       (bossMode && hingeClosed)) return;
    NSDictionary* context=self.pendingFeedbackError;UIImage* image=self.pendingFeedbackImage;
    self.pendingFeedbackError=nil;self.pendingFeedbackImage=nil;
    NSUInteger generation=self.feedbackGeneration;
    UIAlertController* alert=[UIAlertController alertControllerWithTitle:@"エラーが発生しました"
        message:[context[@"message"] stringByAppendingString:@"\n\nこの状態からフィードバックできます。送信前に内容を確認できます。"]
        preferredStyle:UIAlertControllerStyleAlert];
    __weak PlayerController* weak=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:^(UIAlertAction* action) {
        if(weak.feedbackGeneration==generation) [weak finishErrorFeedback];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"フィードバックする" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        PlayerController* s=weak;if(!s || s.feedbackGeneration!=generation)return;
        [s dismissViewControllerAnimated:YES completion:^{
            if(weak.feedbackGeneration==generation)
                [weak showFeedbackImage:image diagnostics:context[@"diagnostics"] summary:context[@"summary"]];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)handleGuestTermination {
    if(!player || !player->m->quit || self.guestTerminationHandled)return;
    self.guestTerminationHandled=YES;
    [self refreshMonitor];
    using feedback_error::GuestFailure;
    auto failure=feedback_error::guestFailure(player->m);
    if(failure!=GuestFailure::None) {
        NSString* code=failure==GuestFailure::Command?@"guest_command":failure==GuestFailure::Memory?@"guest_memory":@"guest_execution";
        NSString* summary=failure==GuestFailure::Command?@"起動コマンドを実行できませんでした":failure==GuestFailure::Memory?@"ゲストのメモリが不足しています":@"ソフトウェアの実行が停止しました";
        NSString* message=player->m->status.empty()?
            (failure==GuestFailure::Command?@"Bad command or file name":failure==GuestFailure::Memory?@"Not enough memory":summary):text(player->m->status);
        [self reportError:message code:code summary:summary];
    }
    paused=YES;[self releaseKeys]; { std::lock_guard<std::mutex> lock(playerMutex); audio.close(); midiOut.allSoundOff(); }
    self.status.text=player->m->quit>=2?text(player->m->status):@"実行が終了しました";
}
- (void)updateScan:(int)scan {
    if(!player || paused) return;
    BOOL down=touchKeys.count(scan)>0 || controllerKeys.test(scan);
    for(NSInteger u:physicalKeys) if(pc98_scan_from_hid(u)==scan) down=YES;
    std::lock_guard<std::mutex> lock(playerMutex);
    machine_key(player->m,(uint8_t)scan,down);
}
- (void)updateGameControllerInput:(NSArray<GCController*>*)controllers {
    constexpr float deadZone=.45f;
    std::bitset<128> pressed;
    for(GCController* controller in controllers) {
        GCExtendedGamepad* pad=controller.extendedGamepad;
        if(!pad) continue;
        const bool controls[]={
            pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value>deadZone,
            pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value<-deadZone,
            pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value>deadZone,
            pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value<-deadZone,
            pad.buttonA.isPressed,
            pad.buttonB.isPressed
        };
        for(NSUInteger i=0;i<std::size(controls);++i)
            if(controls[i]) pressed.set(self.bluetoothBindings[i].intValue);
    }
    const auto changed=controllerKeys ^ pressed;
    if(changed.none()) return;
    controllerKeys=pressed;
    for(size_t scan=0;scan<changed.size();++scan)
        if(changed.test(scan)) [self updateScan:(int)scan];
}
- (void)releaseKeys {
    controllerKeys.reset();
    [self.keyboard releaseAll]; touchKeys.clear(); physicalKeys.clear(); mouseButtons=0;
    if(player) { std::lock_guard<std::mutex> lock(playerMutex); for(int i=0;i<128;++i) if(player->m->kb_down[i]) machine_key(player->m,i,false); machine_mouse(player->m,0,0,0); }
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
    [self moveMouseBy:delta];
}
// モニタ上のパンとタッチパッド面で共有する相対移動。感度はモニタの表示倍率（画面上の指の移動量＝カーソルの移動量）
- (void)moveMouseBy:(CGPoint)delta {
    CGFloat scale=MIN(self.monitor.bounds.size.width/640,self.monitor.bounds.size.height/(player?player->fb_h:400));
    if(player && !paused && scale>0) { std::lock_guard<std::mutex> lock(playerMutex); machine_mouse(player->m,(int)(delta.x/scale),(int)(delta.y/scale),mouseButtons); }
}
- (void)click:(int)button {
    if(!player || paused) return;
    { std::lock_guard<std::mutex> lock(playerMutex); machine_mouse(player->m,0,0,button); }
    __weak PlayerController* weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ PlayerController* s=weak; if(s && s->player) { std::lock_guard<std::mutex> lock(s->playerMutex); machine_mouse(s->player->m,0,0,0); } });
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)gesture shouldReceiveTouch:(UITouch*)touch {
    if(![gesture isKindOfClass:UILongPressGestureRecognizer.class]) return YES;
    if(!fullScreen) return touch.view==self.monitor;
    return ![touch.view isDescendantOfView:self.keyboard];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)gesture {
    if([gesture isKindOfClass:UILongPressGestureRecognizer.class])
        return player && !fetching && !player->m->quit && !self.presentedViewController &&
            !(bossMode && hingeClosed) && (fullScreen || [self.currentID isEqualToString:@"demo"] ||
                (self.displayedSourceFrame && self.monitor.image));
    if([gesture isKindOfClass:UITapGestureRecognizer.class]) {
        UITapGestureRecognizer* tapGesture=(UITapGestureRecognizer*)gesture;
        // 全画面でコントローラー枠を表示中は、操作子周辺（A/Bボタンは50pt、その他は20pt）のダブルタップを全画面解除と判定しない
        if(tapGesture.numberOfTapsRequired==2 && tapGesture.numberOfTouchesRequired==1 &&
           fullScreen && self.keyboard.outlinesOnly && !self.keyboard.hidden &&
           [self.keyboard isNearControllerControls:[gesture locationInView:self.keyboard] margin:20 actionMargin:50])
            return NO;
    }
    return YES;
}
- (void)pauseFromFullscreenMenu {
    if(!fullScreen || !player || fetching || player->m->quit) return;
    if(!paused) [self togglePause];
    fullscreenMenuPaused=YES;
    self.status.text=@"一時停止 — 画面をタップして再開";
}
- (BOOL)canRegisterTitleFrame {
    return self.currentID.length && ![self.currentID isEqualToString:@"demo"] &&
        self.monitor.image && self.displayedSourceFrame && !(bossMode && hingeClosed);
}
- (void)registerTitleImage:(UIImage*)shown source:(UIImage*)source identifier:(NSString*)identifier {
    if(![identifier isEqualToString:self.currentID] || (bossMode && hingeClosed)) return;
    CGDataProviderRef provider=source.CGImage ? CGImageGetDataProvider(source.CGImage) : nullptr;
    NSData* pixels=provider ? CFBridgingRelease(CGDataProviderCopyData(provider)) : nil;
    if(!pixels.length || !writeTitleScreenshot(shown,identifier)) {
        [self reportError:@"タイトル画面を保存できませんでした。" code:@"title_save" summary:@"タイトル画面を保存できませんでした"];
        return;
    }
    NSData* digest=titleFrameDigest(pixels.bytes,pixels.length);
    [NSUserDefaults.standardUserDefaults setObject:digest forKey:titleReferenceKey(identifier)];
    self.titleReference=digest;
    self.titleCaptureAttempted=YES;
    self.status.text=@"タイトル画面を登録しました";
}
- (UIAlertController*)fullscreenMenu {
    UIAlertController* menu=[UIAlertController alertControllerWithTitle:@"操作" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak PlayerController* weak=self;
    if(fullScreen) {
        BOOL showController=self.keyboard.hidden;
        NSString* controllerTitle=showController?@"コントローラーを表示":@"コントローラーを非表示";
        [menu addAction:[UIAlertAction actionWithTitle:paused?@"再生":@"一時停止" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            PlayerController* s=weak; if(!s) return;
            if(s->paused) [s togglePause]; else [s pauseFromFullscreenMenu];
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"リセット" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
            PlayerController* s=weak;if(!s) return;
            [s dismissViewControllerAnimated:YES completion:^{ [weak resetGame]; }];
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:controllerTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            PlayerController* s=weak;
            if(!s) return;
            [s releaseKeys];
            s.fullscreenControllerOverride=@(showController);
            [s.view setNeedsLayout];
        }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"FDD" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [weak dismissViewControllerAnimated:YES completion:^{ [weak showFloppyDrives]; }];
        }]];
    }
    if([self.currentID isEqualToString:@"demo"]) {
        BOOL use480Lines=player && player->ps.cfg.start!="DEMO480.COM";
        NSString* title=use480Lines?@"640×480（PEGC・31 kHz）に切り替え":@"640×400（標準）に切り替え";
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [weak dismissViewControllerAnimated:YES completion:^{ [weak demoWith480Lines:use480Lines]; }];
        }]];
    }
    if([self canRegisterTitleFrame]) {
        UIImage* shown=self.monitor.image;
        UIImage* source=self.displayedSourceFrame;
        NSString* identifier=self.currentID;
        [menu addAction:[UIAlertAction actionWithTitle:@"タイトル画面として登録" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [weak registerTitleImage:shown source:source identifier:identifier];
        }]];
    }
    if(self.displayedSourceFrame && self.monitor.image && !(bossMode && hingeClosed)) {
        UIImage* screenshot=self.monitor.image;
        NSDictionary* diagnostics=[self feedbackDiagnostics:@"screenshot"];
        [menu addAction:[UIAlertAction actionWithTitle:@"フィードバックする" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction* action) {
                [weak dismissViewControllerAnimated:YES completion:^{ [weak showFeedbackImage:screenshot diagnostics:diagnostics summary:nil]; }];
            }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    return menu;
}
- (void)showScreenshotFeedback:(UIImage*)screenshot {
    [self showFeedbackImage:screenshot diagnostics:[self feedbackDiagnostics:@"screenshot"] summary:nil];
}
- (void)showFeedbackImage:(UIImage*)screenshot diagnostics:(NSDictionary*)diagnostics summary:(NSString*)summary {
    if(self.presentedViewController || (bossMode && hingeClosed)) return;
    __weak PlayerController* weak=self;
    UIViewController* form=PC98FeedbackFormWithContext(PC98FeedbackAppVersion(),screenshot,diagnostics,summary,^{[weak finishErrorFeedback];});
    form.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"閉じる"
        style:UIBarButtonItemStylePlain target:self action:@selector(closeScreenshotFeedback)];
    UINavigationController* navigation=[[UINavigationController alloc] initWithRootViewController:form];
    navigation.modalInPresentation=YES;
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)closeScreenshotFeedback {
    [self dismissViewControllerAnimated:YES completion:^{[self finishErrorFeedback];}];
}
- (void)fullscreenLongPress:(UILongPressGestureRecognizer*)gesture {
    if(gesture.state!=UIGestureRecognizerStateBegan || ![self gestureRecognizerShouldBegin:gesture]) return;
    [self releaseKeys];
    UIAlertController* menu=[self fullscreenMenu];
    if(menu.popoverPresentationController) {
        CGPoint point=[gesture locationInView:self.view];
        menu.popoverPresentationController.sourceView=self.view;
        menu.popoverPresentationController.sourceRect=CGRectMake(point.x,point.y,1,1);
    }
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)leftClick:(id)sender {
    if(fullScreen && fullscreenMenuPaused && paused) { [self togglePause];return; }
    [self click:1];
}
- (void)rightClick { [self click:2]; }
- (void)resetFPS {
    fpsSampleStart=0;
    fpsSampleFrames=0;
    fpsHistory.clear();
    self.fpsLabel.hidden=YES;
}
- (void)tick:(CADisplayLink*)link {
    [self presentPendingFeedbackError];
    [self handleGuestTermination];
    BOOL acceptsControllerInput=player && !player->m->quit && !paused && !fetching &&
        !(bossMode && hingeClosed) && !self.presentedViewController &&
        self.view.window.windowScene.activationState==UISceneActivationStateForegroundActive;
    [self updateGameControllerInput:acceptsControllerInput ? GCController.controllers : nil];
    [self.keyboard updateControllerPause:paused enabled:player && !player->m->quit && !fetching && !(bossMode && hingeClosed)];
    self.topPanel.playbackState=(!player || player->m->quit)?PC98PlaybackStateInactive:paused?PC98PlaybackStatePaused:PC98PlaybackStateRunning;
    if(!player || player->m->quit || paused || fetching || (bossMode && hingeClosed)) {
        [self resetFPS];
        return;
    }
    constexpr double seconds=(double)FRAME_TICKS/MASTER_CLOCK;
    double now=CACurrentMediaTime();
    [self.keyboard repeatHeldKeys];
    // Guest frames and audio are produced on the producer thread (see
    // producerMain), so main-thread work such as layout transactions and
    // rotation can no longer starve the audio queue. The display link only
    // presents the newest frame and counts what the producer made.
    uint64_t produced=producedFrames.load();
    int frames=(int)std::min<uint64_t>(produced-lastProducedSeen,600);
    lastProducedSeen=produced;
    // Keep guest timing and audio independent of the filtered presentation rate.
    if(frames && (!self.contentFilter.settings.enabled() || player->m->quit ||
                  filterFrameHeight!=player->fb_h || (self.titleReference && !self.titleCaptureAttempted) ||
                  now-lastMonitorCapture>=1.0/20.0)) {
        [self refreshMonitor];
    }

    if(!fpsSampleStart) {
        fpsSampleStart=now;
        return;
    }
    fpsSampleFrames+=frames;
    double elapsed=now-fpsSampleStart;
    if(elapsed>=1.0 && !paused) {
        // Update every second using up to ten seconds of measured guest frames.
        fpsHistory.push_back({elapsed,fpsSampleFrames});
        if(fpsHistory.size()>10) fpsHistory.pop_front();
        double totalElapsed=0;
        int totalFrames=0;
        for(const auto& sample : fpsHistory) {
            totalElapsed+=sample.elapsed;
            totalFrames+=sample.frames;
        }
        self.fpsLabel.text=[NSString stringWithFormat:@"%.1f / %.1f fps",totalFrames/totalElapsed,1.0/seconds];
        self.fpsLabel.hidden=NO;
        fpsSampleStart=now;
        fpsSampleFrames=0;
    }
}
- (void)refreshMonitor {
    if(!player)return;
    // The producer thread writes the framebuffer; snapshot it under the lock.
    NSData* reference=self.titleReference;
    UIImage* image=nil; uint64_t imageFrame=0; BOOL matchesTitle=NO;
    {
        std::lock_guard<std::mutex> lock(playerMutex);
        if(filterFrameHeight!=player->fb_h) {
            [self.contentFilter reset];
            self.monitor.image=nil;
            filterFrameHeight=player->fb_h;
            [self.view setNeedsLayout];
        }
        lastMonitorCapture=CACurrentMediaTime();
        image=frameImage(player.get());
        imageFrame=player->m->frame_count;
        matchesTitle=reference && !self.titleCaptureAttempted &&
            !(bossMode && hingeClosed) &&
            [reference isEqualToData:titleFrameDigest(player->fb, 640 * player->fb_h * sizeof(uint32_t))];
    }
    if(self.contentFilter.settings.enabled() && !self.monitor.image)
        self.status.text=self.contentFilter.lastError?[@"保護フィルター: " stringByAppendingString:self.contentFilter.lastError]:@"保護フィルター: 判定中…";
    __weak PlayerController* weak=self;
    [self.contentFilter submitImage:image completion:^(UIImage* filtered,NSString* error) {
        PlayerController* s=weak;if(!s || !s->player)return;
        s.monitor.image=filtered;
        s.displayedFrameNumber=imageFrame;
        s.displayedSourceFrame=filtered && !error ? image : nil;
        if(error)s.status.text=[@"保護フィルター: " stringByAppendingString:error];
        else if([s.status.text hasPrefix:@"保護フィルター:"])s.status.text=s->paused?@"一時停止":s.contentFilter.settings.enabled()?@"実行中 — 保護フィルター有効":@"実行中";
        if(matchesTitle && filtered && !error && !s.titleCaptureAttempted &&
           UIApplication.sharedApplication.applicationState==UIApplicationStateActive &&
           [reference isEqualToData:s.titleReference] && !(s->bossMode && s->hingeClosed)) {
            s.titleCaptureAttempted=YES;
            s.status.text=writeTitleScreenshot(filtered,s.currentID)
                ? @"タイトル画面を保存しました" : @"タイトル画面を保存できませんでした";
        }
    }];
}
- (void)stopGame {
    [self resetFPS];
    self.displayedSourceFrame=nil;
    self.titleReference=nil;
    self.titleCaptureAttempted=NO;
    [self.contentFilter reset];self.monitor.image=nil;filterFrameHeight=0;
    fullscreenMenuPaused=NO; paused=YES; [self stopProducer]; [self releaseKeys]; audio.close(); midiSynth.reset(); midiOut.reset();
    if(player) {
        // 作ったディスクは実ファイルを入れているので、終える前に書き戻す
        for(int unit=0;unit<2;++unit) [self writeBackUserDiskForUnit:unit];
        player->shutdown(); player.reset(); [self.view setNeedsLayout];
    }
    hostfs::set_overlay("","");
    [self.scopedGameFolder stopAccessingSecurityScopedResource];
    self.scopedGameFolder=nil;
    self.readingOriginal=NO;
}
- (void)startProducer {
    [self stopProducer];
    producerStop.store(false);
    producerThread=std::thread(PC98ProducerEntry,(__bridge void*)self);
}
- (void)stopProducer {
    producerStop.store(true);
    manualDrive.store(false);
    if(producerThread.joinable()) producerThread.join();
}
// Guest execution, MIDI rendering and PCM production run on this thread, off
// the main thread, so UI work (layout transactions, rotation, sheets) can
// never starve the audio queue. playerMutex serializes guest state against
// main-thread input, presentation snapshots and lifecycle changes.
- (void)producerMain {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    pthread_setname_np("PC98PLAYER producer");
    constexpr double seconds=(double)FRAME_TICKS/MASTER_CLOCK;
    constexpr double lead=0.020; // keep ~20 ms of audio produced ahead
    while(!producerStop.load()) {
        BOOL worked=NO;
        {
            std::lock_guard<std::mutex> lock(playerMutex);
            if(player && !player->m->quit && !paused.load() && !fetching.load() && !manualDrive.load() &&
               !(bossMode && hingeClosed.load()) && audio.queue) {
                double now=CACurrentMediaTime();
                double nf=nextFrame.load();
                if(now-nf>seconds*3) nf=now; // resync after a long stall
                int frames=0;
                while(now+lead>=nf && frames<3) {
                    player->run_frame();
                    ++frames;
#ifdef PC98PLAYER_TESTING
                    [self.audioProbe appendReference:player->audio rate:player->ps.sample_rate];
#endif
                    if(midiFontLoaded && !midiExternal) midiSynth.renderMix(player->audio.data(), player->audio.size()/2);
                    audio.push(player->audio); nf+=seconds;
                    if(player->m->quit) break;
                }
                if(frames) { nextFrame.store(nf); producedFrames.fetch_add((uint64_t)frames); worked=YES; }
            }
        }
        if(!worked) std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
}
- (void)togglePause {
    if(bossMode && hingeClosed) return;
    if(!player || fetching || player->m->quit) return;
    [self releaseKeys]; paused=!paused;
    if(!paused) fullscreenMenuPaused=NO;
#ifdef PC98PLAYER_TESTING
    [self.audioProbe event:paused?@"pause":@"resume"];
#endif
    if(paused) { { std::lock_guard<std::mutex> lock(playerMutex); audio.pause(); midiSynth.allSoundOff(); midiOut.allSoundOff(); } self.status.text=@"一時停止"; }
    else { [self startAudio]; nextFrame=CACurrentMediaTime(); self.status.text=@"実行中"; }
}
- (void)startAudio {
    if(bossMode && hingeClosed) { [self suspend];return; }
    NSError* error=nil; AVAudioSession* session=AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback error:&error]; [session setActive:YES error:&error];
    BOOL opened; { std::lock_guard<std::mutex> lock(playerMutex); opened=audio.open(player->ps.sample_rate); }
    if(error || !opened) self.status.text=@"音声を開始できませんでした（映像のみ）";
}
- (void)suspend {
    [self releaseKeys]; { std::lock_guard<std::mutex> lock(playerMutex); paused=YES; audio.pause(); midiOut.allSoundOff(); }
    self.status.text=@"一時停止 — ▶︎で再開";
}
- (void)showFloppyDrives {
    if(fetching || self.presentedViewController) return;
    if(!player || player->m->quit) {
        [self message:@"ゲームまたはインストーラーを起動してから、ディスクをセットしてください。"];
        return;
    }
    UIAlertController* drives=[UIAlertController alertControllerWithTitle:@"フロッピードライブ"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    __weak PlayerController* weak=self;
    for(int unit=0;unit<2;++unit) {
        char letter=floppy::drive_letter_unit(unit);
        NSString* drive=letter ? [NSString stringWithFormat:@"%c:",letter] : [NSString stringWithFormat:@"FDD %d",unit+1];
        NSString* mounted=text(floppy::current_path_unit(unit)).lastPathComponent;
        NSString* insert=[NSString stringWithFormat:@"%@ にディスクをセット…",drive];
        [drives addAction:[UIAlertAction actionWithTitle:insert style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [weak pickFloppyForUnit:unit];
        }]];
        if(userDiskDirectory(self.currentID)) {
            NSString* create=[NSString stringWithFormat:@"%@ に空のディスクを作成…",drive];
            [drives addAction:[UIAlertAction actionWithTitle:create style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
                [weak askBlankFloppyNameForUnit:unit];
            }]];
            if([self userDiskNames].count) {
                NSString* created=[NSString stringWithFormat:@"%@ に作成したディスクをセット…",drive];
                [drives addAction:[UIAlertAction actionWithTitle:created style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
                    [weak chooseUserDiskForUnit:unit];
                }]];
            }
        }
        if(mounted.length) {
            NSString* eject=[NSString stringWithFormat:@"%@ から %@ を取り出す",drive,mounted];
            [drives addAction:[UIAlertAction actionWithTitle:eject style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
                PlayerController* s=weak;
                if(!s || !s->player) return;
                [s writeBackUserDiskForUnit:unit];
                floppy::eject_unit(unit);
                s.status.text=[NSString stringWithFormat:@"%@ のディスクを取り出しました",drive];
            }]];
        }
    }
    [drives addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:drives animated:YES completion:nil];
}
// 入っているのが作ったディスク（PC98UserDisks の下の実ファイル）なら、今の中身を同じファイルへ書き戻す（失敗は無視）
- (void)writeBackUserDiskForUnit:(int)unit {
    std::string path=floppy::current_path_unit(unit);
    FloppyImage* image=floppy::image_unit(unit);
    if(!image || !isUserDiskPath(path,self.currentID)) return;
    image->save_d88(path,nullptr);
}
// 作ったディスク（.d88）のファイル名を名前順に
- (NSArray<NSString*>*)userDiskNames {
    NSURL* directory=userDiskDirectory(self.currentID);
    if(!directory) return @[];
    NSArray<NSString*>* names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory.path error:nil] ?: @[];
    NSMutableArray<NSString*>* disks=[NSMutableArray new];
    for(NSString* name in names) if([name.pathExtension.lowercaseString isEqualToString:@"d88"]) [disks addObject:name];
    return [disks sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}
- (void)askBlankFloppyNameForUnit:(int)unit {
    if(!player || player->m->quit || fetching || !userDiskDirectory(self.currentID)) return;
    UIAlertController* alert=[UIAlertController alertControllerWithTitle:@"空のディスクを作成"
        message:@"ディスクの名前を入力してください。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
        field.text=@"ブランクディスク";
        field.clearButtonMode=UITextFieldViewModeWhileEditing;
        field.accessibilityLabel=@"ディスクの名前";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    __weak PlayerController* weak=self;
    __weak UIAlertController* weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"作成" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [weak createBlankFloppyNamed:weakAlert.textFields.firstObject.text unit:unit];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)createBlankFloppyNamed:(NSString*)requested unit:(int)unit {
    if(!player || player->m->quit || fetching) return;
    NSURL* directory=userDiskDirectory(self.currentID);
    if(!directory) return;
    [self.reportedErrorCodes removeObject:@"floppy_create"];
    // パスの区切りや制御文字を除く。空・隠しファイルになる名前は既定の名前にする
    NSMutableCharacterSet* invalid=[NSMutableCharacterSet characterSetWithCharactersInString:@"/\\:"];
    [invalid formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
    NSString* name=[[requested ?: @"" componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@""];
    name=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while([name hasPrefix:@"."]) name=[name substringFromIndex:1];
    if(!name.length) name=@"ブランクディスク";
    // .d88 以外の拡張子のままだと「作成したディスク」の一覧に出ないので、.d88 でなければ付ける
    if(![name.pathExtension.lowercaseString isEqualToString:@"d88"]) name=[name stringByAppendingPathExtension:@"d88"];
    NSFileManager* manager=NSFileManager.defaultManager;
    NSError* error=nil;
    if(![manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self reportError:error.localizedDescription code:@"floppy_create" summary:@"空のディスクを作成できませんでした"];
        return;
    }
    // 同じ名前があれば「 2」「 3」… を付けて空いている名前にする
    NSString* stem=name.stringByDeletingPathExtension, *extension=name.pathExtension;
    NSURL* disk=[directory URLByAppendingPathComponent:name];
    for(int n=2;[manager fileExistsAtPath:disk.path];++n)
        disk=[directory URLByAppendingPathComponent:[[NSString stringWithFormat:@"%@ %d",stem,n] stringByAppendingPathExtension:extension]];
    std::string reason;
    if(!floppy::create_blank_image(disk.fileSystemRepresentation,&reason)) {
        [manager removeItemAtURL:disk error:nil];
        [self reportError:[@"空のディスクを作成できませんでした。 " stringByAppendingString:text(reason)] code:@"floppy_create" summary:@"空のディスクを作成できませんでした"];
        return;
    }
    // コピーせず、作った実ファイルをそのまま入れる（書き込みはこのファイルへ残る）。入れ替える前に今のものを書き戻す
    [self writeBackUserDiskForUnit:unit];
    if(!floppy::insert_unit(unit,disk.fileSystemRepresentation,&reason)) {
        [self reportError:[@"作成したディスクをセットできませんでした。 " stringByAppendingString:text(reason)] code:@"floppy_create" summary:@"作成したディスクをセットできませんでした"];
        return;
    }
    self.status.text=[disk.lastPathComponent stringByAppendingString:@" を作成してセットしました"];
}
- (void)chooseUserDiskForUnit:(int)unit {
    if(!player || player->m->quit || fetching) return;
    NSURL* directory=userDiskDirectory(self.currentID);
    NSArray<NSString*>* names=[self userDiskNames];
    if(!directory || !names.count) return;
    UIAlertController* list=[UIAlertController alertControllerWithTitle:@"作成したディスク"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    __weak PlayerController* weak=self;
    for(NSString* name in names) {
        [list addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            PlayerController* s=weak;
            if(!s || !s->player || s->player->m->quit) return;
            [s.reportedErrorCodes removeObject:@"floppy_mount"];
            NSURL* disk=[directory URLByAppendingPathComponent:name];
            // 入れ替える前に、今入っている作ったディスクを書き戻す
            [s writeBackUserDiskForUnit:unit];
            std::string reason;
            if(!floppy::insert_unit(unit,disk.fileSystemRepresentation,&reason)) {
                [s reportError:[@"ディスクをセットできませんでした。 " stringByAppendingString:text(reason)] code:@"floppy_mount" summary:@"フロッピーディスクをセットできませんでした"];
                return;
            }
            s.status.text=[name stringByAppendingString:@" をセットしました"];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:list animated:YES completion:nil];
}
- (void)pickFloppyForUnit:(int)unit {
    UIDocumentPickerViewController* picker=[[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate=self;
    picker.allowsMultipleSelection=NO;
    picker.directoryURL=area(NSDocumentDirectory,@"Games");
    self.floppyPicker=picker;
    self.floppyPickerUnit=unit;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)mountFloppyAtURL:(NSURL*)source unit:(int)unit {
    if(!player || player->m->quit || fetching) return;
    [self.reportedErrorCodes removeObject:@"floppy_mount"];
    NSArray* supported=@[@"d88",@"d68",@"88d",@"d98",@"fdi",@"nfd",@"hdm",@"xdf",@"dup",@"tfd",@"2hd",@"img",@"scp",@"hfe"];
    if(![supported containsObject:source.pathExtension.lowercaseString]) {
        [self message:@"D88、FDI、HFEなどのフロッピーイメージを選んでください。"];
        return;
    }
    NSURL* directory=area(NSCachesDirectory,[@"PC98Floppies/" stringByAppendingString:NSUUID.UUID.UUIDString]);
    NSURL* disk=[directory URLByAppendingPathComponent:source.lastPathComponent];
    NSFileManager* manager=NSFileManager.defaultManager;
    NSError* error=nil;
    if(![manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error] ||
       ![manager copyItemAtURL:source toURL:disk error:&error]) {
        [manager removeItemAtURL:directory error:nil];
        [self reportError:error.localizedDescription code:@"floppy_mount" summary:@"フロッピーディスクを取得できませんでした"];
        return;
    }
    std::string reason;
    if(!floppy::insert_unit(unit,disk.fileSystemRepresentation,&reason)) {
        [manager removeItemAtURL:directory error:nil];
        [self reportError:[@"ディスクをセットできませんでした。 " stringByAppendingString:text(reason)] code:@"floppy_mount" summary:@"フロッピーディスクをセットできませんでした"];
        return;
    }
    self.status.text=[disk.lastPathComponent stringByAppendingString:@" をセットしました"];
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
    if(controller==self.floppyPicker) { self.floppyPicker=nil; return; }
    paused=pickerPreviousPause; if(player && !paused) [self startAudio]; nextFrame=CACurrentMediaTime();
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if(controller==self.floppyPicker) {
        self.floppyPicker=nil;
        if(urls.count) [self mountFloppyAtURL:urls.firstObject unit:self.floppyPickerUnit];
        return;
    }
    if(urls.count) [self openSource:urls.firstObject identifier:registeredGameID(urls.firstObject)];
}
- (void)openSource:(NSURL*)source identifier:(NSString*)identifier {
    if(fetching)return;
    [self resetFeedbackErrors];self.launchDiagnostics=nil;
    if(usesGameCache()) { [self cacheSource:source identifier:identifier]; return; }
    if(fetching) return;
    BOOL scoped=[source startAccessingSecurityScopedResource];
    NSNumber* directory=nil;
    NSError* error=nil;
    if(![source getResourceValue:&directory forKey:NSURLIsDirectoryKey error:&error] || !directory.boolValue) {
        if(scoped) [source stopAccessingSecurityScopedResource];
        [self reportError:error.localizedDescription code:@"source_open" summary:@"ゲームフォルダを開けませんでした"];
        return;
    }
    NSString* name=catalogNameForFolder(source) ?: source.lastPathComponent;
    if([GameLibrary rememberURL:source name:name error:nil]) {
        [NSUserDefaults.standardUserDefaults setObject:identifier forKey:sourceIDKey(source)];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:libraryHiddenKey(identifier)];
    }
    [self openGameFolder:source identifier:identifier direct:YES];
    if(scoped) [source stopAccessingSecurityScopedResource];
}
- (void)cacheSource:(NSURL*)source identifier:(NSString*)identifier {
    if(fetching) return;
    fetching=YES; [self suspend]; [self.spinner startAnimating]; self.status.text=@"ゲームデータをキャッシュしています…";
    BOOL scoped=[source startAccessingSecurityScopedResource];
    NSURL* destination=area(NSCachesDirectory,[@"PC98Games/" stringByAppendingString:identifier]);
    __weak PlayerController* weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool {
            NSError* error=nil;
            // An explicit folder selection is a request to import its current contents.
            [GameLibrary refreshCacheFromURL:source toURL:destination error:&error];
            NSString* displayName=error ? source.lastPathComponent : catalogNameForFolder(destination) ?: source.lastPathComponent;
            dispatch_async(dispatch_get_main_queue(), ^{
                PlayerController* s=weak;
                if(s && !error && [GameLibrary rememberURL:source name:displayName error:nil]) {
                    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:sourceIDKey(source)];
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:libraryHiddenKey(identifier)];
                }
                if(scoped) [source stopAccessingSecurityScopedResource];
                if(!s) return;
                s->fetching=NO; [s.spinner stopAnimating];
#if defined(PC98PLAYER_TESTING)
                NSDictionary* report=@{@"sourceName":source.lastPathComponent ?: @"", @"scoped":@(scoped), @"identifier":identifier, @"error":error.localizedDescription ?: @"", @"domain":error.domain ?: @"", @"code":@(error.code), @"usableCache":@([GameLibrary isUsableCacheAtURL:destination])};
                [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:area(NSDocumentDirectory,@"cache-import-report.json") atomically:YES];
#endif
                if(error) { s.status.text=error.localizedDescription; [s reportError:error.localizedDescription code:@"cache_import" summary:@"ゲームデータを取得できませんでした"]; }
                else [s openCache:destination identifier:identifier];
            });
        }
    });
}
- (BOOL)prepareLocalProgram:(NSURL*)program root:(NSURL*)root settings:(PlayerSettings&)settings {
    if([GameLibrary isWindowsProgramAtURL:program]) {
        [self reportError:@"この実行ファイルはWindows用です。PC-98／DOS用の起動ファイルを選んでください。" code:@"windows_program" summary:@"Windows用の実行ファイルが選択されています"];
        return NO;
    }
    NSURL* launchFolder=[GameLibrary launchFolderForProgram:program relativeToRoot:root];
    if(![launchFolder.path isEqualToString:root.path]) {
        settings.cfg.root=launchFolder.fileSystemRepresentation;
        settings.cfg.start=program.lastPathComponent.UTF8String;
    }
    return YES;
}
- (void)openCache:(NSURL*)cache identifier:(NSString*)identifier {
    [self openGameFolder:cache identifier:identifier direct:NO];
}
- (void)openGameFolder:(NSURL*)folder identifier:(NSString*)identifier direct:(BOOL)direct {
    [self resetFeedbackErrors];self.launchDiagnostics=nil;
    BOOL scoped=direct && [folder startAccessingSecurityScopedResource];
    NSURL* cache=folder.URLByStandardizingPath.URLByResolvingSymlinksInPath;
    [self stopGame];
    self.scopedGameFolder=scoped ? folder : nil;
    self.readingOriginal=direct;
    self.currentCache=direct ? folder : cache;
    self.currentID=identifier;
    [self.keyboard loadControllerBindingsForGame:identifier];
    NSString* saves=[@"PC98Saves/" stringByAppendingString:identifier];
    NSURL* saved=area(NSApplicationSupportDirectory,[saves stringByAppendingPathComponent:@"files"]);
    NSError* error=nil;
    if(![NSFileManager.defaultManager createDirectoryAtURL:saved withIntermediateDirectories:YES attributes:nil error:&error]) { [self reportError:error.localizedDescription code:@"save_directory" summary:@"保存領域を作成できませんでした"]; return; }
    hostfs::set_overlay(cache.fileSystemRepresentation,saved.fileSystemRepresentation);
    NSURL* iniURL=[cache URLByAppendingPathComponent:@"PC98PLAYER.INI"];
    Ini ini;
    BOOL loadedINI=ini.load(iniURL.fileSystemRepresentation);
    self.launchDiagnostics=@{@"ini_loaded":@(loadedINI),@"ini_present":@([NSFileManager.defaultManager fileExistsAtPath:iniURL.path]),
        @"ini_has_start":@(!ini.get("PC98PLAYER.START").empty()),@"ini_has_root":@(!ini.get("PC98PLAYER.ROOT").empty())};
    NSString* configured=text(ini.get("PC98PLAYER.ROOT"));
    NSURL* root=[GameLibrary gameRootAtURL:cache relativePath:configured error:&error];
    if(!root) {
        [self reportError:[@"Root= の指定先を開けません。ゲームフォルダ内の相対パスと取得状態を確認してください。\n" stringByAppendingString:error.localizedDescription ?: @""] code:@"invalid_root" summary:@"INIのRoot指定先を開けませんでした"]; return;
    }
    PlayerSettings ps; player_settings_from_ini(ini,root.fileSystemRepresentation,&ps);
    NSInteger clock=[NSUserDefaults.standardUserDefaults integerForKey:gameClockKey(identifier)];
    if(!validClockMHz(clock)) clock=[NSUserDefaults.standardUserDefaults integerForKey:defaultClockKey];
    if(validClockMHz(clock)) ps.cfg.cpu_mhz=(int)clock;
    NSNumber* sound=[NSUserDefaults.standardUserDefaults objectForKey:@"PC98SoundBoard"];
    NSNumber* colors=[NSUserDefaults.standardUserDefaults objectForKey:@"PC98VideoColors"];
    if(sound) ps.cfg.sound_board=sound.integerValue==26?26:86;
    if(colors) apple_set_video_colors(ps.cfg,(int)colors.integerValue);
    else {
        // The existing 16/256-color option is authoritative on iOS; no blocking prompt.
        apple_set_video_colors(ps.cfg,ps.cfg.pc9821 || ps.cfg.video_colors==256 ? 256 : 16);
    }
    if([identifier isEqualToString:@"demo"])
        apple_set_video_colors(ps.cfg,ps.cfg.start=="DEMO480.COM" ? 256 : 16);
    apple_apply_crt_mode(ps.cfg,(int)displayModeForGame(identifier));   // 色数のあとに画面モード
    midiExternal=midiUsesExternalOut();
    // 外部出力時はサウンドフォントが無くても MPU を有効にする（送り先は launchSettings で開く）
    ps.cfg.midi=(midiFontLoaded || midiExternal) ? 1 : 0; ps.cfg.trace=0; ps.sample_rate=std::clamp(ps.sample_rate,8000,192000);
    if(ps.cfg.start.empty() && !ps.cfg.boot_fd) {
        NSString* explanation;
        if(loadedINI)
            explanation=@"PC98PLAYER.INI に起動指定がありません。[PC98PLAYER] の下に Start=実行ファイル名 を記入してください。";
        else if([NSFileManager.defaultManager fileExistsAtPath:iniURL.path])
            explanation=@"PC98PLAYER.INI を読み込めませんでした。ファイルを確認してください。";
        else
            explanation=@"選んだフォルダの直下に PC98PLAYER.INI がありません。ここから起動ファイルを選べます。";
        [self chooseProgram:root settings:ps explanation:explanation];
        return;
    }
    // An INI may give a literal path containing spaces. Resolve it on the
    // host first, before the DOS shell interprets the path as a command.
    NSString* start=text(ps.cfg.start);
    NSString* relative=[start stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if(!ps.cfg.boot_fd && relative.length && !relative.isAbsolutePath && ![relative containsString:@":"]) {
        NSURL* program=[root URLByAppendingPathComponent:relative].URLByStandardizingPath.URLByResolvingSymlinksInPath;
        NSNumber* regular=nil;
        if([GameLibrary relativePathForProgram:program inRoot:root] &&
           [program getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] && regular.boolValue &&
           ![self prepareLocalProgram:program root:root settings:ps]) return;
    }
    [self launchSettings:ps];
}
- (void)chooseProgram:(NSURL*)root settings:(PlayerSettings)settings explanation:(NSString*)explanation {
    NSMutableArray* programs=[NSMutableArray new];
    __block NSError* scanError=nil;
    NSDirectoryEnumerator* e=[NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:@[NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL* url,NSError* error) { scanError=error; return NO; }];
    for(NSURL* url in e) {
        if([@[@"bat",@"com",@"exe"] containsObject:url.pathExtension.lowercaseString]) {
            NSNumber* regular=nil; if(![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:&scanError]) break;
            if(!regular.boolValue || [GameLibrary isWindowsProgramAtURL:url]) continue;
            NSString* relative=[GameLibrary relativePathForProgram:url inRoot:root];
            if(relative) [programs addObject:relative];
        }
    }
    if(scanError) { [self reportError:[@"ゲームフォルダを読み取れません。取得状態を確認してください。\n" stringByAppendingString:scanError.localizedDescription] code:@"folder_scan" summary:@"ゲームフォルダを読み取れませんでした"]; return; }
    if(!programs.count) { [self reportError:@"起動ファイルがありません。ZIPを展開し、BAT・COM・EXEのあるフォルダを選んでください。iCloudでは「ファイル」でダウンロード完了を確認してください。以前取得した内容が不完全な場合は「一覧」でゲーム本体のキャッシュを消去して再取得してください（セーブは保持されます）。" code:@"no_program" summary:@"起動ファイルが見つかりませんでした"]; return; }
    [programs sortUsingSelector:@selector(localizedStandardCompare:)];
    FileChooser* chooser=[FileChooser new]; chooser.title=@"起動するプログラム"; chooser.paths=programs; chooser.explanation=explanation;
    __weak PlayerController* weak=self;
    chooser.selected=^(NSString* selected) {
        PlayerController* controller=weak;
        if(!controller) return;
        PlayerSettings chosen=settings;
        chosen.cfg.start=selected.UTF8String;
        NSURL* program=[root URLByAppendingPathComponent:selected];
        if([controller prepareLocalProgram:program root:root settings:chosen]) [controller launchSettings:chosen];
    };
    UINavigationController* navigation=[[UINavigationController alloc] initWithRootViewController:chooser];
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)launchSettings:(PlayerSettings)settings {
    self.guestTerminationHandled=NO;
    NSMutableDictionary* launch=[self.launchDiagnostics mutableCopy] ?: [NSMutableDictionary new];
    launch[@"cpu_mhz"]=@(settings.cfg.cpu_mhz);launch[@"video_colors"]=@(settings.cfg.video_colors);
    launch[@"sound_board"]=@(settings.cfg.sound_board);launch[@"floppy_boot"]=@(settings.cfg.boot_fd);
    launch[@"program_selected"]=@(!settings.cfg.start.empty());self.launchDiagnostics=launch;
    [self stopProducer];
    midiSynth.reset();   // 前のゲームの発音・チャンネル設定を残さない
    if(midiFontLoaded && midiSynth.outputRate!=settings.sample_rate) midiSynth.setOutputRate(settings.sample_rate);
    midiDispatch.synth=&midiSynth; midiDispatch.out=&midiOut; midiDispatch.external=midiExternal;
    if(midiExternal) {
        NSString* destinationName=[NSUserDefaults.standardUserDefaults stringForKey:midiDestinationNameKey];
        midiOut.open((int32_t)[NSUserDefaults.standardUserDefaults integerForKey:midiDestinationIDKey],
                     destinationName ? destinationName.UTF8String : "");
        midiOut.reset();   // 前のゲームの発音・コントローラー設定を外部音源へ残さない
    }
    player=std::make_unique<Player>(); mac_install_font(settings.font_name,settings.font_shift); std::string error;
    player->midi_user=&midiDispatch; player->midi_sink=&MidiSinkTrampoline;
    settings.cfg.start = apple_startup::dos_start_path(settings.cfg.start);
    if(!player->init(settings,&error)) { [self reportError:text(error) code:@"launch_failed" summary:@"ソフトウェアを起動できませんでした"]; [self stopGame]; return; }
    paused=NO; nextFrame=CACurrentMediaTime(); self.status.text=self.readingOriginal ? @"実行中 — 元フォルダを直接読込、保存データは別領域" : @"実行中 — ゲーム本体はキャッシュ、保存データは別領域";
#if TARGET_OS_SIMULATOR
    NSString* nasPath=[NSUserDefaults.standardUserDefaults stringForKey:@"PC98SimulatorNASRoot"];
    if(nasPath.length && [self.currentCache.path hasPrefix:[nasPath stringByAppendingString:@"/"]])
        self.status.text=@"実行中 — NASを直接読込、保存データは別領域";
#endif

    if(self.currentID.length && ![self.currentID isEqualToString:@"demo"])
        self.titleReference=[NSUserDefaults.standardUserDefaults dataForKey:titleReferenceKey(self.currentID)];
    self.titleCaptureAttempted=NO;
    [self startAudio]; [self startProducer]; [self becomeFirstResponder];
    NSString* warnings=@"";
    for(auto* e:{&player->floppy_error,&player->cd_error,&player->rhythm_error}) if(!e->empty()) warnings=[warnings stringByAppendingFormat:@"%@\n",text(*e)];
    if(warnings.length) [self reportError:warnings code:@"media_load" summary:@"ディスクまたは音源データを読み込めませんでした"];
}
- (void)slots:(BOOL)load {
    if(!player || fetching) return;
    [self releaseKeys]; { std::lock_guard<std::mutex> lock(playerMutex); audio.clear(); }
    UIAlertController* menu=[UIAlertController alertControllerWithTitle:load?@"ステート読込":@"ステート保存" message:nil preferredStyle:UIAlertControllerStyleAlert];
    __weak PlayerController* weak=self;
    for(int slot=0;slot<STATE_SLOTS;++slot) [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"スロット %d",slot+1] style:UIAlertActionStyleDefault handler:^(UIAlertAction* a) {
        PlayerController* s=weak; if(!s || !s->player) return;
        [s.reportedErrorCodes removeObject:load?@"state_load":@"state_save"];
        std::string error; BOOL ok; { std::lock_guard<std::mutex> lock(s->playerMutex); ok=load?s->player->load_state(slot,&error):s->player->save_state(slot,&error); }
        // A failed load preserves the current state and its filtered screenshot.
        if(load && ok) { [s.contentFilter reset];s.monitor.image=nil; }
        [s releaseKeys]; { std::lock_guard<std::mutex> lock(s->playerMutex); s->audio.clear(); } s->nextFrame=CACurrentMediaTime();
        if(!ok) [s reportError:text(error) code:load?@"state_load":@"state_save" summary:load?@"ステートを読み込めませんでした":@"ステートを保存できませんでした"]; else s.status.text=load?@"ステートを読み込みました":@"ステートを保存しました";
        if(s->player) [s refreshMonitor];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)saveSlot { [self slots:NO]; }
- (void)loadSlot { [self slots:YES]; }
- (void)showOptions {
    if(fetching || self.presentedViewController) return;
    NSDictionary* diagnostics=[self feedbackDiagnostics:@"options"];
    BOOL previousPause=paused;[self suspend];
    GameOptionsController* options=[[GameOptionsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    options.issueDiagnostics=diagnostics;
    if(self.displayedSourceFrame && !(bossMode && hingeClosed)) options.issueScreenshot=self.monitor.image;
    options.soundBoard=player?player->m->cfg.sound_board:([NSUserDefaults.standardUserDefaults objectForKey:@"PC98SoundBoard"]? [NSUserDefaults.standardUserDefaults integerForKey:@"PC98SoundBoard"]:86);
    options.videoColors=player?player->m->cfg.video_colors:([NSUserDefaults.standardUserDefaults objectForKey:@"PC98VideoColors"]? [NSUserDefaults.standardUserDefaults integerForKey:@"PC98VideoColors"]:16);
    options.displayMode=[NSUserDefaults.standardUserDefaults integerForKey:displayModeKey];
    options.midiMode=midiUsesExternalOut()?1:0;
    options.midiDestinationID=[NSUserDefaults.standardUserDefaults integerForKey:midiDestinationIDKey];
    options.midiDestinationName=[NSUserDefaults.standardUserDefaults stringForKey:midiDestinationNameKey] ?: @"";
    NSInteger defaultClock=[NSUserDefaults.standardUserDefaults integerForKey:defaultClockKey];
    options.clockMHz=validClockMHz(defaultClock) ? defaultClock : 0;
    __weak PlayerController* weak=self;
    options.cacheOnLaunch=usesGameCache();
    options.portraitEdgeToEdge=usesPortraitEdgeToEdge();
    options.landscapeControllerDefault=showsLandscapeControllerByDefault();
    options.launchFullscreen=[NSUserDefaults.standardUserDefaults boolForKey:launchFullscreenKey];
    options.manualDuo=manualDuo;options.bossMode=bossMode;options.filterSettings=self.contentFilter.settings;
    BOOL previousLandscapeControllerDefault=options.landscapeControllerDefault;
    options.willApply=^(content_filter::Settings filter) {
        PlayerController* s=weak;if(s && filter.enabled()) { [s.contentFilter reset];s.monitor.image=nil; }
    };
    options.cancelled=^{ PlayerController* s=weak;if(!s) return;s->paused=previousPause;if(s->player && !s->paused) [s startAudio];s->nextFrame=CACurrentMediaTime(); };
    options.applied=^(NSInteger sound,NSInteger colors,NSInteger display,BOOL duo,BOOL boss,content_filter::Settings filter) {
        PlayerController* s=weak;if(!s) return;
        if(previousLandscapeControllerDefault!=showsLandscapeControllerByDefault()) s.fullscreenControllerOverride=nil;
        [NSUserDefaults.standardUserDefaults setInteger:display forKey:displayModeKey];
        BOOL restart=s->player && (s->player->m->cfg.sound_board!=sound || s->player->m->cfg.video_colors!=colors ||
            s->player->m->cfg.crt_mode!=displayModeForGame(s.currentID));
        [s.contentFilter configure:filter];s.monitor.image=nil;
        [NSUserDefaults.standardUserDefaults setBool:filter.adult forKey:@"PC98AdultFilter"];
        [NSUserDefaults.standardUserDefaults setBool:filter.harm forKey:@"PC98HarmFilter"];
        [NSUserDefaults.standardUserDefaults setInteger:(int)filter.effect forKey:@"PC98FilterEffect"];
        [NSUserDefaults.standardUserDefaults setInteger:filter.sensitivity forKey:@"PC98FilterSensitivity"];
        [s releaseKeys];s->manualDuo=duo;s->bossMode=boss;
        s.bluetoothBindings=pc98_controller_bindings([NSUserDefaults.standardUserDefaults arrayForKey:bluetoothBindingsKey]);
        [NSUserDefaults.standardUserDefaults setBool:boss forKey:@"PC98BossMode"];
        [NSUserDefaults.standardUserDefaults setBool:duo forKey:@"PC98ManualDuo"];
        [s setNeedsUpdateOfSupportedInterfaceOrientations];[s setNeedsStatusBarAppearanceUpdate];[s.view setNeedsLayout];
        [NSUserDefaults.standardUserDefaults setInteger:sound forKey:@"PC98SoundBoard"];
        [NSUserDefaults.standardUserDefaults setInteger:colors forKey:@"PC98VideoColors"];
        if(restart && s.currentCache && s.currentID) [s openGameFolder:s.currentCache identifier:s.currentID direct:s.readingOriginal];
        else if(s->player) { s->paused=previousPause;if(!s->paused) [s startAudio];s->nextFrame=CACurrentMediaTime(); }
        else s.status.text=@"オプションを保存しました。ゲームフォルダーを選択してください。";
        [s refreshMonitor];[s updateBossShield];
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
        PlayerController* s=weak;if(s) [s openGameFolder:s.currentCache identifier:s.currentID direct:s.readingOriginal];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)addLibraryGameTo:(GameLocationsController*)menu identifier:(NSString*)identifier
                 folder:(NSURL*)folder cache:(NSURL*)cache catalogName:(NSString*)catalogName
               fallback:(NSString*)fallback action:(void (^)(void))action {
    NSUserDefaults* defaults=NSUserDefaults.standardUserDefaults;
    NSString* hiddenKey=libraryHiddenKey(identifier);
    if([defaults boolForKey:hiddenKey]) return;
    NSString* key=libraryTitleKey(identifier);
    NSString* custom=[defaults stringForKey:key];
    NSString* display=custom ?: catalogName ?: fallback;
    __weak GameLocationsController* weakMenu=menu;
    __weak PlayerController* weak=self;
    void (^refresh)(void)=^{
        [weakMenu.navigationController.presentingViewController dismissViewControllerAnimated:NO completion:^{ [weak showLibrary]; }];
    };
    void (^removeGame)(void)=^{
        [defaults setBool:YES forKey:hiddenKey];
        [GameLibrary forgetURL:folder];
    };
    [menu addGame:display identifier:identifier cached:(cache && [GameLibrary isUsableCacheAtURL:cache]) action:action info:^{
        GameLocationsController* list=weakMenu;
        if(!list) return;
        BOOL cached=cache && [NSFileManager.defaultManager fileExistsAtPath:cache.path];
        NSString* clockKey=gameClockKey(identifier);
        NSInteger clock=[defaults integerForKey:clockKey];
        NSString* clockLabel=validClockMHz(clock) ? [NSString stringWithFormat:@"%ld MHz",(long)clock] : @"デフォルト";
        NSString* displayKey=gameDisplayModeKey(identifier);
        NSNumber* gameMode=[defaults objectForKey:displayKey];
        NSString* displayLabel=gameMode ? displayModeLabels[displayModeForGame(identifier)] : @"デフォルト";
        NSString* info=[NSString stringWithFormat:@"ソフト名  %@\nフォルダ名  %@\n作品DB  %@\nキャッシュ  %@\nCPUクロック  %@\n画面モード  %@",
            catalogName ?: fallback,folder.lastPathComponent,catalogName ? @"照合済み" : @"未確認",cached ? @"保存済み" : @"なし",clockLabel,displayLabel];
        UIAlertController* details=[UIAlertController alertControllerWithTitle:display message:info preferredStyle:UIAlertControllerStyleAlert];
        [details addAction:[UIAlertAction actionWithTitle:@"CPUクロックを設定" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            UIAlertController* clocks=[UIAlertController alertControllerWithTitle:@"このゲームのCPUクロック"
                message:@"選んだ設定は次回のゲーム起動から適用します。" preferredStyle:UIAlertControllerStyleAlert];
            void (^saveClock)(NSInteger)=^(NSInteger value) {
                if(value) [defaults setInteger:value forKey:clockKey];
                else [defaults removeObjectForKey:clockKey];
            };
            for(NSInteger value:clockPresets) {
                NSString* label=value ? [NSString stringWithFormat:@"%ld MHz",(long)value] : @"デフォルトを使用";
                [clocks addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction* selected) {
                    saveClock(value);
                }]];
            }
            [clocks addAction:[UIAlertAction actionWithTitle:@"任意の周波数" style:UIAlertActionStyleDefault handler:^(UIAlertAction* selected) {
                presentCustomClock(weakMenu,validClockMHz(clock) ? clock : 0,saveClock);
            }]];
            [clocks addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
            [weakMenu presentViewController:clocks animated:YES completion:nil];
        }]];
        [details addAction:[UIAlertAction actionWithTitle:@"画面モードを設定" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            UIAlertController* modes=[UIAlertController alertControllerWithTitle:@"このゲームの画面モード"
                message:@"選んだ設定は次回のゲーム起動から適用します。" preferredStyle:UIAlertControllerStyleAlert];
            [modes addAction:[UIAlertAction actionWithTitle:@"デフォルトを使用" style:UIAlertActionStyleDefault handler:^(UIAlertAction* selected) {
                [defaults removeObjectForKey:displayKey];
            }]];
            for(NSInteger value=0;value<3;++value)
                [modes addAction:[UIAlertAction actionWithTitle:displayModeLabels[value] style:UIAlertActionStyleDefault handler:^(UIAlertAction* selected) {
                    [defaults setInteger:value forKey:displayKey];
                }]];
            [modes addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
            [weakMenu presentViewController:modes animated:YES completion:nil];
        }]];
        [details addAction:[UIAlertAction actionWithTitle:@"タイトル名を編集" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            UIAlertController* edit=[UIAlertController alertControllerWithTitle:@"タイトル名を編集"
                message:@"空欄で保存すると自動表示名に戻ります。" preferredStyle:UIAlertControllerStyleAlert];
            [edit addTextFieldWithConfigurationHandler:^(UITextField* field) { field.text=custom; field.placeholder=catalogName ?: fallback; }];
            [edit addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
            __weak UIAlertController* weakEdit=edit;
            [edit addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction* save) {
                NSString* title=[weakEdit.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if(title.length) [defaults setObject:title forKey:key];
                else [defaults removeObjectForKey:key];
                refresh();
            }]];
            [weakMenu presentViewController:edit animated:YES completion:nil];
        }]];
        if(cached) {
            [details addAction:[UIAlertAction actionWithTitle:@"このゲームのキャッシュを削除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
                UIAlertController* confirm=[UIAlertController alertControllerWithTitle:@"キャッシュを削除しますか？"
                    message:@"元フォルダと保存データは保持されます。" preferredStyle:UIAlertControllerStyleAlert];
                [confirm addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
                [confirm addAction:[UIAlertAction actionWithTitle:@"削除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* deleteAction) {
                    PlayerController* controller=weak;
                    if([controller.currentID isEqualToString:identifier]) {
                        [controller stopGame];
                        controller.currentCache=nil;
                        controller.currentID=nil;
                    }
                    NSError* error=nil;
                    if([NSFileManager.defaultManager fileExistsAtPath:cache.path] &&
                       ![NSFileManager.defaultManager removeItemAtURL:cache error:&error]) {
                        UIAlertController* failure=[UIAlertController alertControllerWithTitle:@"キャッシュを削除できませんでした"
                            message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                        [failure addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
                        [weakMenu presentViewController:failure animated:YES completion:nil];
                        return;
                    }
                    refresh();
                }]];
                [weakMenu presentViewController:confirm animated:YES completion:nil];
            }]];
        }
        PlayerController* controller=weak;
        if(controller && [identifier isEqualToString:controller.currentID] && [controller canRegisterTitleFrame]) {
            UIImage* shown=controller.monitor.image;
            UIImage* source=controller.displayedSourceFrame;
            [details addAction:[UIAlertAction actionWithTitle:@"今の画面をタイトル画面として登録"
                style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
                [weak registerTitleImage:shown source:source identifier:identifier];
                refresh();
            }]];
        }
        if([defaults objectForKey:titleReferenceKey(identifier)]) {
            [details addAction:[UIAlertAction actionWithTitle:@"タイトル画面の自動保存を解除"
                style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
                [defaults removeObjectForKey:titleReferenceKey(identifier)];
                PlayerController* current=weak;
                if([identifier isEqualToString:current.currentID]) current.titleReference=nil;
            }]];
        }
        [details addAction:[UIAlertAction actionWithTitle:@"一覧から削除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
            UIAlertController* confirm=[UIAlertController alertControllerWithTitle:@"一覧から削除しますか？"
                message:display preferredStyle:UIAlertControllerStyleAlert];
            [confirm addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
            [confirm addAction:[UIAlertAction actionWithTitle:@"削除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
                removeGame();
                refresh();
            }]];
            [weakMenu presentViewController:confirm animated:YES completion:nil];
        }]];
        [details addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
        [list presentViewController:details animated:YES completion:nil];
    } remove:removeGame];
}
- (void)showLibrary {
    if(fetching || self.presentedViewController) return;
    GameLocationsController* menu=[GameLocationsController new];
    menu.message=@"「開く」から、このiPhone内／ファイルで接続したNASのフォルダを選べます。元データは書き換えません。";
    __weak PlayerController* weak=self;
    NSArray<NSDictionary*>* entries=GameLibrary.entries;
    NSMutableSet<NSString*>* registered=[NSMutableSet new];
    NSMutableSet<NSString*>* registeredPaths=[NSMutableSet new];
    for(NSDictionary* entry in entries) {
        NSURL* original=[NSURL fileURLWithPath:entry[@"path"] isDirectory:YES];
        [registered addObject:registeredGameID(original)];
        [registeredPaths addObject:original.URLByStandardizingPath.URLByResolvingSymlinksInPath.path];
    }
#if TARGET_OS_SIMULATOR
    NSString* nasPath=[NSUserDefaults.standardUserDefaults stringForKey:@"PC98SimulatorNASRoot"];
    if(nasPath.length) {
        NSError* nasError=nil;
        NSArray<NSURL*>* folders=[NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:nasPath isDirectory:YES]
            includingPropertiesForKeys:@[NSURLIsDirectoryKey,NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:&nasError];
        menu.message=nasError?@"NASに接続できません。Macで共有をマウントし直してください。":@"NASのゲームを一覧から開けます。保存データは別領域に保持します。";
        for(NSURL* source in [folders sortedArrayUsingComparator:^NSComparisonResult(NSURL* a,NSURL* b) { return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent]; }]) {
            NSNumber* directory=nil;NSNumber* symlink=nil;
            [source getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
            [source getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:nil];
            NSURL* iniURL=[source URLByAppendingPathComponent:@"PC98PLAYER.INI"];
            if(!directory.boolValue || symlink.boolValue || ![NSFileManager.defaultManager fileExistsAtPath:iniURL.path]) continue;
            Ini ini;ini.load(iniURL.fileSystemRepresentation);
            NSString* title=text(ini.get("PC98PLAYER.TITLE"));if(!title.length) title=source.lastPathComponent;
            NSString* identifier=gameID(source);
            if([registeredPaths containsObject:source.URLByStandardizingPath.URLByResolvingSymlinksInPath.path]) continue;
            [registered addObject:identifier];
            NSURL* cache=area(NSCachesDirectory,[@"PC98Games/" stringByAppendingString:identifier]);
            [self addLibraryGameTo:menu identifier:identifier folder:source cache:cache
                catalogName:catalogNameForFolder(source) fallback:title action:^{
                if(usesGameCache() && [GameLibrary isUsableCacheAtURL:cache]) [weak openCache:cache identifier:identifier];
                else [weak openSource:source identifier:identifier];
            }];
        }
    }
#endif
    for(NSDictionary* entry in entries) {
        NSURL* original=[NSURL fileURLWithPath:entry[@"path"] isDirectory:YES];
        NSString* gameIdentifier=registeredGameID(original);
        [registered addObject:gameIdentifier];
        NSURL* cached=area(NSCachesDirectory,[@"PC98Games/" stringByAppendingString:gameIdentifier]);
        NSString* catalogName=catalogNameForFolder(cached);
        if(!catalogName && ![NSFileManager.defaultManager fileExistsAtPath:cached.path] &&
           ![entry[@"name"] isEqualToString:original.lastPathComponent]) catalogName=entry[@"name"];
        [self addLibraryGameTo:menu identifier:gameIdentifier folder:original cache:cached
            catalogName:catalogName fallback:original.lastPathComponent action:^{
            if(usesGameCache() && [GameLibrary isUsableCacheAtURL:cached]) { [weak openCache:cached identifier:gameIdentifier]; return; }
            NSError* error=nil;
            NSURL* source=[GameLibrary resolveEntry:entry error:&error];
            if(source) [weak openSource:source identifier:gameIdentifier];
            else [weak reportError:@"場所へのアクセスを復元できません。「開く」で再選択してください。" code:@"source_access" summary:@"登録したフォルダへのアクセスを復元できませんでした"];
        }];
    }
    // Also expose complete caches staged for device testing.
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
        [self addLibraryGameTo:menu identifier:identifier folder:cache cache:cache
            catalogName:catalogNameForFolder(cache) fallback:title
            action:^{
                if(usesGameCache()) [weak openCache:cache identifier:identifier];
                else [weak reportError:@"元フォルダを「開く」から選び直してください。" code:@"source_access" summary:@"元フォルダを開けませんでした"];
            }];
    }
    menu.demoAction=^{ [weak demo]; };
    UINavigationController* nav=[[UINavigationController alloc] initWithRootViewController:menu];
    // Keep the player hierarchy attached so Duo hinge notifications continue.
    nav.modalPresentationStyle=UIModalPresentationOverFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)demo { [self demoWith480Lines:NO]; }
- (void)demoWith480Lines:(BOOL)use480Lines {
    if(fetching) return;
    NSURL* root=area(NSCachesDirectory,@"PC98Games/demo");
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    // Guest program: INT 18h requests 31 kHz / 480 lines, then the PEGC
    // palette and VRAM ports draw a pattern across the 256 KiB boundary.
    const uint8_t pattern[]={
        0xb8,0x0c,0x30,0xb7,0x31,0xcd,0x18,0xb4,0x40,0xcd,0x18,0xb0,0x69,0xe6,0x6a,
        0x31,0xdb,0x88,0xd8,0xe6,0xa8,0x30,0xc0,0xe6,0xaa,0x88,0xd8,0xe6,0xac,0xf6,0xd0,
        0xe6,0xae,0xfe,0xc3,0x75,0xec,0xb8,0x00,0xe0,0x8e,0xd8,0xb8,0x00,0xa8,0x8e,0xc0,
        0x31,0xdb,0xfc,0x89,0x1e,0x04,0x00,0x31,0xff,0xb9,0x00,0x80,0x88,0xd8,0xc0,0xe0,
        0x04,0x04,0x20,0xf3,0xaa,0x43,0x83,0xfb,0x0a,0x72,0xe8,
        // Mark the entire last scanline red.
        0xc7,0x06,0x04,0x00,0x09,0x00,0xbf,0x80,0x2d,0xb9,0x80,0x02,0xb0,0xff,0xf3,0xaa,
        0xf4,0xeb,0xfd
    };
    const uint8_t keyboardDemo[]={0xBA,0x13,0x01,0xB4,0x09,0xCD,0x21,0xB4,0x08,0xCD,0x21,0xB4,0x02,0x88,0xC2,0xCD,0x21,0xEB,0xF4};
    NSString* program=use480Lines?@"DEMO480.COM":@"DEMO.COM";
    NSMutableData* com;
    if(use480Lines) com=[NSMutableData dataWithBytes:pattern length:sizeof(pattern)];
    else {
        com=[NSMutableData dataWithBytes:keyboardDemo length:sizeof(keyboardDemo)];
        std::string message=hostfs::to_sjis("RetroDOS Player / 640x400\r\n\r\n日本語 / レトロキーボード\r\n\r\nTouch keys below. SHIFT / CTRL / GRPH latch.\r\n$");
        [com appendBytes:message.data() length:message.size()];
    }
    NSError* error=nil;
    NSString* ini=[NSString stringWithFormat:@"[PC98PLAYER]\nStart=%@\nMIDI=0\nRhythmROM=0\n",program];
    if(![com writeToURL:[root URLByAppendingPathComponent:program] options:NSDataWritingAtomic error:&error] ||
       ![ini writeToURL:[root URLByAppendingPathComponent:@"PC98PLAYER.INI"] atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self message:error.localizedDescription];
        return;
    }
    [self openCache:root identifier:@"demo"];
}
#ifdef PC98PLAYER_TESTING
- (void)contentFilterSmoke {
    uint64_t initialFrame=player?player->m->frame_count:0;
    PC98ContentFilter* probe=[PC98ContentFilter new];
    [probe runSmokeChecks:^(NSDictionary* checks,UIImage* preview) {
        NSMutableDictionary* report=[checks mutableCopy];BOOL passed=YES;
        report[@"emulationContinuedDuringInference"]=@(player && player->m->frame_count>initialFrame);
        report[@"audioQueueContinuedDuringInference"]=@(audio.queue && audio.started && !audio.paused);
        for(id value in report.allValues)if([value isKindOfClass:NSNumber.class] && ![value boolValue])passed=NO;
        if(checks[@"error"])passed=NO;report[@"passed"]=@(passed);
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
            writeToURL:area(NSDocumentDirectory,@"content-filter-smoke.json") atomically:YES];
        [UIImagePNGRepresentation(preview) writeToURL:area(NSDocumentDirectory,@"content-filter-preview.png") atomically:YES];
    }];
}
// Debug-only, input-driven compatibility check inside the real simulator app.
- (void)verifyGameFrames:(int)total {
    if(!player) return;
    [self suspend]; manualDrive.store(true);
    __weak PlayerController* weak=self;
    __block int frame=0,peak=0;
    [NSTimer scheduledTimerWithTimeInterval:0.001 repeats:YES block:^(NSTimer* timer) {
        PlayerController* s=weak;if(!s || !s->player) { [timer invalidate];if(s) s->manualDrive.store(false);return; }
        for(int n=0;n<60 && frame<total && !s->player->m->quit;++n,++frame) {
            for(int keyFrame : {300,600,900,1200,1800,2400,3000,3600,5000,8000,11000,14000}) {
                if(frame==keyFrame) machine_key(s->player->m,0x1c,true);
                if(frame==keyFrame+3) machine_key(s->player->m,0x1c,false);
            }
            for(int mouseFrame : {2000,2800,3500,6000,9000,12000,15000}) {
                if(frame==mouseFrame || frame==mouseFrame+3) {
                    auto& mouse=s->player->m->mouse;
                    machine_mouse(s->player->m,320-mouse.x,200-mouse.y,frame==mouseFrame?1:0);
                }
            }
            s->player->run_frame();
            for(int16_t sample:s->player->audio) peak=std::max(peak,std::abs((int)sample));
        }
        [s refreshMonitor];
        if(frame<total && !s->player->m->quit) return;
        [timer invalidate];s->manualDrive.store(false);[s releaseKeys];
        Machine* m=s->player->m;std::set<uint32_t> colors;
        for(int i=0;i<640*s->player->fb_h;++i) colors.insert(s->player->fb[i]);
        int imageHeight=s.monitor.image.CGImage? (int)CGImageGetHeight(s.monitor.image.CGImage):0;
        NSDictionary* report=@{@"game":s.currentID ?: @"",@"frames":@(frame),@"requestedFrames":@(total),@"guestQuit":@(m->quit),
            @"videoColors":@(m->cfg.video_colors),@"pc9821":@(m->cfg.pc9821),@"pegcActive":@(m->pegc.on),
            @"crtMode":@(m->cfg.crt_mode),@"crt31":@(m->pegc.crt31),
            @"screenColorCount":@(colors.size()),@"framebufferHeight":@(s->player->fb_h),@"imageHeight":@(imageHeight),@"audioPeak":@(peak)};
        NSData* json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToURL:[area(NSDocumentDirectory,@"") URLByAppendingPathComponent:@"compatibility-result.json"] atomically:YES];
        [UIImagePNGRepresentation(s.monitor.image) writeToURL:[area(NSDocumentDirectory,@"") URLByAppendingPathComponent:@"compatibility-frame.png"] atomically:YES];
        s.status.text=@"検証完了 — ▶︎で再開";
    }];
}
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
    [self suspend]; paused=NO; manualDrive.store(true);
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
    result[@"controllerChord"]=@([self.keyboard controllerChordForTesting:^BOOL(int scan) { return player->m->kb_down[scan]!=0; }]);
    NSArray<NSNumber*>* savedBluetoothBindings=self.bluetoothBindings;
    self.bluetoothBindings=pc98_controller_bindings(@[@0x3A,@0x3B,@0x3C,@0x3D,@29,@28]);
    GCController* gamepad=[GCController controllerWithExtendedGamepad];
    [gamepad.extendedGamepad.leftThumbstick setValueForXAxis:.8f yAxis:0];
    [gamepad.extendedGamepad.buttonA setValue:1];
    [self updateGameControllerInput:@[gamepad]];
    int gamepadRight=self.bluetoothBindings[2].intValue;
    int gamepadAction=self.bluetoothBindings[4].intValue;
    bool gamepadChord=player->m->kb_down[gamepadRight] && player->m->kb_down[gamepadAction] && !player->m->kb_down[0x34];
    touchKeys.insert(gamepadRight);
    [self updateGameControllerInput:nil];
    gamepadChord &= player->m->kb_down[gamepadRight] && !player->m->kb_down[gamepadAction];
    touchKeys.erase(gamepadRight);
    [self updateScan:gamepadRight];
    [self updateGameControllerInput:@[gamepad]];
    gamepadChord &= player->m->kb_down[gamepadRight] && player->m->kb_down[gamepadAction];
    [self releaseKeys];
    self.bluetoothBindings=savedBluetoothBindings;
    result[@"gameControllerChordAndReconnect"]=@(gamepadChord &&
        !player->m->kb_down[gamepadRight] && !player->m->kb_down[gamepadAction]);
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
    [self refreshMonitor];
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
    result[@"touchpadMode"]=@([self.keyboard touchpadForTesting:^BOOL(int button) {
        return player->m->mouse.buttons==button;
    }]);
    [self releaseKeys];
    UILongPressGestureRecognizer* hold=nil;
    for(UIGestureRecognizer* gesture in self.view.gestureRecognizers)
        if([gesture isKindOfClass:UILongPressGestureRecognizer.class]) hold=(UILongPressGestureRecognizer*)gesture;
    result[@"demoAllowsLongPress"]=@(hold && [self gestureRecognizerShouldBegin:hold] && [[[self fullscreenMenu].actions firstObject].title containsString:@"640×480"]);
    CGRect previousMonitor=self.monitor.frame;
    [self.keyboard pressScansForTesting:@[@0x70,@29]];
    [self toggleFullScreen];
    result[@"fullscreenShowsControllerOutlines"]=@(fullScreen && self.topPanel.hidden && !self.keyboard.hidden && self.keyboard.outlinesOnly && self.toolbar.hidden && self.statusRow.hidden && self.monitor.superview==self.view && self.prefersStatusBarHidden);
    CGRect fullscreenSafe=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);
    result[@"fullscreenAspectFit"]=@(CGRectContainsRect(fullscreenSafe,self.monitor.frame) && fabs(self.monitor.frame.size.width/self.monitor.frame.size.height-1.6)<.001);
    result[@"fullscreenReleasesKeys"]=@(!player->m->kb_down[0x70] && !player->m->kb_down[29]);
    result[@"fullscreenControllerChord"]=@([self.keyboard controllerChordForTesting:^BOOL(int scan) {
        return player->m->kb_down[scan];
    }]);
    result[@"controlMargin"]=@([self.keyboard controlMarginForTesting]);
    [self releaseKeys];
    [self rightClick];result[@"fullscreenRightClick"]=@(player->m->mouse.buttons==2);[self releaseKeys];
    result[@"fullscreenAcceptsLongPress"]=@(hold && [self gestureRecognizerShouldBegin:hold]);
    UIAlertController* menu=[self fullscreenMenu];
    result[@"fullscreenMenuActions"]=@(menu.actions.count==7 && [menu.actions[5].title isEqualToString:@"フィードバックする"] && [menu.actions[3].title isEqualToString:@"FDD"] && [menu.actions[2].title isEqualToString:@"コントローラーを非表示"] && [menu.actions[0].title isEqualToString:@"一時停止"] && [menu.actions[1].title isEqualToString:@"リセット"]);
    [self pauseFromFullscreenMenu];
    result[@"fullscreenMenuPauses"]=@(paused.load() && fullscreenMenuPaused && audio.paused);
    [self rightClick];
    result[@"rightClickDoesNotResume"]=@(paused.load() && player->m->mouse.buttons==0);
    [self leftClick:nil];
    result[@"fullscreenTapResumesWithoutGuestClick"]=@(!paused && !fullscreenMenuPaused && player->m->mouse.buttons==0);
    [self leftClick:nil];
    result[@"fullscreenNextTapClicks"]=@(player->m->mouse.buttons==1);[self releaseKeys];
    [self pauseFromFullscreenMenu];
    [self toggleFullScreen];
    [self leftClick:nil];
    result[@"normalViewDoesNotTapResume"]=@(paused.load() && !fullscreenMenuPaused);
    [self togglePause];
    result[@"fullscreenRestoresLayout"]=@(!fullScreen && !self.topPanel.hidden && !self.keyboard.hidden && !self.toolbar.hidden && !self.statusRow.hidden && self.monitor.superview==self.topPanel && CGRectEqualToRect(previousMonitor,self.monitor.frame));
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
    paused=YES; audio.close(); [self refreshMonitor]; self.status.text=@"Duo上下表示・PC98入力・ステート検証完了";
    UIGraphicsImageRenderer* renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.view.bounds];
    UIImage* image=[renderer imageWithActions:^(UIGraphicsImageRendererContext* context) { [self.view.layer renderInContext:context.CGContext]; }];
    [UIImagePNGRepresentation(image) writeToURL:area(NSDocumentDirectory,@"duo-smoke.png") atomically:YES];
    [self demoWith480Lines:YES];
    if(player) for(int i=0;i<8;++i) player->run_frame(true,false);
    result[@"demo480LastLine"]=@(player && player->m->pegc.on && player->m->pegc.crt31 &&
        player->fb_h==480 && player->fb[479*640]==0xffff0000 && player->fb[480*640-1]==0xffff0000);
    result[@"demo480OffersReturn"]=@([[[self fullscreenMenu].actions firstObject].title containsString:@"640×400"]);
    [self demoWith480Lines:NO];
    if(player) player->run_frame(true,false);
    result[@"demoReturnsTo400"]=@(player && !player->m->pegc.on && player->fb_h==400);
    bool success=true; for(NSNumber* value in result.allValues) if(!value.boolValue) success=false;
    result[@"passed"]=@(success);
    NSData* report=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [report writeToURL:area(NSDocumentDirectory,@"smoke-result.json") atomically:YES];
    manualDrive.store(false);
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
- (void)sceneWillResignActive:(UIScene*)scene { [self.controller prepareForInactive]; }
- (void)sceneDidBecomeActive:(UIScene*)scene { [self.controller refreshHingeAfterActivation]; }
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
