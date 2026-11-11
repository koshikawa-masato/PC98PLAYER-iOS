// SPDX-License-Identifier: MIT
#import "FeedbackForm.h"
#import "FeedbackDiagnostics.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static NSString* FeedbackRandomToken(void) {
    unsigned char bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof bytes, bytes) != errSecSuccess) return nil;
    NSString* token = [[NSData dataWithBytes:bytes length:sizeof bytes] base64EncodedStringWithOptions:0];
    return [[[token stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
        stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

@interface FeedbackFormController : UIViewController <ASWebAuthenticationPresentationContextProviding, NSURLSessionTaskDelegate, UIGestureRecognizerDelegate>
@property(copy) NSString* version;
@property(strong) UIImage* screenshot;
@property(copy) NSString* diagnosticJSON;
@property(copy) NSString* errorSummary;
@property(copy) void (^completed)(void);
@property(strong) UISwitch* includeDiagnostics;
@property(strong) NSURL* endpoint;
@property(strong) UITextField* subject;
@property(strong) UITextView* details;
@property(strong) UISwitch* includeImage;
@property(strong) UISegmentedControl* identity;
@property(strong) UIBarButtonItem* sendButton;
@property(strong) ASWebAuthenticationSession* authentication;
@property(copy) NSString* receiptKey;
@property(copy) NSString* submissionVerifier;
@property(copy) NSDictionary* pendingReport;
@end

@implementation FeedbackFormController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"不具合を報告";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    NSString* configured = [NSBundle.mainBundle objectForInfoDictionaryKey:@"RetroDOSFeedbackURL"];
    NSURLComponents* url = [NSURLComponents componentsWithString:configured ?: @""];
    if ([url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length &&
        !url.user && !url.password && !url.query && !url.fragment) self.endpoint = url.URL;

    UIScrollView* scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UITapGestureRecognizer* dismissKeyboard = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(hideKeyboard)];
    dismissKeyboard.cancelsTouchesInView = NO;
    dismissKeyboard.delegate = self;
    [self.view addGestureRecognizer:dismissKeyboard];
    UIStackView* stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32]
    ]];

    UILabel* intro = [UILabel new];
    intro.numberOfLines = 0;
    intro.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    intro.text = @"匿名・Xの報告は開発者へのメールになります。GitHubを選ぶと、報告は公開Issueになります。";
    [stack addArrangedSubview:intro];

    self.subject = [UITextField new];
    self.subject.placeholder = @"件名";
    self.subject.accessibilityLabel = @"件名";
    self.subject.borderStyle = UITextBorderStyleRoundedRect;
    if (self.errorSummary.length) self.subject.text = self.errorSummary;
    [stack addArrangedSubview:self.subject];

    UILabel* description = [UILabel new];
    description.text = @"症状・再現手順";
    [stack addArrangedSubview:description];
    self.details = [UITextView new];
    self.details.accessibilityLabel = description.text;
    self.details.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.details.layer.cornerRadius = 8;
    if (self.errorSummary.length) self.details.text = [NSString stringWithFormat:
        @"発生した問題：%@\n\n直前に行った操作：\n\n期待していた動作：\n\n再現する頻度：", self.errorSummary];
    [self.details.heightAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;
    [stack addArrangedSubview:self.details];

    self.subject.inputAccessoryView = [self keyboardToolbar];
    self.details.inputAccessoryView = [self keyboardToolbar];

    if (self.screenshot) {
        self.includeImage = [UISwitch new];
        self.includeImage.accessibilityLabel = @"ゲーム画面を添付";
        UILabel* caption = [UILabel new];
        caption.text = self.includeImage.accessibilityLabel;
        UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[caption, self.includeImage]];
        row.alignment = UIStackViewAlignmentCenter;
        [stack addArrangedSubview:row];
        UIImageView* preview = [[UIImageView alloc] initWithImage:self.screenshot];
        preview.contentMode = UIViewContentModeScaleAspectFit;
        preview.accessibilityLabel = @"添付候補のゲーム画面";
        preview.isAccessibilityElement = YES;
        [preview.heightAnchor constraintEqualToConstant:120].active = YES;
        [stack addArrangedSubview:preview];
    }

    if (self.diagnosticJSON.length) {
        self.includeDiagnostics = [UISwitch new];
        self.includeDiagnostics.accessibilityLabel = @"診断情報（JSON）を本文に添付";
        UILabel* caption = [UILabel new];
        caption.text = self.includeDiagnostics.accessibilityLabel;
        caption.numberOfLines = 0;
        UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[caption, self.includeDiagnostics]];
        row.alignment = UIStackViewAlignmentCenter;
        [stack addArrangedSubview:row];
        UIButton* preview = [UIButton buttonWithType:UIButtonTypeSystem];
        [preview setTitle:@"診断情報の内容を確認" forState:UIControlStateNormal];
        [preview addTarget:self action:@selector(showDiagnostics) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:preview];
        UILabel* note = [UILabel new];
        note.numberOfLines = 0;
        note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        note.text = @"設定・画面の寸法・処理速度・エラーの種類を添付できます。ゲームデータ、セーブ、入力履歴、フォルダのパスは含みません。GitHubを選ぶと診断情報も公開されます。";
        [stack addArrangedSubview:note];
    }

    self.identity = [[UISegmentedControl alloc] initWithItems:@[@"匿名", @"GitHub", @"X"]];
    self.identity.accessibilityLabel = @"報告者の認証方法";
    self.identity.selectedSegmentIndex = 0;
    [self.identity addTarget:self action:@selector(updateSendLabel) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.identity];

    UILabel* privacy = [UILabel new];
    privacy.numberOfLines = 0;
    privacy.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    privacy.textColor = UIColor.secondaryLabelColor;
    privacy.text = @"報告はCloudflare経由で届きます。非公開の受付データは30日間保管します。メール・公開Issueは別に保持されます。詳しくはオプションのプライバシーポリシーをご覧ください。";
    [stack addArrangedSubview:privacy];

    if (!self.endpoint) {
        UILabel* unavailable = [UILabel new];
        unavailable.numberOfLines = 0;
        unavailable.text = @"受付サーバーの設定後に認証・送信できます。";
        unavailable.textColor = UIColor.secondaryLabelColor;
        [stack addArrangedSubview:unavailable];
    }
    self.sendButton = [[UIBarButtonItem alloc] initWithTitle:@"送信"
        style:UIBarButtonItemStyleDone target:self action:@selector(sendReport)];
    self.sendButton.enabled = self.endpoint != nil;
    self.navigationItem.rightBarButtonItem = self.sendButton;
    [self updateSendLabel];
}

