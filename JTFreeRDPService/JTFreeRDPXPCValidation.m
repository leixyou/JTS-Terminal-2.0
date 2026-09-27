#import "JTFreeRDPXPCValidation.h"
#import "JTFreeRDPTextClipboardBridge.h"

#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

NSString * const JTFreeRDPXPCValidationErrorDomain =
    @"com.lljts.JTSTerminal.FreeRDPXPCValidation";
NSString * const JTFreeRDPXPCValidationErrorCodeKey = @"JTFreeRDPErrorCode";

static const uint64_t JTMaximumFutureRequestMilliseconds = 30 * 1000;
static const NSUInteger JTMaximumKeyChordScanCodes = 32;

static NSError *JTValidationError(NSString *code, NSString *message)
{
    return [NSError errorWithDomain:JTFreeRDPXPCValidationErrorDomain
                               code:1
                           userInfo:@{
                               NSLocalizedDescriptionKey: message,
                               JTFreeRDPXPCValidationErrorCodeKey: code
                           }];
}

static BOOL JTDictionaryHasOnlyKeys(NSDictionary<NSString *, id> *dictionary,
                                    NSSet<NSString *> *allowedKeys,
                                    NSError **error)
{
    if (![dictionary isKindOfClass:NSDictionary.class] || dictionary.count > allowedKeys.count) {
        if (error) {
            *error = JTValidationError(@"XPC_SCHEMA_INVALID",
                                       @"The XPC request dictionary has an invalid shape.");
        }
        return NO;
    }
    for (id key in dictionary) {
        if (![key isKindOfClass:NSString.class] || ![allowedKeys containsObject:key]) {
            if (error) {
                *error = JTValidationError(@"XPC_SCHEMA_INVALID",
                                           @"The XPC request contains an unsupported field.");
            }
            return NO;
        }
    }
    return YES;
}

static BOOL JTStringIsValid(id value,
                            NSUInteger minimumLength,
                            NSUInteger maximumLength)
{
    if (![value isKindOfClass:NSString.class]) {
        return NO;
    }
    NSString *string = value;
    return string.length >= minimumLength &&
        string.length <= maximumLength &&
        [string rangeOfString:@"\0"].location == NSNotFound;
}

static NSString * _Nullable JTCanonicalUUIDString(id value)
{
    if (!JTStringIsValid(value, 36, 36)) {
        return nil;
    }
    NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:value];
    return identifier.UUIDString.lowercaseString;
}

