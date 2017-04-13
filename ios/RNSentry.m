#import "RNSentry.h"
#import "RSSwizzle.h"
#if __has_include(<React/RCTConvert.h>)
#import <React/RCTConvert.h>
#else
#import "RCTConvert.h"
#endif


@import Sentry;

@implementation RNSentry

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

+ (void)installWithBridge:(RCTBridge *)bridge {
    RNSentry *sentry = [bridge moduleForName:@"RNSentry"];
    [[bridge moduleForName:@"ExceptionsManager"] initWithDelegate:sentry];
}

+ (void)installWithRootView:(RCTRootView *)rootView {
    [RNSentry installWithBridge: rootView.bridge];
}

+ (NSNumberFormatter *)numberFormatter {
    static dispatch_once_t onceToken;
    static NSNumberFormatter *formatter = nil;
    dispatch_once(&onceToken, ^{
        formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterNoStyle;
    });
    return formatter;
}

+ (NSRegularExpression *)frameRegex {
    static dispatch_once_t onceTokenRegex;
    static NSRegularExpression *regex = nil;
    dispatch_once(&onceTokenRegex, ^{
//        NSString *pattern = @"at (.+?) \\((?:(.+?):([0-9]+?):([0-9]+?))\\)"; // Regex with debugger
        NSString *pattern = @"(?:([^@]+)@(.+?):([0-9]+?):([0-9]+))"; // Regex without debugger
        regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    });
    return regex;
}

