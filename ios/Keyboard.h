// SPDX-License-Identifier: MIT
#import <UIKit/UIKit.h>
@interface PC98Keyboard : UIView
@property(nonatomic) BOOL hardwareLayout;
@property(nonatomic) BOOL outlinesOnly;
@property(nonatomic) BOOL landscapeEdgeControls;
@property(copy) void (^pauseChanged)(void);
@property(copy) void (^controllerSettingsOpening)(void);
- (void)loadControllerBindingsForGame:(NSString*)identifier;
- (void)updateControllerPause:(BOOL)paused enabled:(BOOL)enabled;
@property(copy) void (^keyChanged)(int scan, BOOL down);
// タッチパッドモード：パッド面のドラッグ量（ポイント）と、クリック（1=左、2=右）を通知する
@property(copy) void (^mouseMoved)(CGPoint delta);
@property(copy) void (^mouseClicked)(int button);
// タッチパッドモードで上端から空けておく高さ（パネル上に重なるツールバー分）
@property(nonatomic) CGFloat touchpadTopInset;
// モード切替スワイプで、パネルと一緒にスライドさせる相手（ゲーム画面のキャビネット）
@property(nonatomic, weak) UIView* swipeCompanionView;
// コントローラーモードで上端から空けておく高さ（同上：ポーズ／キー設定ボタンの配置用）
@property(nonatomic) CGFloat controllerTopInset;
- (void)releaseAll;
- (void)repeatHeldKeys;
// コントローラーの操作子（十字キー・アクションボタン・ポーズボタン）の周囲 margin ポイント以内かどうか（自ビューの座標系）
// actionMargin はアクションボタン（と同時押し判定エリア）専用の広めのマージン
- (BOOL)isNearControllerControls:(CGPoint)point margin:(CGFloat)margin;
- (BOOL)isNearControllerControls:(CGPoint)point margin:(CGFloat)margin actionMargin:(CGFloat)actionMargin;
#ifdef PC98PLAYER_TESTING
- (BOOL)controllerChordForTesting:(BOOL (^)(int scan))isDown;
- (BOOL)controlMarginForTesting;
- (BOOL)touchpadForTesting:(BOOL (^)(int button))isDown;
- (BOOL)tapReturnSectionsForTesting;
- (BOOL)hardwareLayoutForTesting;
- (BOOL)tapScanForTesting:(int)scan;
- (BOOL)pressScansForTesting:(NSArray<NSNumber*>*)scans;
- (BOOL)releaseScanForTesting:(int)scan cancelled:(BOOL)cancelled;
#endif
@end
// USB HID usages from hardware keyboards share the guest scan codes with touch keys.
int pc98_scan_from_hid(NSInteger usage);

NSArray<NSNumber*>* pc98_controller_bindings(NSArray<NSNumber*>* saved);
UIMenu* pc98_controller_binding_menu(NSArray<NSNumber*>* bindings, NSMutableArray<NSString*>* names,
                                    void (^changed)(NSArray<NSNumber*>*));
