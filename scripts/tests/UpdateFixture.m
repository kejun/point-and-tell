// Test-only app; never bundled in Point & Tell. Exercises Sparkle's real
// replacement/relaunch using a temporary bundle, private feed and disposable key.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

@interface UpdateFixture : NSObject <NSApplicationDelegate, SPUUserDriver>
@property(strong) SPUUpdater *updater;
@end

@implementation UpdateFixture
- (void)recordResult:(NSString *)result {
    NSString *path = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"PTTestResult"];
    [result writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if ([[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"2"]) {
        [self recordResult:@"UPDATED_AND_RELAUNCHED"];
        [NSApp terminate:nil];
        return;
    }
    self.updater = [[SPUUpdater alloc] initWithHostBundle:[NSBundle mainBundle]
        applicationBundle:[NSBundle mainBundle] userDriver:self delegate:nil];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) {
        [self recordResult:[@"FAILED: " stringByAppendingString:error.description]];
        [NSApp terminate:nil];
        return;
    }
    [self.updater checkForUpdates];
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    [self showUpdaterError:error acknowledgement:acknowledgement];
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    [self recordResult:[@"FAILED: " stringByAppendingString:error.description]];
    acknowledgement();
    [NSApp terminate:nil];
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate {}
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement { acknowledgement(); }
- (void)dismissUpdateInstallation {}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        UpdateFixture *fixture = [UpdateFixture new];
        app.delegate = fixture;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
