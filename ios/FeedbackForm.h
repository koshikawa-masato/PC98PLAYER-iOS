#import <UIKit/UIKit.h>

NSString* PC98FeedbackAppVersion(void);
UIViewController* PC98FeedbackForm(NSString* version, UIImage* screenshot);
UIViewController* PC98FeedbackFormWithContext(NSString* version, UIImage* screenshot,
    NSDictionary* diagnostics, NSString* errorSummary, void (^completed)(void));
