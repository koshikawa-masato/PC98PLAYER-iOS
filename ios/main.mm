// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "GameLibrary.h"
#import "Keyboard.h"
#include "DuoPresentation.h"
#import "RetroHardware.h"
#include "AudioOut.h"
#include "font.h"
#include "player.h"
#include "StartupPath.h"
#include "GraphicsSettings.h"
#import "ContentFilter.h"
#include "hostfs.h"
#include <bitset>
#include <deque>
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

static NSString* gameClockKey(NSString* identifier) {
    return [@"PC98GameClockMHz." stringByAppendingString:identifier];
}
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

// A full-window list avoids the fold-aware alert's short, upper-panel viewport.
@interface GameLocationsController : UITableViewController
@property(copy) NSString* message;
@property(strong) NSMutableArray<NSDictionary*>* choices;
- (void)addTitle:(NSString*)title destructive:(BOOL)destructive action:(void (^)(void))action;
- (void)addGame:(NSString*)title identifier:(NSString*)identifier cached:(BOOL)cached action:(void (^)(void))action
           info:(void (^)(void))info remove:(void (^)(void))remove;
@end
@implementation GameLocationsController
- (instancetype)init { if((self=[super initWithStyle:UITableViewStyleInsetGrouped])) self.choices=[NSMutableArray new];return self; }
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"ゲーム一覧";
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"閉じる" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=60;
}
- (void)addTitle:(NSString*)title destructive:(BOOL)destructive action:(void (^)(void))action {
    [self.choices addObject:@{@"title":title,@"destructive":@(destructive),@"action":[action copy]}];
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
    cell.accessoryType=choice[@"info"] ? UITableViewCellAccessoryDetailButton : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)index {
    void (^action)(void)=self.choices[index.row][@"action"];
    [self dismissViewControllerAnimated:YES completion:action];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

static NSString* const cacheOnLaunchKey=@"PC98CacheOnLaunch";
static BOOL usesGameCache(void) {
    NSNumber* enabled=[NSUserDefaults.standardUserDefaults objectForKey:cacheOnLaunchKey];
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
@property NSInteger soundBoard;
@property NSInteger videoColors;
@property NSInteger clockMHz;
@property BOOL manualDuo;
@property BOOL bossMode;
@property BOOL launchFullscreen;
@property BOOL cacheOnLaunch;
@property(copy) NSArray<NSNumber*>* bluetoothBindings;
@property content_filter::Settings filterSettings;
@property(copy) void (^willApply)(content_filter::Settings);
@property(copy) void (^applied)(NSInteger,NSInteger,BOOL,BOOL,content_filter::Settings);
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
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return section==2?5:section==3?6:section==4?1:section==5?5:2; }
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section { return @[@"音源",@"色数",@"表示",@"コンテンツフィルター",@"Bluetoothコントローラー",@"CPUクロックのデフォルト",@"このアプリについて"][section]; }
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
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
        cell.textLabel.text=index.row==0?@"OPN":@"OPNA";
        cell.detailTextLabel.text=index.row==0?@"YM2203":@"YM2608";
        cell.accessoryType=(self.soundBoard==(index.row==0?26:86))?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    } else if(index.section==1) {
        cell.textLabel.text=index.row==0?@"16色":@"256色";
        cell.detailTextLabel.text=index.row==0?@"標準グラフィック":@"拡張グラフィック";
        cell.accessoryType=(self.videoColors==(index.row==0?16:256))?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    } else if(index.section==2) {
        cell.textLabel.text=index.row==0?@"自動判別":index.row==1?@"Duo上下表示を固定":@"ボスがきた";
        cell.detailTextLabel.text=index.row==0?@"端末とヒンジの状態に合わせる":index.row==1?@"上にモニタ、下にキーボード":@"Duoを閉じると一時停止・アウターを非表示";
        if(index.row==4) {
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
        LegalTextController* document=[LegalTextController new];document.title=index.row==0?@"プライバシーポリシー":@"ライセンス";
        document.resource=index.row==0?@"privacy-policy.txt":@"LICENSE";[self.navigationController pushViewController:document animated:YES];return;
    }
    if(index.section==0)self.soundBoard=index.row==0?26:86;
    else if(index.section==1)self.videoColors=index.row==0?16:256;
    else if(index.section==2 && index.row<2)self.manualDuo=index.row==1;
    else if(index.section==3 && index.row>=2 && index.row<5) { auto settings=self.filterSettings;settings.effect=(content_filter::Effect)(index.row-2);self.filterSettings=settings; }
    [tableView reloadData];
}
- (void)editClock {
    __weak GameOptionsController* weak=self;
    presentCustomClock(self,self.clockMHz,^(NSInteger value) {
        weak.clockMHz=value;
        [weak.tableView reloadData];
    });
}
- (void)changeCacheOnLaunch:(UISwitch*)sender { self.cacheOnLaunch=sender.on; }
- (void)changeLaunchFullscreen:(UISwitch*)sender { self.launchFullscreen=sender.on; }
- (void)changeBossMode:(UISwitch*)sender { self.bossMode=sender.on; }
- (void)changeFilter:(UISwitch*)sender { auto settings=self.filterSettings;if(sender.tag==0)settings.adult=sender.on;else settings.harm=sender.on;self.filterSettings=settings; }
- (void)changeSensitivity:(UISegmentedControl*)sender { auto settings=self.filterSettings;settings.sensitivity=(int)sender.selectedSegmentIndex;self.filterSettings=settings; }
- (void)cancel { [self dismissViewControllerAnimated:YES completion:^{if(self.cancelled)self.cancelled();}]; }
- (void)apply {
    [NSUserDefaults.standardUserDefaults setObject:self.bluetoothBindings forKey:bluetoothBindingsKey];
    [NSUserDefaults.standardUserDefaults setBool:self.launchFullscreen forKey:launchFullscreenKey];
    [NSUserDefaults.standardUserDefaults setBool:self.cacheOnLaunch forKey:cacheOnLaunchKey];
    [NSUserDefaults.standardUserDefaults setInteger:self.clockMHz forKey:defaultClockKey];
    if(self.willApply)self.willApply(self.filterSettings);[self dismissViewControllerAnimated:YES completion:^{if(self.applied)self.applied(self.soundBoard,self.videoColors,self.manualDuo,self.bossMode,self.filterSettings);}]; }
