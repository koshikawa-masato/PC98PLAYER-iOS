#import <XCTest/XCTest.h>

@interface FullscreenMenuUITests : XCTestCase
@end

@implementation FullscreenMenuUITests
- (void)testLongPressPauseAndTapResume {
    [self checkPauseInOrientation:UIDeviceOrientationPortrait launchFullscreen:YES];
}
- (void)testPauseAfterDoubleTapAndRotation {
    [self checkPauseInOrientation:UIDeviceOrientationLandscapeLeft launchFullscreen:NO];
}
- (void)checkPauseInOrientation:(UIDeviceOrientation)orientation launchFullscreen:(BOOL)launchFullscreen {
    self.continueAfterFailure=NO;
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationPortrait;
    XCUIApplication* app=[[XCUIApplication alloc] initWithBundleIdentifier:@"jp.pc98player.ios"];
    app.launchArguments=@[@"--demo",@"-PC98LaunchFullscreen",launchFullscreen?@"YES":@"NO",
        @"-PC98BossMode",@"NO",@"-PC98AdultFilter",@"NO",@"-PC98HarmFilter",@"NO"];
    [app launch];
    if(!launchFullscreen) {
        XCTAssertTrue([app.buttons[@"オプション"] waitForExistenceWithTimeout:10]);
        [[app.windows.firstMatch coordinateWithNormalizedOffset:CGVectorMake(.5,.23)] doubleTap];
    }
    XCUIDevice.sharedDevice.orientation=orientation;
    XCTAssertTrue([app.buttons[@"一時停止"] waitForExistenceWithTimeout:10]);

    XCUICoordinate* monitor=[app.windows.firstMatch coordinateWithNormalizedOffset:CGVectorMake(.5,.5)];
    [monitor pressForDuration:.8];
    NSPredicate* menuLabel=[NSPredicate predicateWithFormat:@"label == %@",@"一時停止"];
    XCUIElementQuery* pauses=[app.buttons matchingPredicate:menuLabel];
    XCTAssertTrue([app.buttons[@"リセット"] waitForExistenceWithTimeout:5],@"Long press must open the operations menu");
    [[pauses elementBoundByIndex:pauses.count-1] tap];
    XCTAssertTrue([app.buttons[@"再開"] waitForExistenceWithTimeout:5],@"Pause selected in the menu must remain active after dismissal");
    [NSThread sleepForTimeInterval:1];
    XCTAssertTrue(app.buttons[@"再開"].exists,@"The selecting touch must not resume playback");
    [monitor tap];
    XCTAssertTrue([app.buttons[@"一時停止"] waitForExistenceWithTimeout:5],@"A new monitor tap must resume playback");
    [app terminate];
}
@end