- (UIToolbar*)keyboardToolbar {
    UIToolbar* toolbar = [UIToolbar new];
    UIBarButtonItem* spacer = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem* hide = [[UIBarButtonItem alloc] initWithTitle:@"キーボードを閉じる"
        style:UIBarButtonItemStyleDone target:self action:@selector(hideKeyboard)];
    toolbar.items = @[spacer, hide];
    [toolbar sizeToFit];
    return toolbar;
}

- (void)hideKeyboard {
    [self.view endEditing:YES];
}

- (void)showDiagnostics {
    [self.view endEditing:YES];
    UIViewController* preview = [UIViewController new];
    preview.title = @"診断情報（送信前の確認）";
    UITextView* text = [UITextView new];
    text.editable = NO;
    text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    text.text = self.diagnosticJSON;
    text.accessibilityLabel = @"送信する診断情報JSON";
    preview.view = text;
    [self.navigationController pushViewController:preview animated:YES];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer shouldReceiveTouch:(UITouch*)touch {
    for (UIView* view = touch.view; view && view != self.view; view = view.superview) {
        if (view == self.subject || view == self.details || [view isKindOfClass:UIControl.class]) return NO;
    }
    return YES;
}

- (void)updateSendLabel {
    NSInteger mode = self.identity.selectedSegmentIndex;
    self.sendButton.title = mode == 1 ? @"Issueに投稿" : mode == 2 ? @"Xで認証して送信" : @"メールで送信";
}

- (void)showMessage:(NSString*)message completed:(BOOL)completed {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"不具合を報告"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        if (completed) {
            if (self.navigationController.viewControllers.count > 1)
                [self.navigationController popViewControllerAnimated:YES];
            else
                [self dismissViewControllerAnimated:YES completion:self.completed];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)sendReport {
    if (!self.sendButton.enabled) return;
    [self.view endEditing:YES];
    NSCharacterSet* whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString* title = [self.subject.text stringByTrimmingCharactersInSet:whitespace];
    NSString* body = [self.details.text stringByTrimmingCharactersInSet:whitespace];
    if (!title.length || !body.length || title.length > 120 || body.length > 8000) {
        [self showMessage:@"件名（120文字以内）と症状・再現手順（8,000文字以内）を入力してください。" completed:NO];
        return;
    }
    body = PC98FeedbackBody(body, self.diagnosticJSON, self.includeDiagnostics.on);
    if (body.length > 8000) {
        [self showMessage:@"診断情報を含めて8,000文字以内になるよう本文を短くするか、診断情報の添付をオフにしてください。" completed:NO];
        return;
    }
    NSMutableDictionary* report = [@{@"title":title, @"body":body, @"app_version":self.version,
        @"os_version":UIDevice.currentDevice.systemVersion} mutableCopy];
    if (self.includeImage.on) {
        NSData* png = UIImagePNGRepresentation(self.screenshot);
        if (!png.length || png.length > 2 * 1024 * 1024) {
            [self showMessage:@"画像を添付できませんでした。画像なしで送信できます。" completed:NO];
            return;
        }
        report[@"screenshot_png"] = [png base64EncodedStringWithOptions:0];
    }
    if (self.identity.selectedSegmentIndex == 1) {
        UIAlertController* confirmation = [UIAlertController alertControllerWithTitle:@"公開Issueに投稿しますか？"
            message:@"件名・本文・環境情報・GitHubユーザー名が公開されます。添付画像は公開されません。"
            preferredStyle:UIAlertControllerStyleAlert];
        [confirmation addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
        __weak FeedbackFormController* weakSelf = self;
        [confirmation addAction:[UIAlertAction actionWithTitle:@"GitHubで認証して投稿" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction* action) { report[@"publish_consent"] = @YES; [weakSelf sendPreparedReport:report]; }]];
        [self presentViewController:confirmation animated:YES completion:nil];
        return;
    }
    [self sendPreparedReport:report];
}

- (void)sendPreparedReport:(NSMutableDictionary*)report {
    self.sendButton.enabled = NO;
    self.navigationItem.hidesBackButton = YES;
    self.navigationItem.leftBarButtonItem.enabled = NO;
    self.identity.enabled = NO;
    self.subject.enabled = NO;
    self.details.editable = NO;
    self.includeImage.enabled = NO;
    NSString* provider = @[@"anonymous", @"github", @"x"][self.identity.selectedSegmentIndex];
    report[@"provider"] = provider;
    if (![self.pendingReport isEqualToDictionary:report]) {
        self.pendingReport = [report copy];
        self.receiptKey = NSUUID.UUID.UUIDString;
        self.submissionVerifier = FeedbackRandomToken();
    }
    if (!self.submissionVerifier) {
        [self finishSend];
        [self showMessage:@"安全な送信を準備できませんでした。もう一度お試しください。" completed:NO];
        return;
    }

    NSURL* capabilitiesURL = [self.endpoint URLByAppendingPathComponent:@"capabilities"];
    NSURLSession* checkSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
        delegate:self delegateQueue:nil];
    NSMutableURLRequest* check = [NSMutableURLRequest requestWithURL:capabilitiesURL];
    check.timeoutInterval = 15;
    __weak FeedbackFormController* weakForm = self;
    [[checkSession dataTaskWithRequest:check completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id providers = [json isKindOfClass:NSDictionary.class] ? json[@"providers"] : nil;
        BOOL available = !error && [response isKindOfClass:NSHTTPURLResponse.class] &&
            ((NSHTTPURLResponse*)response).statusCode == 200 && [providers isKindOfClass:NSDictionary.class] &&
            [providers[provider] isEqual:@YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            FeedbackFormController* form = weakForm;
            if (!form) return;
            if (available) [form authenticateReport:report provider:provider];
            else {
                [form finishSend];
                [form showMessage:@"選択した受付方法は現在利用できません。内容を保持しています。別の方法を選ぶか、後でもう一度お試しください。" completed:NO];
            }
        });
    }] resume];
    [checkSession finishTasksAndInvalidate];
}