@end

@interface PlayerController : UIViewController <UIDocumentPickerDelegate,UIAdaptivePresentationControllerDelegate,UIGestureRecognizerDelegate> {
    std::unique_ptr<Player> player;
    AudioOut audio;
    double nextFrame;
    double fpsSampleStart;
    int fpsSampleFrames;
    struct FPSSample {
        double elapsed;
        int frames;
    };
    std::deque<FPSSample> fpsHistory;
    BOOL bossMode, hingeClosed;
    BOOL paused, fetching, pickerPreviousPause, manualDuo, hingeDuo, duoHardware, fullScreen, fullscreenMenuPaused;
    int mouseButtons;
    int filterFrameHeight;
    std::set<NSInteger> physicalKeys;
    std::set<int> touchKeys;
    std::bitset<128> controllerKeys;
}
@property UIView* bossShield;
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
    [self.monitor addGestureRecognizer:hold];
    UITapGestureRecognizer* twoFingerTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rightClick)];
    twoFingerTap.numberOfTouchesRequired=2;[self.monitor addGestureRecognizer:twoFingerTap];
    UITapGestureRecognizer* doubleTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleFullScreen)];
    doubleTap.numberOfTapsRequired=2;[doubleTap requireGestureRecognizerToFail:twoFingerTap];[self.monitor addGestureRecognizer:doubleTap];
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
    NSArray* titles=@[@"オプション",@"開く",@"一覧",@"▶︎ / Ⅱ",@"保存",@"読込",@"リセット",@"右クリック"];
    SEL actions[]={@selector(showOptions),@selector(openFolder),@selector(showLibrary),@selector(togglePause),@selector(saveSlot),@selector(loadSlot),@selector(resetGame),@selector(rightClick)};
    for(NSUInteger i=0;i<titles.count;++i) { UIButton* b=[UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:titles[i] forState:UIControlStateNormal]; b.titleLabel.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; [b setTitleColor:[UIColor colorWithWhite:.18 alpha:1] forState:UIControlStateNormal]; [b setTitleColor:UIColor.grayColor forState:UIControlStateHighlighted]; b.backgroundColor=PC98Plastic(.87); b.layer.cornerRadius=2; b.layer.borderWidth=1; b.layer.borderColor=PC98Plastic(.55).CGColor; b.layer.shadowColor=UIColor.blackColor.CGColor; b.layer.shadowOffset=CGSizeMake(0,1); b.layer.shadowOpacity=.25; b.layer.shadowRadius=0; b.titleLabel.adjustsFontSizeToFitWidth=YES; [b addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside]; [self.toolbar addArrangedSubview:b]; }
    [self.view addSubview:self.toolbar];
    self.keyboard=[PC98Keyboard new]; __weak PlayerController* weak=self;
    self.keyboard.keyChanged=^(int scan,BOOL down) {
        PlayerController* s=weak; if(!s) return;
        if(down) s->touchKeys.insert(scan); else s->touchKeys.erase(scan);
        [s updateScan:scan];
    };
    self.keyboard.pauseChanged=^{ [weak togglePause]; };
    self.keyboard.controllerSettingsOpening=^{
        PlayerController* controller=weak;
        if(controller && !controller->paused) [controller togglePause];
    };
    self.bluetoothBindings=pc98_controller_bindings([NSUserDefaults.standardUserDefaults arrayForKey:bluetoothBindingsKey]);
    [self.keyboard loadControllerBindingsForGame:@"demo"];
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
            else [self message:@"指定されたゲームのキャッシュがありません。"];
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
                @"videoColors":@(m->cfg.video_colors),@"pegcActive":@(m->pegc.on),@"screenColorCount":@(colors.size()),@"framebufferHeight":@(s->player->fb_h),
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
        self.statusRow.frame=CGRectMake(lower.origin.x+15,lower.origin.y+40,lower.size.width-30,10);
    } else {
        self.statusRow.frame=[self.topPanel convertRect:[self.topPanel statusFrame] toView:self.view];
        self.toolbar.frame=[self.topPanel convertRect:[self.topPanel controlsFrame] toView:self.view];
    }
    [self.view bringSubviewToFront:self.toolbar];
    [self.view bringSubviewToFront:self.statusRow];
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
    self.topPanel.hidden=fullScreen;self.keyboard.hidden=fullScreen;
    self.toolbar.hidden=fullScreen;self.statusRow.hidden=fullScreen;
    self.view.backgroundColor=fullScreen?UIColor.blackColor:PC98Plastic(.84);
    self.monitor.layer.cornerRadius=fullScreen?0:4;
    [self.monitor removeFromSuperview];
    if(fullScreen) [self.view addSubview:self.monitor];else [self.topPanel addSubview:self.monitor];
    [self setNeedsStatusBarAppearanceUpdate];[self setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (void)message:(NSString*)message {
    UIAlertController* a=[UIAlertController alertControllerWithTitle:@"RetroDOS Player" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil];
}
- (void)updateScan:(int)scan {
    if(!player || paused) return;
    BOOL down=touchKeys.count(scan)>0 || controllerKeys.test(scan);
    for(NSInteger u:physicalKeys) if(pc98_scan_from_hid(u)==scan) down=YES;
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
    CGFloat scale=MIN(self.monitor.bounds.size.width/640,self.monitor.bounds.size.height/(player?player->fb_h:400));
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
- (void)resetFPS {
    fpsSampleStart=0;
    fpsSampleFrames=0;
    fpsHistory.clear();
    self.fpsLabel.hidden=YES;
}
- (void)tick:(CADisplayLink*)link {
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
    double now=CACurrentMediaTime(); if(now-nextFrame>seconds*3) nextFrame=now;
    [self.keyboard repeatHeldKeys];
    // Match macOS: advance the guest on elapsed time. Audio output consumes
    // the generated samples without deciding when the guest runs.
    int frames=0;
    while(now>=nextFrame && frames<3) {
        player->run_frame();
        ++frames;
#ifdef PC98PLAYER_TESTING
        [self.audioProbe appendReference:player->audio rate:player->ps.sample_rate];
#endif
        audio.push(player->audio); nextFrame+=seconds;
        if(player->m->quit) { paused=YES; [self releaseKeys]; audio.close(); self.status.text=player->m->quit==2 ? text(player->m->status) : @"実行が終了しました"; break; }
    }
    if(frames) [self refreshMonitor];

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
    if(filterFrameHeight!=player->fb_h) { [self.contentFilter reset];self.monitor.image=nil;filterFrameHeight=player->fb_h; }
    UIImage* image=frameImage(player.get());
    NSData* reference=self.titleReference;
    BOOL matchesTitle=reference && !self.titleCaptureAttempted &&
        !(bossMode && hingeClosed) &&
        [reference isEqualToData:titleFrameDigest(player->fb, 640 * player->fb_h * sizeof(uint32_t))];
    if(self.contentFilter.settings.enabled() && !self.monitor.image)
        self.status.text=self.contentFilter.lastError?[@"保護フィルター: " stringByAppendingString:self.contentFilter.lastError]:@"保護フィルター: 判定中…";
    __weak PlayerController* weak=self;
    [self.contentFilter submitImage:image completion:^(UIImage* filtered,NSString* error) {
        PlayerController* s=weak;if(!s || !s->player)return;
        s.monitor.image=filtered;
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
    fullscreenMenuPaused=NO; paused=YES; [self releaseKeys]; audio.close();
    if(player) { player->shutdown(); player.reset(); }
    hostfs::set_overlay("","");
    [self.scopedGameFolder stopAccessingSecurityScopedResource];
    self.scopedGameFolder=nil;
    self.readingOriginal=NO;
}
- (void)togglePause {
    if(bossMode && hingeClosed) return;
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
    if(bossMode && hingeClosed) { [self suspend];return; }
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
    if(urls.count) [self openSource:urls.firstObject identifier:registeredGameID(urls.firstObject)];
}
- (void)openSource:(NSURL*)source identifier:(NSString*)identifier {
    if(usesGameCache()) { [self cacheSource:source identifier:identifier]; return; }
    if(fetching) return;
    BOOL scoped=[source startAccessingSecurityScopedResource];
    NSNumber* directory=nil;
    NSError* error=nil;
    if(![source getResourceValue:&directory forKey:NSURLIsDirectoryKey error:&error] || !directory.boolValue) {
        if(scoped) [source stopAccessingSecurityScopedResource];
        [self message:error.localizedDescription ?: @"ゲームフォルダを開けませんでした。"];
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
                if(error) { s.status.text=error.localizedDescription; [s message:error.localizedDescription]; }
                else [s openCache:destination identifier:identifier];
            });
        }
    });
}
- (BOOL)prepareLocalProgram:(NSURL*)program root:(NSURL*)root settings:(PlayerSettings&)settings {
    if([GameLibrary isWindowsProgramAtURL:program]) {
        [self message:@"この実行ファイルはWindows用です。PC-98／DOS用の起動ファイルを選んでください。"];
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
    if(![NSFileManager.defaultManager createDirectoryAtURL:saved withIntermediateDirectories:YES attributes:nil error:&error]) { [self message:error.localizedDescription]; return; }
    hostfs::set_overlay(cache.fileSystemRepresentation,saved.fileSystemRepresentation);
    NSURL* iniURL=[cache URLByAppendingPathComponent:@"PC98PLAYER.INI"];
    Ini ini;
    BOOL loadedINI=ini.load(iniURL.fileSystemRepresentation);
    NSString* configured=text(ini.get("PC98PLAYER.ROOT"));
    NSURL* root=[GameLibrary gameRootAtURL:cache relativePath:configured error:&error];
    if(!root) {
        [self message:[@"Root= の指定先を開けません。ゲームフォルダ内の相対パスと取得状態を確認してください。\n" stringByAppendingString:error.localizedDescription ?: @""]]; return;
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
    ps.cfg.midi=0; ps.cfg.trace=0; ps.sample_rate=std::clamp(ps.sample_rate,8000,192000);
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
    if(scanError) { [self message:[@"ゲームフォルダを読み取れません。取得状態を確認してください。\n" stringByAppendingString:scanError.localizedDescription]]; return; }
    if(!programs.count) { [self message:@"起動ファイルがありません。ZIPを展開し、BAT・COM・EXEのあるフォルダを選んでください。iCloudでは「ファイル」でダウンロード完了を確認してください。以前取得した内容が不完全な場合は「一覧」でゲーム本体のキャッシュを消去して再取得してください（セーブは保持されます）。"]; return; }
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
    player=std::make_unique<Player>(); mac_install_font(settings.font_name,settings.font_shift); std::string error;
    settings.cfg.start = apple_startup::dos_start_path(settings.cfg.start);
    if(!player->init(settings,&error)) { [self stopGame]; [self message:text(error)]; return; }
    paused=NO; nextFrame=CACurrentMediaTime(); self.status.text=self.readingOriginal ? @"実行中 — 元フォルダを直接読込、保存データは別領域" : @"実行中 — ゲーム本体はキャッシュ、保存データは別領域";
#if TARGET_OS_SIMULATOR
    NSString* nasPath=[NSUserDefaults.standardUserDefaults stringForKey:@"PC98SimulatorNASRoot"];
    if(nasPath.length && [self.currentCache.path hasPrefix:[nasPath stringByAppendingString:@"/"]])
        self.status.text=@"実行中 — NASを直接読込、保存データは別領域";
#endif

    if(self.currentID.length && ![self.currentID isEqualToString:@"demo"])
        self.titleReference=[NSUserDefaults.standardUserDefaults dataForKey:titleReferenceKey(self.currentID)];
    self.titleCaptureAttempted=NO;
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
        if(load) { [s.contentFilter reset];s.monitor.image=nil; }
        std::string error; BOOL ok=load?s->player->load_state(slot,&error):s->player->save_state(slot,&error);
        [s releaseKeys]; s->audio.clear(); s->nextFrame=CACurrentMediaTime();
        if(!ok) [s message:text(error)]; else s.status.text=load?@"ステートを読み込みました":@"ステートを保存しました";
        if(s->player) [s refreshMonitor];
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
    NSInteger defaultClock=[NSUserDefaults.standardUserDefaults integerForKey:defaultClockKey];
    options.clockMHz=validClockMHz(defaultClock) ? defaultClock : 0;
    __weak PlayerController* weak=self;
    options.cacheOnLaunch=usesGameCache();
    options.launchFullscreen=[NSUserDefaults.standardUserDefaults boolForKey:launchFullscreenKey];
    options.manualDuo=manualDuo;options.bossMode=bossMode;options.filterSettings=self.contentFilter.settings;
    options.willApply=^(content_filter::Settings filter) {
        PlayerController* s=weak;if(s && filter.enabled()) { [s.contentFilter reset];s.monitor.image=nil; }
    };
    options.cancelled=^{ PlayerController* s=weak;if(!s) return;s->paused=previousPause;if(s->player && !s->paused) [s startAudio];s->nextFrame=CACurrentMediaTime(); };
    options.applied=^(NSInteger sound,NSInteger colors,BOOL duo,BOOL boss,content_filter::Settings filter) {
        PlayerController* s=weak;if(!s) return;
        BOOL restart=s->player && (s->player->m->cfg.sound_board!=sound || s->player->m->cfg.video_colors!=colors);
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
    [menu addGame:display identifier:identifier cached:(cache && [GameLibrary isUsableCacheAtURL:cache]) action:action info:^{
        GameLocationsController* list=weakMenu;
        if(!list) return;
        BOOL cached=cache && [NSFileManager.defaultManager fileExistsAtPath:cache.path];
        NSString* clockKey=gameClockKey(identifier);
        NSInteger clock=[defaults integerForKey:clockKey];
        NSString* clockLabel=validClockMHz(clock) ? [NSString stringWithFormat:@"%ld MHz",(long)clock] : @"デフォルト";
        NSString* info=[NSString stringWithFormat:@"ソフト名  %@\nフォルダ名  %@\n作品DB  %@\nキャッシュ  %@\nCPUクロック  %@",
            catalogName ?: fallback,folder.lastPathComponent,catalogName ? @"照合済み" : @"未確認",cached ? @"保存済み" : @"なし",clockLabel];
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
        [details addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
        [list presentViewController:details animated:YES completion:nil];
    } remove:^{
        // Keep cached files and prevent the same game reappearing as a cache-only row.
        [defaults setBool:YES forKey:hiddenKey];
        [GameLibrary forgetURL:folder];
    }];
}
- (void)showLibrary {
    if(fetching || self.presentedViewController) return;
    GameLocationsController* menu=[GameLocationsController new];
    menu.message=@"「開く」から、このiPhone内／ファイルで接続したNASのフォルダを選べます。元データは書き換えません。";
    __weak PlayerController* weak=self;
    NSString* identifier=self.currentID;
    if(player && !player->m->quit && identifier.length && ![identifier isEqualToString:@"demo"]) {
        UIImage* shown=self.monitor.image;
        UIImage* source=self.displayedSourceFrame;
        if(shown && source && !(bossMode && hingeClosed)) {
            menu.message=@"タイトル画面で「今の画面を登録」を選ぶと、次回から同じ画面が出たときに自動でPNGを保存します。";
            [menu addTitle:@"今の画面をタイトル画面として登録" destructive:NO action:^{
                PlayerController* s=weak;
                if(!s || ![identifier isEqualToString:s.currentID] || (s->bossMode && s->hingeClosed)) return;
                CGDataProviderRef provider=CGImageGetDataProvider(source.CGImage);
                NSData* pixels=provider ? CFBridgingRelease(CGDataProviderCopyData(provider)) : nil;
                if(!pixels.length || !writeTitleScreenshot(shown,identifier)) {
                    [s message:@"タイトル画面を保存できませんでした。"];
                    return;
                }
                NSData* digest=titleFrameDigest(pixels.bytes,pixels.length);
                [NSUserDefaults.standardUserDefaults setObject:digest forKey:titleReferenceKey(identifier)];
                s.titleReference=digest;
                s.titleCaptureAttempted=YES;
                s.status.text=@"タイトル画面を登録しました";
            }];
        }
        NSURL* screenshot=titleScreenshotURL(identifier);
        if([NSFileManager.defaultManager fileExistsAtPath:screenshot.path]) {
            [menu addTitle:@"保存したタイトル画面を共有" destructive:NO action:^{
                PlayerController* s=weak;
                if(!s || (s->bossMode && s->hingeClosed)) return;
                UIActivityViewController* share=[[UIActivityViewController alloc]
                    initWithActivityItems:@[screenshot] applicationActivities:nil];
                share.popoverPresentationController.sourceView=s.toolbar;
                share.popoverPresentationController.sourceRect=s.toolbar.bounds;
                [s presentViewController:share animated:YES completion:nil];
            }];
        }
        if(self.titleReference) {
            [menu addTitle:@"タイトル画面の自動保存を解除" destructive:NO action:^{
                [NSUserDefaults.standardUserDefaults removeObjectForKey:titleReferenceKey(identifier)];
                PlayerController* s=weak;
                if([identifier isEqualToString:s.currentID]) s.titleReference=nil;
            }];
        }
    }

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
            else [weak message:@"場所へのアクセスを復元できません。「開く」で再選択してください。"];
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
                else [weak message:@"元フォルダを「開く」から選び直してください。"];
            }];
    }
    [menu addTitle:@"オリジナルDOSデモ" destructive:NO action:^ { [weak demo]; }];
    UINavigationController* nav=[[UINavigationController alloc] initWithRootViewController:menu];
    // Keep the player hierarchy attached so Duo hinge notifications continue.
    nav.modalPresentationStyle=UIModalPresentationOverFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)demo {
    if(fetching) return;
    NSURL* root=area(NSCachesDirectory,@"PC98Games/demo");
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    const uint8_t code[]={0xBA,0x13,0x01,0xB4,0x09,0xCD,0x21,0xB4,0x08,0xCD,0x21,0xB4,0x02,0x88,0xC2,0xCD,0x21,0xEB,0xF4};
    NSMutableData* com=[NSMutableData dataWithBytes:code length:sizeof(code)];
    std::string message=hostfs::to_sjis("RetroDOS Player\r\n\r\n日本語 / レトロキーボード\r\n\r\nTouch keys below. SHIFT / CTRL / GRPH latch.\r\n$");
    [com appendBytes:message.data() length:message.size()]; [com writeToURL:[root URLByAppendingPathComponent:@"DEMO.COM"] atomically:YES];
    [@"[PC98PLAYER]\nStart=DEMO.COM\nMIDI=0\nRhythmROM=0\n" writeToURL:[root URLByAppendingPathComponent:@"PC98PLAYER.INI"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
    [self suspend];
    __weak PlayerController* weak=self;
    __block int frame=0,peak=0;
    [NSTimer scheduledTimerWithTimeInterval:0.001 repeats:YES block:^(NSTimer* timer) {
        PlayerController* s=weak;if(!s || !s->player) { [timer invalidate];return; }
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
        [timer invalidate];[s releaseKeys];
        Machine* m=s->player->m;std::set<uint32_t> colors;
        for(int i=0;i<640*s->player->fb_h;++i) colors.insert(s->player->fb[i]);
        int imageHeight=s.monitor.image.CGImage? (int)CGImageGetHeight(s.monitor.image.CGImage):0;
        NSDictionary* report=@{@"game":s.currentID ?: @"",@"frames":@(frame),@"requestedFrames":@(total),@"guestQuit":@(m->quit),
            @"videoColors":@(m->cfg.video_colors),@"pc9821":@(m->cfg.pc9821),@"pegcActive":@(m->pegc.on),
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
    UILongPressGestureRecognizer* hold=nil;
    for(UIGestureRecognizer* gesture in self.monitor.gestureRecognizers)
        if([gesture isKindOfClass:UILongPressGestureRecognizer.class]) hold=(UILongPressGestureRecognizer*)gesture;
    result[@"normalViewRejectsLongPress"]=@(hold && ![self gestureRecognizerShouldBegin:hold]);
    CGRect previousMonitor=self.monitor.frame;
    [self.keyboard pressScansForTesting:@[@0x70,@29]];
    [self toggleFullScreen];
    result[@"fullscreenHidesControls"]=@(fullScreen && self.topPanel.hidden && self.keyboard.hidden && self.toolbar.hidden && self.statusRow.hidden && self.monitor.superview==self.view && self.prefersStatusBarHidden);
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
