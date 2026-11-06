// Used only by tools/capture_store_screens.py for iPad App Store screenshots.
// iPadOS 26+ windowing refuses the app's requestGeometryUpdate, but rotating the
// simulated device itself (XCUIDevice) still rotates the app, as on a real iPad.
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

@interface StoreOrientationUITests : XCTestCase
@end

@implementation StoreOrientationUITests
- (void)testHoldStoreOrientation {
    NSDictionary<NSString*,NSString*>* env=NSProcessInfo.processInfo.environment;
    NSString* bundle=env[@"STORE_BUNDLE_ID"] ?: @"jp.pc98player.ios";
    NSString* orientation=env[@"STORE_ORIENTATION"] ?: @"portrait";
    NSString* arguments=env[@"STORE_LAUNCH_ARGUMENTS"] ?: @"";
    NSString* done=env[@"STORE_DONE_FILE"];
    XCTAssertTrue(done.length>0, @"STORE_DONE_FILE is required");

    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationPortrait;
    XCUIApplication* app=[[XCUIApplication alloc] initWithBundleIdentifier:bundle];
    app.launchArguments=arguments.length ? [arguments componentsSeparatedByString:@" "] : @[];
    [app launch];
    XCUIDevice.sharedDevice.orientation=[orientation isEqualToString:@"landscape"] ? UIDeviceOrientationLandscapeLeft : UIDeviceOrientationPortrait;

    // Hold this orientation until the capture script has taken its screenshot.
    NSDate* limit=[NSDate dateWithTimeIntervalSinceNow:300];
    while(![NSFileManager.defaultManager fileExistsAtPath:done] && limit.timeIntervalSinceNow>0)
        [NSThread sleepForTimeInterval:0.5];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:done], @"Capture script did not finish");
    XCUIDevice.sharedDevice.orientation=UIDeviceOrientationPortrait;
}
@end