static BOOL JTNumberIsBoolean(id value)
{
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL JTNumberIsIntegerInRange(id value,
                                     int64_t minimum,
                                     uint64_t maximum)
{
    if (![value isKindOfClass:NSNumber.class] || JTNumberIsBoolean(value)) {
        return NO;
    }
    NSNumber *number = value;
    double doubleValue = number.doubleValue;
    if (!isfinite(doubleValue) || floor(doubleValue) != doubleValue ||
        doubleValue < (double)minimum || doubleValue > (double)maximum) {
        return NO;
    }
    return YES;
}

static BOOL JTValueIsBoolean(id value)
{
    return JTNumberIsBoolean(value);
}

static BOOL JTScanCodeArrayIsValid(id value)
{
    if (![value isKindOfClass:NSArray.class]) {
        return NO;
    }
    NSArray *scanCodes = value;
    if (scanCodes.count == 0 || scanCodes.count > JTMaximumKeyChordScanCodes) {
        return NO;
    }
    for (id scanCode in scanCodes) {
        if (!JTNumberIsIntegerInRange(scanCode, 0, UINT16_MAX)) {
            return NO;
        }
    }
    return YES;
}

uint64_t JTFreeRDPCurrentUptimeMilliseconds(void)
{
    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    if (!isfinite(uptime) || uptime <= 0) {
        return 0;
    }
    long double milliseconds = (long double)uptime * 1000.0L;
    return milliseconds >= (long double)UINT64_MAX
        ? UINT64_MAX
        : (uint64_t)milliseconds;
}

BOOL JTFreeRDPIsValidCompanionInstallerRemoteFileName(NSString *value)
{
    static NSString * const prefix = @"JTS-Companion-";
    static NSString * const suffix = @".exe";
    if (![value isKindOfClass:NSString.class] ||
        ![value hasPrefix:prefix] || ![value hasSuffix:suffix] ||
        value.length != prefix.length + 32 + suffix.length) {
        return NO;
    }
    NSString *token = [value substringWithRange:NSMakeRange(prefix.length, 32)];
    NSCharacterSet *invalid = [[NSCharacterSet
        characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [token rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

@interface JTFreeRDPXPCRequestEnvelope ()

@property (nonatomic, copy, readwrite) NSString *requestIdentifier;
@property (nonatomic, readwrite) uint64_t connectionGeneration;
@property (nonatomic, copy, readwrite) NSString *connectionAttemptIdentifier;
@property (nonatomic, readwrite) uint64_t deadlineUptimeMilliseconds;

@end

@implementation JTFreeRDPXPCRequestEnvelope

+ (instancetype)envelopeFromDictionary:(NSDictionary<NSString *, id> *)dictionary
                     expectedGeneration:(uint64_t)expectedGeneration
                    expectedAttemptIdentifier:(NSString *)expectedAttemptIdentifier
                    currentUptimeMillis:(uint64_t)currentUptimeMilliseconds
                                  error:(NSError **)error
{
    static NSSet<NSString *> *allowedKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedKeys = [NSSet setWithArray:@[
            @"requestId", @"connectionGeneration", @"connectionAttemptId",
            @"deadlineUptimeMilliseconds"
        ]];
    });
    NSString *requestIdentifier = JTCanonicalUUIDString(dictionary[@"requestId"]);
    NSString *attemptIdentifier = JTCanonicalUUIDString(dictionary[@"connectionAttemptId"]);
    if (!JTDictionaryHasOnlyKeys(dictionary, allowedKeys, error) ||
        !requestIdentifier ||
        !attemptIdentifier ||
        !JTNumberIsIntegerInRange(dictionary[@"connectionGeneration"], 1, UINT64_MAX) ||
        !JTNumberIsIntegerInRange(dictionary[@"deadlineUptimeMilliseconds"], 1, UINT64_MAX)) {
        if (error && !*error) {
            *error = JTValidationError(@"XPC_REQUEST_ENVELOPE_INVALID",
                                       @"The XPC request envelope is invalid.");
        }
        return nil;
    }

    uint64_t generation = [dictionary[@"connectionGeneration"] unsignedLongLongValue];
    if (generation != expectedGeneration) {
        if (error) {
            *error = JTValidationError(@"RDP_XPC_STALE_GENERATION",
                                       @"The XPC request belongs to a stale connection generation.");
        }
        return nil;
    }
    NSString *expectedAttempt = JTCanonicalUUIDString(expectedAttemptIdentifier);
    if (!expectedAttempt || ![attemptIdentifier isEqualToString:expectedAttempt]) {
        if (error) {
            *error = JTValidationError(@"RDP_XPC_STALE_ATTEMPT",
                                       @"The XPC request belongs to a stale RDP connection attempt.");
        }
        return nil;
    }
    uint64_t deadline = [dictionary[@"deadlineUptimeMilliseconds"] unsignedLongLongValue];
    if (deadline <= currentUptimeMilliseconds) {
        if (error) {
            *error = JTValidationError(@"RDP_XPC_REQUEST_EXPIRED",
                                       @"The XPC request deadline already expired.");
        }
        return nil;
    }
    if (deadline - currentUptimeMilliseconds > JTMaximumFutureRequestMilliseconds) {
        if (error) {
            *error = JTValidationError(@"XPC_REQUEST_ENVELOPE_INVALID",
                                       @"The XPC request deadline is outside the accepted window.");
        }
        return nil;
    }

    JTFreeRDPXPCRequestEnvelope *envelope = [[self alloc] init];
    envelope.requestIdentifier = requestIdentifier;
    envelope.connectionGeneration = generation;
    envelope.connectionAttemptIdentifier = attemptIdentifier;
    envelope.deadlineUptimeMilliseconds = deadline;
    return envelope;
}

@end

NSDictionary<NSString *, id> *JTFreeRDPSanitizedConfiguration(
    NSDictionary<NSString *, id> *configuration,
    NSError **error)
{
    static NSSet<NSString *> *allowedKeys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowedKeys = [NSSet setWithArray:@[
            @"host", @"username", @"password", @"domain", @"sessionId",
            @"port", @"width", @"height", @"pinnedFingerprint",
            @"trustOnceFingerprint", @"clipboardEnabled",
            @"connectionGeneration", @"connectionAttemptId"
        ]];
    });
    NSString *attemptIdentifier = JTCanonicalUUIDString(configuration[@"connectionAttemptId"]);
    if (!JTDictionaryHasOnlyKeys(configuration, allowedKeys, error)) {
        return nil;
    }
    if (!JTStringIsValid(configuration[@"host"], 1, 255) ||
        !JTStringIsValid(configuration[@"username"], 1, 512) ||
        !JTStringIsValid(configuration[@"password"], 1, 4096) ||
        !JTStringIsValid(configuration[@"domain"] ?: @"", 0, 255) ||
        !JTStringIsValid(configuration[@"sessionId"] ?: @"", 0, 128) ||
        !JTNumberIsIntegerInRange(configuration[@"port"], 1, UINT16_MAX) ||
        !JTNumberIsIntegerInRange(configuration[@"width"], 640, 7680) ||
        !JTNumberIsIntegerInRange(configuration[@"height"], 480, 4320) ||
        !JTValueIsBoolean(configuration[@"clipboardEnabled"]) ||
        !JTNumberIsIntegerInRange(configuration[@"connectionGeneration"], 1, UINT64_MAX) ||
        !attemptIdentifier) {
        if (error) {
            *error = JTValidationError(@"INVALID_CONFIGURATION",
                                       @"The RDP connection configuration is invalid.");
        }
        return nil;
    }
    for (NSString *fingerprintKey in @[@"pinnedFingerprint", @"trustOnceFingerprint"]) {
        id value = configuration[fingerprintKey];
        if (value && !JTStringIsValid(value, 0, 128)) {
            if (error) {
                *error = JTValidationError(@"INVALID_CONFIGURATION",
                                           @"The RDP certificate fingerprint is invalid.");
            }
            return nil;
        }
    }

    NSMutableDictionary<NSString *, id> *sanitized = [NSMutableDictionary dictionary];
    for (NSString *key in allowedKeys) {
        id value = configuration[key];
        if (value) {
            sanitized[key] = value;
        }
    }
    sanitized[@"domain"] = configuration[@"domain"] ?: @"";
    sanitized[@"sessionId"] = configuration[@"sessionId"] ?: @"";
    sanitized[@"connectionAttemptId"] = attemptIdentifier;
    return sanitized;
}

BOOL JTFreeRDPValidateClipboardText(NSData * _Nullable text,
                                    NSError **error)
{
    if (!text) {
        return YES;
    }
    if (![text isKindOfClass:NSData.class] ||
        text.length > JTFreeRDPTextClipboardMaximumUTF8Bytes) {
        if (error) {
            *error = JTValidationError(
                @"RDP_CLIPBOARD_TEXT_TOO_LARGE",
                @"Clipboard text must be valid UTF-8 no larger than 4 MiB.");
        }
        return NO;
    }
    NSString *value = [[NSString alloc] initWithData:text
                                             encoding:NSUTF8StringEncoding];
    if (!value || [value rangeOfString:@"\0"].location != NSNotFound) {
        if (error) {
            *error = JTValidationError(
                @"RDP_CLIPBOARD_TEXT_INVALID",
                @"Clipboard text must be valid UTF-8 without embedded null characters.");
        }
        return NO;
    }
    return YES;
}

NSDictionary<NSString *, id> *JTFreeRDPSanitizedInput(
    NSDictionary<NSString *, id> *input,
    NSError **error)
{
    NSString *type = [input[@"type"] isKindOfClass:NSString.class] ? input[@"type"] : nil;
    NSSet<NSString *> *allowedKeys = nil;
    if ([type isEqualToString:@"mouse"]) {
        allowedKeys = [NSSet setWithArray:@[
            @"type", @"action", @"x", @"y", @"expectedFrameId",
            @"expectedStateRevision", @"button", @"deltaX", @"deltaY",
            @"inputOrigin", @"coordinateSpaceWidth", @"coordinateSpaceHeight"
        ]];
    } else if ([type isEqualToString:@"scancode"]) {
        allowedKeys = [NSSet setWithArray:@[
            @"type", @"scancode", @"down", @"repeat", @"expectedStateRevision",
            @"inputOrigin"
        ]];
    } else if ([type isEqualToString:@"keyChord"]) {
        allowedKeys = [NSSet setWithArray:@[
            @"type", @"scancodes", @"expectedStateRevision", @"inputOrigin"
        ]];
    } else if ([type isEqualToString:@"text"]) {
        allowedKeys = [NSSet setWithArray:@[
            @"type", @"text", @"expectedStateRevision", @"inputOrigin"
        ]];
    } else if ([type isEqualToString:@"resize"]) {
        allowedKeys = [NSSet setWithArray:@[@"type", @"width", @"height"]];
    } else {
        if (error) {
            *error = JTValidationError(@"INPUT_TYPE_INVALID",
                                       @"The XPC input type is unsupported.");
        }
        return nil;
    }
    if (!JTDictionaryHasOnlyKeys(input, allowedKeys, error)) {
        return nil;
    }

    if ([type isEqualToString:@"mouse"]) {
        NSString *action = [input[@"action"] isKindOfClass:NSString.class] ? input[@"action"] : nil;
        NSSet<NSString *> *actions = [NSSet setWithArray:@[
            @"move", @"down", @"up", @"click", @"doubleClick", @"scroll"
        ]];
        NSString *button = [input[@"button"] isKindOfClass:NSString.class] ? input[@"button"] : @"left";
        NSSet<NSString *> *buttons = [NSSet setWithArray:@[@"left", @"middle", @"right"]];
        if (![actions containsObject:action ?: @""] ||
            ![buttons containsObject:button] ||
            !JTNumberIsIntegerInRange(input[@"x"], 0, 7679) ||
            !JTNumberIsIntegerInRange(input[@"y"], 0, 4319) ||
            !JTStringIsValid(input[@"expectedFrameId"], 1, 64) ||
            !JTNumberIsIntegerInRange(input[@"expectedStateRevision"], 0, UINT64_MAX)) {
            if (error) {
                *error = JTValidationError(@"INPUT_BOUNDS_INVALID",
                                           @"The XPC mouse input is invalid.");
            }
            return nil;
        }
        for (NSString *deltaKey in @[@"deltaX", @"deltaY"]) {
            if (input[deltaKey] && !JTNumberIsIntegerInRange(input[deltaKey], -32767, 32767)) {
                if (error) {
                    *error = JTValidationError(@"SCROLL_DELTA_INVALID",
                                               @"The XPC scroll delta is invalid.");
                }
                return nil;
            }
        }
        id origin = input[@"inputOrigin"];
        if (origin) {
            if (![origin isKindOfClass:NSString.class] || ![origin isEqualToString:@"localManual"] ||
                !JTNumberIsIntegerInRange(input[@"coordinateSpaceWidth"], 640, 7680) ||
                !JTNumberIsIntegerInRange(input[@"coordinateSpaceHeight"], 480, 4320)) {
                if (error) {
                    *error = JTValidationError(@"INPUT_BOUNDS_INVALID",
                                               @"The local pointer coordinate space is invalid.");
                }
                return nil;
            }
        } else if (input[@"coordinateSpaceWidth"] || input[@"coordinateSpaceHeight"]) {
            if (error) {
                *error = JTValidationError(@"INPUT_BOUNDS_INVALID",
                                           @"Only local pointer input may provide a coordinate space.");
            }
            return nil;
        }
    } else if ([type isEqualToString:@"scancode"]) {
        if (!JTNumberIsIntegerInRange(input[@"scancode"], 0, UINT16_MAX) ||
            !JTValueIsBoolean(input[@"down"]) ||
            !JTValueIsBoolean(input[@"repeat"]) ||
            !JTNumberIsIntegerInRange(input[@"expectedStateRevision"], 0, UINT64_MAX) ||
            (input[@"inputOrigin"] &&
             (![input[@"inputOrigin"] isKindOfClass:NSString.class] ||
              ![input[@"inputOrigin"] isEqualToString:@"localManual"]))) {
            if (error) {
                *error = JTValidationError(@"SCANCODE_INVALID",
                                           @"The XPC scancode input is invalid.");
            }
            return nil;
        }
    } else if ([type isEqualToString:@"keyChord"]) {
        if (!JTScanCodeArrayIsValid(input[@"scancodes"]) ||
            !JTNumberIsIntegerInRange(input[@"expectedStateRevision"], 0, UINT64_MAX) ||
            (input[@"inputOrigin"] &&
             (![input[@"inputOrigin"] isKindOfClass:NSString.class] ||
              ![input[@"inputOrigin"] isEqualToString:@"localManual"]))) {
            if (error) {
                *error = JTValidationError(@"SCANCODE_INVALID",
                                           @"The XPC key chord is invalid.");
            }
            return nil;
        }
    } else if ([type isEqualToString:@"text"]) {
        if (!JTStringIsValid(input[@"text"], 0, 32768) ||
            !JTNumberIsIntegerInRange(input[@"expectedStateRevision"], 0, UINT64_MAX) ||
            (input[@"inputOrigin"] &&
             (![input[@"inputOrigin"] isKindOfClass:NSString.class] ||
              ![input[@"inputOrigin"] isEqualToString:@"localManual"]))) {
            if (error) {
                *error = JTValidationError(@"TEXT_INPUT_INVALID",
                                           @"The XPC text input is invalid.");
            }
            return nil;
        }
    } else if ([type isEqualToString:@"resize"]) {
        if (!JTNumberIsIntegerInRange(input[@"width"], 640, 7680) ||
            !JTNumberIsIntegerInRange(input[@"height"], 480, 4320)) {
            if (error) {
                *error = JTValidationError(@"RESOLUTION_INVALID",
                                           @"The XPC resize input is invalid.");
            }
            return nil;
        }
    }

    NSMutableDictionary<NSString *, id> *sanitized = [NSMutableDictionary dictionary];
    for (NSString *key in allowedKeys) {
        id value = input[key];
        if (value) {
            sanitized[key] = value;
        }
    }
    return sanitized;
}

NSError * _Nullable JTFreeRDPMouseInputValidationError(
    NSDictionary<NSString *, id> *input,
    NSDictionary<NSString *, id> *frame)
{
    NSString *expectedFrameID = [input[@"expectedFrameId"] isKindOfClass:NSString.class]
        ? input[@"expectedFrameId"] : nil;
    NSNumber *expectedRevision = [input[@"expectedStateRevision"] isKindOfClass:NSNumber.class]
        ? input[@"expectedStateRevision"] : nil;
    NSString *currentFrameID = [frame[@"frameId"] isKindOfClass:NSString.class]
        ? frame[@"frameId"] : nil;
    NSNumber *currentRevision = [frame[@"stateRevision"] isKindOfClass:NSNumber.class]
        ? frame[@"stateRevision"] : nil;
    if (expectedFrameID.length == 0 ||
        ![expectedFrameID isEqualToString:currentFrameID ?: @""] ||
        !expectedRevision ||
        !currentRevision ||
        ![expectedRevision isEqualToNumber:currentRevision]) {
        return JTValidationError(
            @"STATE_CONFLICT",
            @"The referenced desktop frame is stale. Observe a new frame before sending coordinates.");
    }

    NSString *action = [input[@"action"] isKindOfClass:NSString.class]
        ? input[@"action"] : nil;
    NSSet<NSString *> *allowedActions = [NSSet setWithArray:@[
        @"move", @"down", @"up", @"click", @"doubleClick", @"scroll"
    ]];
    NSString *button = [input[@"button"] isKindOfClass:NSString.class]
        ? input[@"button"] : @"left";
    NSSet<NSString *> *allowedButtons = [NSSet setWithArray:@[
        @"left", @"right", @"middle"
    ]];
    NSNumber *xValue = [input[@"x"] isKindOfClass:NSNumber.class] ? input[@"x"] : nil;
    NSNumber *yValue = [input[@"y"] isKindOfClass:NSNumber.class] ? input[@"y"] : nil;
    NSNumber *widthValue = [frame[@"width"] isKindOfClass:NSNumber.class] ? frame[@"width"] : nil;
    NSNumber *heightValue = [frame[@"height"] isKindOfClass:NSNumber.class] ? frame[@"height"] : nil;
    NSInteger x = xValue.integerValue;
    NSInteger y = yValue.integerValue;
    NSInteger width = widthValue.integerValue;
    NSInteger height = heightValue.integerValue;
    BOOL requiresButton = [action isEqualToString:@"down"] ||
        [action isEqualToString:@"up"] ||
        [action isEqualToString:@"click"] ||
        [action isEqualToString:@"doubleClick"];
    if (!action || ![allowedActions containsObject:action] ||
        !xValue || !yValue || !widthValue || !heightValue ||
        (requiresButton && ![allowedButtons containsObject:button]) ||
        x < 0 || y < 0 || width <= 0 || height <= 0 ||
        x >= width || y >= height) {
        return JTValidationError(
            @"INPUT_BOUNDS_INVALID",
            @"Mouse input must use a supported action and coordinates inside the remote framebuffer.");
    }
    if ([action isEqualToString:@"scroll"]) {
        NSNumber *deltaValue = [input[@"deltaY"] isKindOfClass:NSNumber.class]
            ? input[@"deltaY"] : nil;
        NSInteger delta = deltaValue.integerValue;
        if (!deltaValue || delta == 0 || delta < -32767 || delta > 32767) {
            return JTValidationError(
                @"SCROLL_DELTA_INVALID",
                @"Scroll input requires a nonzero deltaY between -32,767 and 32,767.");
        }
    }
    return nil;
}

NSDictionary<NSString *, id> * _Nullable JTFreeRDPInputCommandForExecution(
    NSDictionary<NSString *, id> *input,
    NSDictionary<NSString *, id> *frame,
    NSString *currentConnectionAttemptIdentifier,
    NSError **error)
{
    NSString *type = [input[@"type"] isKindOfClass:NSString.class] ? input[@"type"] : nil;
    NSMutableDictionary<NSString *, id> *command = [input mutableCopy];
    BOOL requiresDesktopState = [type isEqualToString:@"mouse"] ||
        [type isEqualToString:@"scancode"] ||
        [type isEqualToString:@"keyChord"] ||
        [type isEqualToString:@"text"];
    NSError *attemptError = JTFreeRDPConnectionAttemptValidationError(
        command,
        currentConnectionAttemptIdentifier,
        requiresDesktopState ? frame : nil);
    if (attemptError) {
        if (error) {
            *error = attemptError;
        }
        return nil;
    }
    if ([type isEqualToString:@"mouse"]) {
        BOOL isLocalManualInput = [input[@"inputOrigin"] isKindOfClass:NSString.class] &&
            [input[@"inputOrigin"] isEqualToString:@"localManual"];
        if (isLocalManualInput) {
            NSNumber *coordinateSpaceWidth =
                [input[@"coordinateSpaceWidth"] isKindOfClass:NSNumber.class]
                    ? input[@"coordinateSpaceWidth"] : nil;
            NSNumber *coordinateSpaceHeight =
                [input[@"coordinateSpaceHeight"] isKindOfClass:NSNumber.class]
                    ? input[@"coordinateSpaceHeight"] : nil;
            NSNumber *frameWidth = [frame[@"width"] isKindOfClass:NSNumber.class]
                ? frame[@"width"] : nil;
            NSNumber *frameHeight = [frame[@"height"] isKindOfClass:NSNumber.class]
                ? frame[@"height"] : nil;
            NSString *frameID = [frame[@"frameId"] isKindOfClass:NSString.class]
                ? frame[@"frameId"] : nil;
            NSNumber *stateRevision = [frame[@"stateRevision"] isKindOfClass:NSNumber.class]
                ? frame[@"stateRevision"] : nil;
            BOOL coordinateSpaceMatches = coordinateSpaceWidth && coordinateSpaceHeight &&
                [coordinateSpaceWidth isEqualToNumber:frameWidth] &&
                [coordinateSpaceHeight isEqualToNumber:frameHeight];
            if (!coordinateSpaceMatches || frameID.length == 0 || !stateRevision) {
                if (error) {
                    *error = JTValidationError(
                        @"STATE_CONFLICT",
                        @"The remote desktop resized before the local pointer event could execute.");
                }
                return nil;
            }
            command[@"expectedFrameId"] = frameID;
            command[@"expectedStateRevision"] = stateRevision;
        }
        NSError *validationError = JTFreeRDPMouseInputValidationError(command, frame);
        if (validationError) {
            if (error) {
                *error = validationError;
            }
            return nil;
        }
        return command;
    }

    if ([type isEqualToString:@"scancode"] ||
        [type isEqualToString:@"keyChord"] ||
        [type isEqualToString:@"text"]) {
        BOOL isLocalManualInput = [input[@"inputOrigin"] isKindOfClass:NSString.class] &&
            [input[@"inputOrigin"] isEqualToString:@"localManual"];
        NSNumber *expectedRevision =
            [input[@"expectedStateRevision"] isKindOfClass:NSNumber.class]
                ? input[@"expectedStateRevision"] : nil;
        NSNumber *currentRevision =
            [frame[@"stateRevision"] isKindOfClass:NSNumber.class]
                ? frame[@"stateRevision"] : nil;
        if (isLocalManualInput && currentRevision) {
            command[@"expectedStateRevision"] = currentRevision;
            return command;
        }
        if (!expectedRevision || !currentRevision ||
            ![expectedRevision isEqualToNumber:currentRevision]) {
            if (error) {
                *error = JTValidationError(
                    @"STATE_CONFLICT",
                    @"The remote desktop state changed before the input command could execute.");
            }
            return nil;
        }
        return command;
    }

    if ([type isEqualToString:@"resize"]) {
        return command;
    }
    if (error) {
        *error = JTValidationError(
            @"INPUT_TYPE_INVALID",
            @"The queued input command type is unsupported.");
    }
    return nil;
}

NSError * _Nullable JTFreeRDPConnectionAttemptValidationError(
    NSDictionary<NSString *, id> *command,
    NSString *currentConnectionAttemptIdentifier,
    NSDictionary<NSString *, id> * _Nullable frame)
{
    NSString *expectedAttempt = JTCanonicalUUIDString(
        command[@"expectedConnectionAttemptId"]);
    NSString *currentAttempt = JTCanonicalUUIDString(
        currentConnectionAttemptIdentifier);
    NSString *frameAttempt = frame
        ? JTCanonicalUUIDString(frame[@"connectionAttemptId"])
        : nil;
    if (!expectedAttempt || !currentAttempt ||
        ![expectedAttempt isEqualToString:currentAttempt] ||
        (frame && (!frameAttempt || ![frameAttempt isEqualToString:currentAttempt]))) {
        return JTValidationError(
            @"RDP_XPC_STALE_ATTEMPT",
            @"The queued mutation belongs to a stale RDP connection attempt.");
    }
    return nil;
}

NSError * _Nullable JTFreeRDPDVCGenerationValidationError(
    NSDictionary<NSString *, id> *command,
    uint64_t currentDVCGeneration)
{
    id rawExpectedGeneration = command[@"expectedDVCGeneration"];
    if (!JTNumberIsIntegerInRange(rawExpectedGeneration, 1, UINT64_MAX)) {
        return JTValidationError(
            @"DVC_CHANNEL_GENERATION_INVALID",
            @"The Companion request does not contain a valid helper channel generation.");
    }
    uint64_t expectedGeneration = [rawExpectedGeneration unsignedLongLongValue];
    if (currentDVCGeneration == 0 || expectedGeneration != currentDVCGeneration) {
        return JTValidationError(
            @"COMPANION_CHANNEL_CHANGED",
            @"The Companion dynamic virtual channel changed before the request could execute.");
    }
    return nil;
}

NSDictionary<NSString *, id> *JTFreeRDPSanitizedCancellation(
    NSDictionary<NSString *, id> *cancellation,
    uint64_t expectedGeneration,
    NSString *expectedAttemptIdentifier,
    NSError **error)
{
    NSSet<NSString *> *allowedKeys = [NSSet setWithArray:@[
        @"requestId", @"connectionGeneration", @"connectionAttemptId"
    ]];
    NSString *requestIdentifier = JTCanonicalUUIDString(cancellation[@"requestId"]);
    NSString *attemptIdentifier = JTCanonicalUUIDString(cancellation[@"connectionAttemptId"]);
    if (!JTDictionaryHasOnlyKeys(cancellation, allowedKeys, error) ||
        !requestIdentifier ||
        !attemptIdentifier ||
        !JTNumberIsIntegerInRange(cancellation[@"connectionGeneration"], 1, UINT64_MAX)) {
        if (error && !*error) {
            *error = JTValidationError(@"XPC_REQUEST_ENVELOPE_INVALID",
                                       @"The XPC cancellation request is invalid.");
        }
        return nil;
    }
    if ([cancellation[@"connectionGeneration"] unsignedLongLongValue] != expectedGeneration) {
        if (error) {
            *error = JTValidationError(@"RDP_XPC_STALE_GENERATION",
                                       @"The XPC cancellation belongs to a stale connection generation.");
        }
        return nil;
    }
    NSString *expectedAttempt = JTCanonicalUUIDString(expectedAttemptIdentifier);
    if (!expectedAttempt || ![attemptIdentifier isEqualToString:expectedAttempt]) {
        if (error) {
            *error = JTValidationError(@"RDP_XPC_STALE_ATTEMPT",
                                       @"The XPC cancellation belongs to a stale RDP connection attempt.");
        }
        return nil;
    }
    return @{
        @"requestId": requestIdentifier,
        @"connectionGeneration": cancellation[@"connectionGeneration"],
        @"connectionAttemptId": attemptIdentifier
    };
}
