// SPDX-License-Identifier: MIT
#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#include "player.h"
#include "hostfs.h"
#include "font.h"
#include "AudioOut.h"
#import "GameLibrary.h"
#include <algorithm>
#include <deque>
#include <memory>
#include <mutex>
#include <set>

static std::unique_ptr<Player> player;
static AudioOut audio;
static bool paused = false, captured = false, muted = false;
static int mouseMode = 0, mouseSpeed = 100, buttons = 0;
static std::set<unsigned short> heldKeys;
static NSString* initialPath;
static std::string startOverride;
static int frameLimit = 0, frameCount = 0;
static NSString* screenshotPath;
static NSString* currentIniPath;
static PlayerSettings currentSettings;
static constexpr double frameSeconds = (double)FRAME_TICKS / MASTER_CLOCK;

static NSString* ns(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
static void alert(NSString* message) {
    NSAlert* a = [NSAlert new]; a.messageText = @"PC98PLAYER"; a.informativeText = message;
    [a runModal];
}
static int keyCode(unsigned short c) {
    // macOS hardware key codes -> PC-98 scan codes (physical US/JIS positions).
    switch (c) {
        case 53:return 0; case 18:return 1; case 19:return 2; case 20:return 3;
        case 21:return 4; case 23:return 5; case 22:return 6; case 26:return 7;
        case 28:return 8; case 25:return 9; case 29:return 10; case 27:return 11;
        case 24:return 12; case 93:return 13; case 51:return 14; case 48:return 15;
        case 12:return 16; case 13:return 17; case 14:return 18; case 15:return 19;
        case 17:return 20; case 16:return 21; case 32:return 22; case 34:return 23;
        case 31:return 24; case 35:return 25; case 33:return 26; case 30:return 27;
        case 36:case 76:return 28; case 0:return 29; case 1:return 30;
        case 2:return 31; case 3:return 32; case 5:return 33; case 4:return 34;
        case 38:return 35; case 40:return 36; case 37:return 37; case 41:return 38;
        case 39:return 39; case 42:return 40; case 6:return 41; case 7:return 42;
        case 8:return 43; case 9:return 44; case 11:return 45; case 45:return 46;
        case 46:return 47; case 43:return 48; case 47:return 49; case 44:return 50;
        case 94:return 51; case 49:return 52; case 104:return 53; case 102:return 0x51;
        case 121:return 0x36; case 116:return 0x37; case 114:return 0x38;
        case 117:return 0x39; case 126:return 0x3A; case 123:return 0x3B;
        case 124:return 0x3C; case 125:return 0x3D; case 115:return 0x3E;
        case 119:return 0x3F; case 78:return 0x40; case 75:return 0x41;
        case 89:return 0x42; case 91:return 0x43; case 92:return 0x44;
        case 67:return 0x45; case 86:return 0x46; case 87:return 0x47;
        case 88:return 0x48; case 69:return 0x49; case 83:return 0x4A;
        case 84:return 0x4B; case 85:return 0x4C; case 82:return 0x4E;
        case 65:return 0x50; case 122:return 0x62; case 120:return 0x63;
        case 99:return 0x64; case 118:return 0x65; case 96:return 0x66;
        case 97:return 0x67; case 98:return 0x68; case 100:return 0x69;
        case 101:return 0x6A; case 109:return 0x6B;
        default:return -1;
    }
}
static void capture(bool on) {
    if (on && (mouseMode != 0 || !player || paused)) return;
    if (captured != on) { captured = on; if (on) [NSCursor hide]; else [NSCursor unhide]; }
    CGAssociateMouseAndMouseCursorPosition(!on);
    if (!on) { buttons = 0; if (player) machine_mouse(player->m, 0, 0, 0); }
}
static void releaseInput() {
    capture(false); heldKeys.clear();
    if (player) for (int i = 0; i < 128; ++i)
        if (player->m->kb_down[i]) machine_key(player->m, (uint8_t)i, false);
}

@interface GameView : NSView
@end
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(strong) NSWindow* window;
@property(strong) GameView* view;
@property(strong) NSTimer* timer;
@property double nextFrame;
@property(strong) NSMenu* libraryMenu;
@property(strong) NSURL* sourceURL;
@property BOOL sourceScoped;
- (void)openPath:(NSString*)path;
- (void)openGame:(id)sender;
- (void)tick:(NSTimer*)timer;
@end
static __weak AppDelegate* appDelegate;

static NSBitmapImageRep* framebuffer() {
    NSBitmapImageRep* image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr
        pixelsWide:640 pixelsHigh:player->fb_h bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:640*3 bitsPerPixel:24];
    uint8_t* dst = image.bitmapData;
    for (int i = 0; i < 640*player->fb_h; ++i) {
        uint32_t c = player->fb[i]; dst[i*3] = c >> 16; dst[i*3+1] = c >> 8; dst[i*3+2] = c;
    }
    return image;
}
@implementation GameView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)drawRect:(NSRect)dirty {
    [[NSColor blackColor] setFill]; NSRectFill(self.bounds);
    if (!player) {
        NSString* text = @"PC98PLAYER for Mac\n⌘O でゲームフォルダを開く";
        NSDictionary* attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:22], NSForegroundColorAttributeName:NSColor.whiteColor};
        [text drawAtPoint:NSMakePoint(40, self.bounds.size.height/2) withAttributes:attrs];
        return;
    }
    double scale = std::min(self.bounds.size.width/640, self.bounds.size.height/player->fb_h);
    NSRect dest = NSMakeRect((self.bounds.size.width-640*scale)/2,
        (self.bounds.size.height-player->fb_h*scale)/2, 640*scale, player->fb_h*scale);
    NSGraphicsContext.currentContext.imageInterpolation = player->ps.smooth ? NSImageInterpolationHigh : NSImageInterpolationNone;
    [framebuffer() drawInRect:dest];
}
- (void)keyDown:(NSEvent*)e {
    if (e.modifierFlags & NSEventModifierFlagCommand) return;
    if (e.keyCode == 111) { if (!e.isARepeat) capture(!captured); return; } // F12
    if (!player || paused) return;
    int sc = keyCode(e.keyCode);
    if (sc >= 0 && (!e.isARepeat || player->ps.cfg.key_repeat)) {
        heldKeys.insert(e.keyCode); machine_key(player->m, sc, true);
    }
}
- (void)keyUp:(NSEvent*)e {
    heldKeys.erase(e.keyCode);
    int sc = keyCode(e.keyCode); if (player && sc >= 0) machine_key(player->m, sc, false);
}
- (void)flagsChanged:(NSEvent*)e {
    if (!player) return;
    machine_key(player->m, 0x70, (e.modifierFlags & NSEventModifierFlagShift) != 0);
    machine_key(player->m, 0x74, (e.modifierFlags & NSEventModifierFlagControl) != 0);
    machine_key(player->m, 0x73, (e.modifierFlags & NSEventModifierFlagOption) != 0);
    machine_key(player->m, 0x71, (e.modifierFlags & NSEventModifierFlagCapsLock) != 0);
}
- (void)mouseDown:(NSEvent*)e {
    if (mouseMode == 0 && !captured) { capture(true); return; }
    if (mouseMode != 1) { buttons |= 1; if(player) machine_mouse(player->m,0,0,buttons); }
}
- (void)mouseUp:(NSEvent*)e { buttons &= ~1; if(player) machine_mouse(player->m,0,0,buttons); }
- (void)rightMouseDown:(NSEvent*)e { if (captured || mouseMode == 2) { buttons |= 2; if(player) machine_mouse(player->m,0,0,buttons); } }
- (void)rightMouseUp:(NSEvent*)e { buttons &= ~2; if(player) machine_mouse(player->m,0,0,buttons); }
- (void)mouseMoved:(NSEvent*)e {
    if (player && !paused && (captured || mouseMode == 2))
        machine_mouse(player->m, (int)(e.deltaX*mouseSpeed/100), (int)(e.deltaY*mouseSpeed/100), buttons);
}
- (void)mouseDragged:(NSEvent*)e { [self mouseMoved:e]; }
- (void)rightMouseDragged:(NSEvent*)e { [self mouseMoved:e]; }
@end