NSArray *SentryParseJavaScriptStacktrace(NSString *stacktrace) {
    NSNumberFormatter *formatter = [RNSentry numberFormatter];
    NSArray *lines = [stacktrace componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray *frames = [NSMutableArray array];
    for (NSString *line in lines) {
        NSRange searchedRange = NSMakeRange(0, [line length]);
        NSArray *matches = [[RNSentry frameRegex] matchesInString:line options:0 range:searchedRange];
        for (NSTextCheckingResult *match in matches) {
            [frames addObject:@{
                @"methodName": [line substringWithRange:[match rangeAtIndex:1]],
                @"column": [formatter numberFromString:[line substringWithRange:[match rangeAtIndex:4]]],
                @"lineNumber": [formatter numberFromString:[line substringWithRange:[match rangeAtIndex:3]]],
                @"file": [line substringWithRange:[match rangeAtIndex:2]]
            }];
        }
    }
    return frames;
}

NSArray *SentryParseRavenFrames(NSArray *ravenFrames) {
    NSNumberFormatter *formatter = [RNSentry numberFormatter];
    NSMutableArray *frames = [NSMutableArray array];
    for (NSDictionary *ravenFrame in ravenFrames) {
        if (ravenFrame[@"lineno"] != NSNull.null) {
            [frames addObject:@{
                @"methodName": ravenFrame[@"function"],
                @"column": [formatter numberFromString:[NSString stringWithFormat:@"%@", ravenFrame[@"colno"]]],
                @"lineNumber": [formatter numberFromString:[NSString stringWithFormat:@"%@", ravenFrame[@"lineno"]]],
                @"file": ravenFrame[@"filename"]
            }];
        }
    }
    return frames;
}

RCT_EXPORT_MODULE()

- (NSDictionary<NSString *, id> *)constantsToExport
{
    return @{@"nativeClientAvailable": @YES};
}

RCT_EXPORT_METHOD(startWithDsnString:(NSString * _Nonnull)dsnString)
{
    SentryClient *client = [[SentryClient alloc] initWithDsnString:dsnString];
    SentryUserFeedbackViewModel *model = [SentryUserFeedbackViewModel new];
    [client enableUserFeedbackAfterFatalEventWithUserFeedbackViewModel:model];
    [client setDelegate:[[UIApplication sharedApplication] delegate]];
    [SentryClient setShared:client];
    [client startCrashHandler];
}

RCT_EXPORT_METHOD(activateStacktraceMerging:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    static const void *key = &key;
    Class RCTBatchedBridge = NSClassFromString(@"RCTBatchedBridge");
    uintptr_t callNativeModuleAddress = [RCTBatchedBridge instanceMethodForSelector:@selector(callNativeModule:method:params:)];

    RSSwizzleInstanceMethod(RCTBatchedBridge,
                            @selector(callNativeModule:method:params:),
                            RSSWReturnType(id),
                            RSSWArguments(NSUInteger moduleID, NSUInteger methodID, NSArray *params),
                            RSSWReplacement({
        NSMutableArray *newParams = [NSMutableArray array];
        if (params != nil && params.count > 0) {
            for (id param in params) {
                if ([param isKindOfClass:NSDictionary.class] && param[@"__sentry_stack"]) {
                    @synchronized ([SentryClient shared]) {
                        [[SentryClient shared] addExtra:@"__sentry_address" value:[NSNumber numberWithUnsignedInteger:callNativeModuleAddress]];
                        [[SentryClient shared] addExtra:@"__sentry_stack" value:SentryParseJavaScriptStacktrace([RCTConvert NSString:param[@"__sentry_stack"]])];
                    }
                } else {
                    if (param != nil) {
                        [newParams addObject:param];
                    }
                }
            }
        }
        return RSSWCallOriginal(moduleID, methodID, newParams);
    }), RSSwizzleModeOncePerClassAndSuperclasses, key);

    resolve(@YES);
}

RCT_EXPORT_METHOD(clearContext)
{
    [SentryClient shared].tags = @{};
    [SentryClient shared].extra = @{};
    [SentryClient shared].user = nil;
}

RCT_EXPORT_METHOD(setLogLevel:(int)level)
{
    [SentryClient setLogLevel:level];
}

RCT_EXPORT_METHOD(setTags:(NSDictionary * _Nonnull)tags)
{
    [SentryClient shared].tags = [self sanitizeDictionary:tags];
}

RCT_EXPORT_METHOD(setExtra:(NSDictionary * _Nonnull)extra)
{
    [SentryClient shared].extra = extra;
}

RCT_EXPORT_METHOD(setUser:(NSDictionary * _Nonnull)user)
{
    [SentryClient shared].user = [[SentryUser alloc] initWithId:[RCTConvert NSString:user[@"userID"]]
                                                          email:[RCTConvert NSString:user[@"email"]]
                                                       username:[RCTConvert NSString:user[@"username"]]
                                                          extra:[RCTConvert NSDictionary:user[@"extra"]]];
}

RCT_EXPORT_METHOD(captureBreadcrumb:(NSDictionary * _Nonnull)breadcrumb)
{
    SentryBreadcrumb *crumb = [[SentryBreadcrumb alloc] initWithCategory:breadcrumb[@"category"]
                                                               timestamp:[NSDate dateWithTimeIntervalSince1970:[breadcrumb[@"timestamp"] integerValue]]
                                                                 message:breadcrumb[@"message"]
                                                                    type:nil
                                                                   level:[self sentrySeverityFromLevel:[breadcrumb[@"level"] integerValue]]
                                                                    data:nil];
    [[SentryClient shared].breadcrumbs add:crumb];
}

RCT_EXPORT_METHOD(captureEvent:(NSDictionary * _Nonnull)event)
{
    SentrySeverity level = [self sentrySeverityFromLevel:[event[@"level"] integerValue]];

    SentryUser *user = nil;
    if (event[@"user"] != nil) {
        user = [[SentryUser alloc] initWithId:[RCTConvert NSString:event[@"user"][@"userID"]]
                                        email:[RCTConvert NSString:event[@"user"][@"email"]]
                                     username:[RCTConvert NSString:event[@"user"][@"username"]]
                                        extra:[RCTConvert NSDictionary:event[@"user"][@"extra"]]];
    }

    if (event[@"message"]) {
        SentryEvent *sentryEvent = [[SentryEvent alloc] init:event[@"message"]
                                                   timestamp:[NSDate date]
                                                       level:level
                                                      logger:event[@"logger"]
                                                     culprit:nil
                                                  serverName:nil
                                                     release:nil
                                                 buildNumber:nil
                                                        tags:[self sanitizeDictionary:event[@"tags"]]
                                                     modules:nil
                                                       extra:event[@"extra"]
                                                 fingerprint:nil
                                                        user:user
                                                  exceptions:nil
                                                  stacktrace:nil];
        [[SentryClient shared] captureEvent:sentryEvent];
    } else if (event[@"exception"]) {
        // TODO what do we do here with extra/tags/users that are not global?
        [self handleSoftJSExceptionWithMessage:[NSString stringWithFormat:@"Unhandled JS Exception: %@", event[@"exception"][@"values"][0][@"value"]]
                                         stack:SentryParseRavenFrames(event[@"exception"][@"values"][0][@"stacktrace"][@"frames"])
                                   exceptionId:@99];
    }

}

RCT_EXPORT_METHOD(crash)
{
    [[SentryClient shared] crash];
}

- (SentrySeverity)sentrySeverityFromLevel:(NSInteger)level {
    switch (level) {
        case 0:
            return SentrySeverityFatal;
        case 2:
            return SentrySeverityWarning;
        case 3:
            return SentrySeverityInfo;
        case 4:
            return SentrySeverityDebug;
        default:
            return SentrySeverityError;
    }
    return level;
}

- (NSDictionary *)sanitizeDictionary:(NSDictionary *)dictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for (NSString *key in dictionary.allKeys) {
        [dict setObject:[NSString stringWithFormat:@"%@", [dictionary objectForKey:key]] forKey:key];
    }
    return [NSDictionary dictionaryWithDictionary:dict];
}

#pragma mark RCTExceptionsManagerDelegate

- (void)handleSoftJSExceptionWithMessage:(NSString *)message stack:(NSArray *)stack exceptionId:(NSNumber *)exceptionId {
    NSDictionary *userInfo = @{ NSLocalizedDescriptionKey: message };
    NSError *error = [[NSError alloc] initWithDomain:@"" code:exceptionId.integerValue userInfo:userInfo];
    [[SentryClient shared] reportReactNativeCrashWithError:error stacktrace:stack terminateProgram:NO];
}

- (void)handleFatalJSExceptionWithMessage:(NSString *)message stack:(NSArray *)stack exceptionId:(NSNumber *)exceptionId {
#ifndef DEBUG
    RCTSetFatalHandler(^(NSError *error) {
        [[SentryClient shared] reportReactNativeCrashWithError:error stacktrace:stack terminateProgram:YES];
    });
#else
    RCTSetFatalHandler(^(NSError *error) {
        [[SentryClient shared] reportReactNativeCrashWithError:error stacktrace:stack terminateProgram:NO];
    });
#endif
}

@end