- (void)authenticateReport:(NSMutableDictionary*)report provider:(NSString*)provider {
    NSString* verifier = self.submissionVerifier;
    NSData* bytes = [verifier dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash);
    NSString* challenge = [[NSData dataWithBytes:hash length:sizeof hash] base64EncodedStringWithOptions:0];
    challenge = [[[challenge stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
        stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
    NSString* state = NSUUID.UUID.UUIDString;
    NSURL* start = [[self.endpoint URLByAppendingPathComponent:@"auth"] URLByAppendingPathComponent:provider];
    NSURLComponents* login = [NSURLComponents componentsWithURL:start resolvingAgainstBaseURL:NO];
    login.queryItems = @[[NSURLQueryItem queryItemWithName:@"state" value:state],
        [NSURLQueryItem queryItemWithName:@"code_challenge" value:challenge],
        [NSURLQueryItem queryItemWithName:@"submission_id" value:self.receiptKey]];
    __weak FeedbackFormController* weakSelf = self;
    self.authentication = [[ASWebAuthenticationSession alloc] initWithURL:login.URL callbackURLScheme:@"retrodos-feedback"
        completionHandler:^(NSURL* callback, NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FeedbackFormController* form = weakSelf;
                if (!form) return;
                form.authentication = nil;
                NSURLComponents* result = callback ? [NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO] : nil;
                NSString* code = nil;
                NSString* returnedState = nil;
                NSString* returnedProvider = nil;
                NSString* returnedError = nil;
                NSMutableSet* names = [NSMutableSet set];
                BOOL duplicate = NO;
                for (NSURLQueryItem* item in result.queryItems) {
                    if ([names containsObject:item.name]) duplicate = YES;
                    [names addObject:item.name];
                    if ([item.name isEqualToString:@"code"]) code = item.value;
                    if ([item.name isEqualToString:@"state"]) returnedState = item.value;
                    if ([item.name isEqualToString:@"provider"]) returnedProvider = item.value;
                    if ([item.name isEqualToString:@"error"]) returnedError = item.value;
                }
                BOOL callbackValid = !duplicate && [result.scheme isEqualToString:@"retrodos-feedback"] &&
                    [result.host isEqualToString:@"callback"] && !result.path.length && !result.port &&
                    !result.user && !result.password && !result.fragment && [returnedState isEqualToString:state] &&
                    [returnedProvider isEqualToString:provider];
                if (error || !callbackValid || returnedError || code.length != 43 ||
                    [code rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
                        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet]].location != NSNotFound) {
                    [form finishSend];
                    if (!([error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain] &&
                            error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin) &&
                        !(callbackValid && [returnedError isEqualToString:@"cancelled"]))
                        [form showMessage:@"認証を完了できませんでした。" completed:NO];
                    return;
                }
                report[@"auth_code"] = code;
                report[@"code_verifier"] = verifier;
                [form submitReport:report];
            });
        }];
    self.authentication.presentationContextProvider = self;
    if (![self.authentication start]) {
        self.authentication = nil;
        [self finishSend];
        [self showMessage:@"認証画面を開けませんでした。" completed:NO];
    }
}

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession*)session {
    return self.view.window;
}