static NSMenuItem* item(NSMenu* menu, NSString* title, SEL action, NSString* key) {
    NSMenuItem* i = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    i.target = appDelegate; [menu addItem:i]; return i;
}
@implementation AppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app { return YES; }
- (void)applicationWillFinishLaunching:(NSNotification*)n {
    NSMenu* bar = [NSMenu new]; NSApp.mainMenu = bar;
    NSMenuItem* app = [NSMenuItem new]; [bar addItem:app]; app.submenu = [NSMenu new];
    item(app.submenu, @"PC98PLAYER を終了", @selector(quit:), @"q");
    NSMenuItem* file = [NSMenuItem new]; [bar addItem:file]; file.submenu = [[NSMenu alloc] initWithTitle:@"ファイル"];
    item(file.submenu, @"ゲームフォルダ／INIを開く…", @selector(openGame:), @"o");
    item(file.submenu, @"INIを編集…", @selector(editIni:), @"e");
    item(file.submenu, @"NASに接続…", @selector(connectNAS:), @"");
    NSMenuItem* library = [NSMenuItem new]; [file.submenu addItem:library];
    library.title = @"登録したゲームフォルダ";
    self.libraryMenu = [[NSMenu alloc] initWithTitle:library.title]; library.submenu = self.libraryMenu;
    [self refreshLibrary];
    NSMenuItem* game = [NSMenuItem new]; [bar addItem:game]; game.submenu = [[NSMenu alloc] initWithTitle:@"ゲーム"];
    item(game.submenu, @"一時停止／再開", @selector(pause:), @"p");
    item(game.submenu, @"再起動（INIを再読込）", @selector(restart:), @"r");
    item(game.submenu, @"マウス捕捉／解放（F12）", @selector(toggleCapture:), @"");
    item(game.submenu, @"全画面", @selector(fullscreen:), @"f");
    item(game.submenu, @"STOPキーを送る", @selector(stopKey:), @".");
    for (int mode = 0; mode < 2; ++mode) {
        NSMenuItem* sub = [NSMenuItem new]; [game.submenu addItem:sub];
        sub.title = mode ? @"ステート読込" : @"ステート保存";
        sub.submenu = [[NSMenu alloc] initWithTitle:sub.title];
        for (int s = 0; s < STATE_SLOTS; ++s) {
            NSMenuItem* i = item(sub.submenu, [NSString stringWithFormat:@"スロット %d",s+1],
                mode ? @selector(loadState:) : @selector(saveState:), @""); i.tag = s;
        }
    }
}
- (void)applicationDidFinishLaunching:(NSNotification*)n {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,960,600)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"PC98PLAYER for Mac"; self.window.delegate = self;
    self.window.contentAspectRatio = NSMakeSize(640,400);
    self.window.contentMinSize = NSMakeSize(640,400);
    self.view = [[GameView alloc] initWithFrame:NSMakeRect(0,0,960,600)];
    self.window.contentView = self.view; self.window.acceptsMouseMovedEvents = YES;
    [self.window center]; [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.view]; [NSApp activateIgnoringOtherApps:YES];
    self.nextFrame = NSProcessInfo.processInfo.systemUptime;
    self.timer = [NSTimer timerWithTimeInterval:0.004 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    if (initialPath) [self openPath:initialPath];
}
- (void)application:(NSApplication*)app openFiles:(NSArray<NSString*>*)files {
    if (files.count) { if (self.window) [self openPath:files[0]]; else initialPath = files[0]; }
    [app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}
- (void)openGame:(id)sender {
    releaseInput(); BOOL wasPaused = paused; paused = true; audio.clear();
    NSOpenPanel* panel = [NSOpenPanel openPanel]; panel.canChooseDirectories = YES;
    panel.canChooseFiles = YES; panel.allowsMultipleSelection = NO;
    panel.directoryURL = self.sourceURL;
    panel.message = @"Mac内またはFinderで接続したNASのゲームフォルダ／INIを選んでください。データをアプリ内へ移動する必要はありません。";
    if ([panel runModal] == NSModalResponseOK) { paused = wasPaused; [self openPath:panel.URL.path]; }
    else paused = wasPaused;
}
- (void)openPath:(NSString*)path {
    releaseInput(); audio.clear();
    path = path.stringByStandardizingPath;
    if (![path isAbsolutePath]) path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    BOOL dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir]) { alert(@"指定されたパスが見つかりません。"); return; }
    NSString* root = dir ? path : path.stringByDeletingLastPathComponent;
    NSString* iniPath = (!dir && [path.pathExtension.lowercaseString isEqual:@"ini"]) ? path : [root stringByAppendingPathComponent:@"PC98PLAYER.INI"];
    Ini ini; ini.load(iniPath.fileSystemRepresentation);
    std::string configuredRoot = ini.get("PC98PLAYER.ROOT");
    if (!configuredRoot.empty()) {
        NSString* r = ns(configuredRoot);
        root = r.isAbsolutePath ? r : [root stringByAppendingPathComponent:r];
    }
    PlayerSettings ps; player_settings_from_ini(ini, root.fileSystemRepresentation, &ps);
    if (!dir && ![path.pathExtension.lowercaseString isEqual:@"ini"])
        ps.cfg.start = hostfs::to_sjis(path.lastPathComponent.UTF8String);
    if (!startOverride.empty()) ps.cfg.start = startOverride;
    if (ps.cfg.start.empty() && !ps.cfg.boot_fd) {
        NSOpenPanel* select = [NSOpenPanel openPanel]; select.directoryURL = [NSURL fileURLWithPath:root];
        select.message = @"起動するBAT／COM／EXEを選んでください（ゲームフォルダ内）。";
        if ([select runModal] != NSModalResponseOK) return;
        NSString* prefix = [root.stringByStandardizingPath stringByAppendingString:@"/"];
        NSString* selected = select.URL.path.stringByStandardizingPath;
        if (![selected hasPrefix:prefix]) { alert(@"ゲームフォルダ内のファイルを選んでください。"); return; }
        ps.cfg.start = hostfs::to_sjis([selected substringFromIndex:prefix.length].UTF8String);
    }
    // macOS MIDI output is not implemented yet; do not advertise a silent MIDI device.
    if (ps.cfg.midi) ps.cfg.midi = 0;
    ps.sample_rate = std::clamp(ps.sample_rate, 8000, 192000);
    mouseMode = std::clamp(ini.geti("PC98PLAYER.MOUSELOCKDISABLE",0),0,2);
    mouseSpeed = std::clamp(ini.geti("PC98PLAYER.MOUSESPEED",100),1,1000);
    NSURL* source = [NSURL fileURLWithPath:root isDirectory:YES];
    BOOL scoped = [source startAccessingSecurityScopedResource];
    paused = true; audio.close();
    if (player) player->shutdown();
    if (self.sourceScoped) [self.sourceURL stopAccessingSecurityScopedResource];
    self.sourceURL = source; self.sourceScoped = scoped;
    player = std::make_unique<Player>();
    player->ask_pc9821 = [](void*) -> bool {
        NSAlert* prompt = [NSAlert new];
        prompt.messageText = @"256色対応の機種として起動しますか？";
        prompt.informativeText = @"このソフトは拡張グラフィックを確認しています。16色で起動したい場合は「16色」を選んでください。INIのPC9821またはVideoColorsで起動方法を指定できます。";
        [prompt addButtonWithTitle:@"256色"]; [prompt addButtonWithTitle:@"16色"];
        return [prompt runModal] == NSAlertFirstButtonReturn;
    };
    mac_install_font(ps.font_name, ps.font_shift);
    std::string error;
    if (!player->init(ps,&error)) { alert(ns(error)); player->shutdown(); player.reset(); return; }
    currentIniPath = iniPath; currentSettings = ps;
    NSError* bookmarkError = nil;
    if (![GameLibrary rememberURL:[NSURL fileURLWithPath:path isDirectory:dir] name:root.lastPathComponent error:&bookmarkError])
        NSLog(@"ゲームフォルダの登録に失敗: %@",bookmarkError.localizedDescription);
    [self refreshLibrary];
    self.window.representedFilename = iniPath;
    self.window.title = ps.title.empty() ? [@"PC98PLAYER — " stringByAppendingString:root.lastPathComponent] : ns(ps.title);
    self.window.contentAspectRatio = NSMakeSize(640,player->fb_h);
    [self.window setContentSize:NSMakeSize(640*ps.scale,player->fb_h*ps.scale)];
    if (!muted && !audio.open(ps.sample_rate)) alert(@"音声デバイスを開けませんでした。映像のみで続行します。");
    for (const auto* e : {&player->floppy_error,&player->cd_error,&player->rhythm_error}) if (!e->empty()) alert(ns(*e));
    paused = false; frameCount = 0; self.nextFrame = NSProcessInfo.processInfo.systemUptime;
    if (ps.fullscreen && !(self.window.styleMask & NSWindowStyleMaskFullScreen)) [self.window toggleFullScreen:nil];
    [self.view setNeedsDisplay:YES];
}
- (void)tick:(NSTimer*)timer {
    if (!player || paused) return;
    double now = NSProcessInfo.processInfo.systemUptime;
    if (now - self.nextFrame > frameSeconds*3) self.nextFrame = now;
    int n = 0;
    while (now >= self.nextFrame && n++ < 3) {
        player->run_frame();
        if (self.window.contentAspectRatio.height != player->fb_h) {
            self.window.contentAspectRatio = NSMakeSize(640,player->fb_h);
            if (!(self.window.styleMask & NSWindowStyleMaskFullScreen))
                [self.window setContentSize:NSMakeSize(self.window.contentView.bounds.size.width,self.window.contentView.bounds.size.width*player->fb_h/640)];
        }
        audio.push(player->audio); ++frameCount; self.nextFrame += frameSeconds;
        if (frameLimit && frameCount >= frameLimit) {
            if (screenshotPath) [framebuffer().TIFFRepresentation writeToFile:screenshotPath atomically:YES];
            [NSApp terminate:nil]; return;
        }
        if (player->m->quit) {
            if (player->m->quit == 2) { paused = true; releaseInput(); audio.clear(); alert(ns(player->m->status)); }
            else if (player->ps.exit_on_end) [NSApp terminate:nil];
            else { paused = true; audio.clear(); }
            break;
        }
    }
    [self.view setNeedsDisplay:YES];
}
- (void)pause:(id)sender { paused = !paused; releaseInput(); audio.clear(); self.nextFrame = NSProcessInfo.processInfo.systemUptime; }
- (void)restart:(id)sender {
    if (!player) return;
    if ([NSFileManager.defaultManager fileExistsAtPath:currentIniPath]) { [self openPath:currentIniPath]; return; }
    releaseInput(); audio.clear(); std::string error;
    if (!player->reboot(currentSettings,&error)) { paused = true; alert(ns(error)); }
    else { paused = false; self.nextFrame = NSProcessInfo.processInfo.systemUptime; }
}
- (void)editIni:(id)sender {
    NSString* path = self.window.representedFilename;
    if (path.length && [NSFileManager.defaultManager fileExistsAtPath:path]) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]];
    else alert(@"INIはまだありません。「設定INI作成.html」で作成し、ゲームフォルダにPC98PLAYER.INIとして保存してください。");
}
- (void)refreshLibrary {
    [self.libraryMenu removeAllItems];
    NSArray* entries = GameLibrary.entries;
    for (NSUInteger i=0; i<entries.count; ++i) {
        NSMenuItem* entry = item(self.libraryMenu, entries[i][@"name"], @selector(openRecent:), @""); entry.tag = i;
    }
    if (!entries.count) { NSMenuItem* empty = [NSMenuItem new]; empty.title = @"フォルダを開くと登録されます"; empty.enabled = NO; [self.libraryMenu addItem:empty]; }
}
- (void)openRecent:(NSMenuItem*)sender {
    NSArray* entries = GameLibrary.entries;
    if ((NSUInteger)sender.tag >= entries.count) return;
    NSError* error = nil; NSURL* url = [GameLibrary resolveEntry:entries[sender.tag] error:&error];
    BOOL scoped = [url startAccessingSecurityScopedResource];
    if (!url || ![url checkResourceIsReachableAndReturnError:&error])
        alert(@"フォルダに接続できません。NASの場合はFinderで再接続してから開いてください。");
    else [self openPath:url.path];
    if (scoped) [url stopAccessingSecurityScopedResource];
}
- (void)connectNAS:(id)sender {
    releaseInput(); BOOL previous = paused; paused = true; audio.clear();
    NSAlert* dialog = [NSAlert new]; dialog.messageText = @"NASに接続";
    dialog.informativeText = @"smb://サーバー名/共有名 を入力してください。接続と認証はFinderが行います。接続後、⌘Oで共有内のゲームフォルダを選びます。";
    NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,360,24)]; field.placeholderString = @"smb://nas.local/Games";
    dialog.accessoryView = field; [dialog addButtonWithTitle:@"Finderで接続"]; [dialog addButtonWithTitle:@"キャンセル"];
    if ([dialog runModal] == NSAlertFirstButtonReturn) {
        NSURL* url = [NSURL URLWithString:field.stringValue];
        if (![url.scheme.lowercaseString isEqual:@"smb"] || !url.host.length || url.user.length || url.password.length)
            alert(@"ユーザー名やパスワードを含めず、smb://サーバー名/共有名 の形式で入力してください。");
        else [NSWorkspace.sharedWorkspace openURL:url];
    }
    paused = previous; self.nextFrame = NSProcessInfo.processInfo.systemUptime;
}
- (void)toggleCapture:(id)sender { capture(!captured); }
- (void)fullscreen:(id)sender { [self.window toggleFullScreen:nil]; }
- (void)stopKey:(id)sender { if(player) { machine_key(player->m,0x60,true); machine_key(player->m,0x60,false); } }
- (void)saveState:(NSMenuItem*)sender {
    if (!player) return;
    releaseInput(); std::string error;
    if (!player->save_state((int)sender.tag,&error)) alert(ns(error));
}
- (void)loadState:(NSMenuItem*)sender {
    if (!player) return;
    releaseInput(); audio.clear(); std::string error;
    if (!player->load_state((int)sender.tag,&error)) alert(ns(error));
    releaseInput(); self.nextFrame = NSProcessInfo.processInfo.systemUptime; [self.view setNeedsDisplay:YES];
}
- (void)windowDidResignKey:(NSNotification*)n { releaseInput(); }
- (void)applicationDidResignActive:(NSNotification*)n { releaseInput(); }
- (void)applicationWillTerminate:(NSNotification*)n {
    [self.timer invalidate]; releaseInput(); audio.close();
    if (player) { player->shutdown(); player.reset(); }
    if (self.sourceScoped) [self.sourceURL stopAccessingSecurityScopedResource];
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end

int main(int argc, char** argv) {
    @autoreleasepool {
        for (int i = 1; i < argc; ++i) {
            std::string a = argv[i];
            if (a == "--help") {
                puts("PC98PLAYER [game-folder|INI|BAT|COM|EXE] [--start DOS-command] [--mute] [--frames N --screenshot output.tiff]"); return 0;
            } else if (a == "--mute") muted = true;
            else if (a == "--start" && i+1 < argc) startOverride = argv[++i];
            else if (a == "--frames" && i+1 < argc) frameLimit = std::max(1,atoi(argv[++i]));
            else if (a == "--screenshot" && i+1 < argc) screenshotPath = ns(argv[++i]);
            else if (!a.empty() && a[0] != '-') initialPath = ns(a);
        }
        extern std::string g_app_dir;
        g_app_dir = NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent.fileSystemRepresentation;
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate* delegate = [AppDelegate new]; appDelegate = delegate; NSApp.delegate = delegate;
        [NSApp run];
    }
    return 0;
}