- (void)finishSend {
    self.sendButton.enabled = YES;
    self.navigationItem.hidesBackButton = NO;
    self.navigationItem.leftBarButtonItem.enabled = YES;
    self.identity.enabled = YES;
    self.subject.enabled = YES;
    self.details.editable = YES;
    self.includeImage.enabled = YES;
}

- (void)submitReport:(NSDictionary*)report {
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:self.endpoint];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:self.receiptKey forHTTPHeaderField:@"Idempotency-Key"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
        delegate:self delegateQueue:nil];
    [[session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary* result = [json isKindOfClass:NSDictionary.class] ? json : nil;
        NSString* receipt = [result[@"receipt"] isKindOfClass:NSString.class] ? result[@"receipt"] : nil;
        BOOL accepted = !error && (status == 201 || status == 202) &&
            [result[@"status"] isEqual:@"accepted"] && receipt && [[NSUUID alloc] initWithUUIDString:receipt];
        NSString* message = accepted ? [NSString stringWithFormat:@"報告を受け付けました。\n受付番号：%@", receipt] :
            status == 429 ? @"送信回数の上限に達しました。内容を保持しています。時間をおいてお試しください。" :
            status == 503 ? @"受付または選択した認証方法は現在準備中です。内容を保持しています。" :
            @"送信を確認できませんでした。内容を保持しています。もう一度お試しください。";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!accepted) [self finishSend];
            [self showMessage:message completed:accepted];
        });
    }] resume];
    [session finishTasksAndInvalidate];
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task
    willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request
    completionHandler:(void (^)(NSURLRequest*))completionHandler {
    completionHandler(nil);
}
@end

NSString* PC98FeedbackAppVersion(void) {
    NSBundle* bundle = NSBundle.mainBundle;
    NSString* version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"—";
    NSString* build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    return build.length ? [NSString stringWithFormat:@"%@（ビルド %@）", version, build] : version;
}

UIViewController* PC98FeedbackForm(NSString* version, UIImage* screenshot) {
    return PC98FeedbackFormWithContext(version, screenshot, nil, nil, nil);
}
UIViewController* PC98FeedbackFormWithContext(NSString* version, UIImage* screenshot,
    NSDictionary* diagnostics, NSString* errorSummary, void (^completed)(void)) {
    FeedbackFormController* form = [FeedbackFormController new];
    form.version = version;
    form.screenshot = screenshot;
    form.diagnosticJSON = PC98FeedbackDiagnosticJSON(diagnostics);
    form.errorSummary = errorSummary;
    form.completed = completed;
    return form;
}
