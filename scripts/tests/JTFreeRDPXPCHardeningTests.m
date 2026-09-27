#ifndef __COREFOUNDATION_CFPLUGINCOM__
#define __COREFOUNDATION_CFPLUGINCOM__ 1
#endif
#ifndef IUNKNOWN_C_GUTS
#define IUNKNOWN_C_GUTS \
    void *_reserved;    \
    void *QueryInterface; \
    void *AddRef;       \
    void *Release
#endif

#import <Foundation/Foundation.h>
#import <stdatomic.h>

#import "JTFreeRDPCommandQueue.h"
#import "JTFreeRDPDeferredReleasePool.h"
#import "JTFreeRDPTextClipboardBridge.h"
#import "JTFreeRDPXPCValidation.h"

#include <freerdp/channels/cliprdr.h>
#include <freerdp/client/cliprdr.h>
#include <winpr/clipboard.h>
#include <winpr/error.h>
#include <string.h>

static NSUInteger JTAssertions = 0;

static NSUInteger JTClipboardCapabilitiesCount = 0;
static UINT32 JTClipboardGeneralCapabilityFlags = 0;
static NSUInteger JTClipboardFormatListCount = 0;
static NSUInteger JTClipboardFormatListResponseCount = 0;
static NSUInteger JTClipboardDataRequestCount = 0;
static NSUInteger JTClipboardDataResponseCount = 0;
static NSUInteger JTClipboardFileContentsResponseCount = 0;
static UINT32 JTClipboardRequestedFormat = 0;
static UINT16 JTClipboardResponseFlags = 0;
static UINT16 JTClipboardFileContentsResponseFlags = 0;
static UINT32 JTClipboardFileContentsResponseStreamID = 0;
static NSArray<NSNumber *> *JTClipboardFormats;
static NSArray<NSString *> *JTClipboardFormatNames;
static NSData *JTClipboardResponseData;
static NSData *JTClipboardFileContentsResponseData;
static NSMutableArray<NSArray<NSNumber *> *> *JTClipboardFormatAnnouncements;
static NSMutableArray<NSNumber *> *JTClipboardRequestedFormats;

static UINT JTTestClipboardClientCapabilities(
    CliprdrClientContext *context,
    const CLIPRDR_CAPABILITIES *capabilities)
{
    if (!context || !capabilities || capabilities->cCapabilitiesSets != 1) {
        return ERROR_INVALID_PARAMETER;
    }
    const CLIPRDR_GENERAL_CAPABILITY_SET *general =
        (const CLIPRDR_GENERAL_CAPABILITY_SET *)capabilities->capabilitySets;
    if (!general ||
        general->capabilitySetType != CB_CAPSTYPE_GENERAL ||
        general->capabilitySetLength != CB_CAPSTYPE_GENERAL_LEN) {
        return ERROR_INVALID_PARAMETER;
    }
    JTClipboardCapabilitiesCount += 1;
    JTClipboardGeneralCapabilityFlags = general->generalFlags;
    return CHANNEL_RC_OK;
}

static UINT JTTestClipboardClientFormatList(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_LIST *formatList)
{
    if (!context || !formatList) {
        return ERROR_INVALID_PARAMETER;
    }
    JTClipboardFormatListCount += 1;
    NSMutableArray<NSNumber *> *formats =
        [NSMutableArray arrayWithCapacity:formatList->numFormats];
    NSMutableArray<NSString *> *formatNames =
        [NSMutableArray arrayWithCapacity:formatList->numFormats];
    for (UINT32 index = 0; index < formatList->numFormats; index++) {
        [formats addObject:@(formatList->formats[index].formatId)];
        const char *formatName = formatList->formats[index].formatName;
        [formatNames addObject:formatName
            ? [NSString stringWithUTF8String:formatName]
            : @""];
    }
    JTClipboardFormats = formats;
    JTClipboardFormatNames = formatNames;
    [JTClipboardFormatAnnouncements addObject:[formats copy]];
    return CHANNEL_RC_OK;
}

static UINT JTTestClipboardClientFormatListResponse(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_LIST_RESPONSE *response)
{
    if (!context || !response ||
        response->common.msgFlags != CB_RESPONSE_OK) {
        return ERROR_INVALID_PARAMETER;
    }
    JTClipboardFormatListResponseCount += 1;
    return CHANNEL_RC_OK;
}

static UINT JTTestClipboardClientFormatDataRequest(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
    if (!context || !request) {
        return ERROR_INVALID_PARAMETER;
    }
    JTClipboardDataRequestCount += 1;
    JTClipboardRequestedFormat = request->requestedFormatId;
    [JTClipboardRequestedFormats addObject:@(request->requestedFormatId)];
    return CHANNEL_RC_OK;
}

static UINT JTTestClipboardClientFormatDataResponse(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    if (!context || !response) {
        return ERROR_INVALID_PARAMETER;
    }
    JTClipboardDataResponseCount += 1;
    JTClipboardResponseFlags = response->common.msgFlags;
    JTClipboardResponseData = response->requestedFormatData &&
        response->common.dataLen > 0
        ? [NSData dataWithBytes:response->requestedFormatData
                        length:response->common.dataLen]
        : nil;
    return CHANNEL_RC_OK;
}

static UINT JTTestClipboardClientFileContentsResponse(
    CliprdrClientContext *context,
    const CLIPRDR_FILE_CONTENTS_RESPONSE *response)
{
    if (!context || !response) {
        return ERROR_INVALID_PARAMETER;
    }
    JTClipboardFileContentsResponseCount += 1;
    JTClipboardFileContentsResponseFlags = response->common.msgFlags;
    JTClipboardFileContentsResponseStreamID = response->streamId;
    JTClipboardFileContentsResponseData =
        response->requestedData && response->cbRequested > 0
            ? [NSData dataWithBytes:response->requestedData
                            length:response->cbRequested]
            : nil;
    return CHANNEL_RC_OK;
}

@interface JTTestClipboardDelegate :
    NSObject <JTFreeRDPTextClipboardBridgeDelegate>

@property (nonatomic, copy, nullable) NSData *receivedText;
@property (nonatomic, strong) NSMutableArray<NSData *> *receivedTexts;
@property (nonatomic, strong) NSMutableArray<NSString *> *acknowledgedIdentifiers;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *acknowledgementResults;
@property (nonatomic, strong)
    NSMutableArray<NSDictionary<NSString *, id> *> *fileTransferUpdates;
@property (nonatomic, strong)
    NSMutableArray<NSNumber *> *fileTransferReadinessUpdates;

@end

@implementation JTTestClipboardDelegate

- (instancetype)init
{
    self = [super init];
    if (self) {
        _receivedTexts = [NSMutableArray array];
        _acknowledgedIdentifiers = [NSMutableArray array];
        _acknowledgementResults = [NSMutableArray array];
        _fileTransferUpdates = [NSMutableArray array];
        _fileTransferReadinessUpdates = [NSMutableArray array];
    }
    return self;
}

- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
         didReceiveUTF8Text:(NSData *)text
{
    (void)bridge;
    self.receivedText = text;
    [self.receivedTexts addObject:[text copy]];
}

- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
didAcknowledgeLocalFormatList:(NSString *)acknowledgementIdentifier
                    accepted:(BOOL)accepted
{
    (void)bridge;
    [self.acknowledgedIdentifiers addObject:acknowledgementIdentifier];
    [self.acknowledgementResults addObject:@(accepted)];
}

- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
      didUpdateFileTransfer:(NSDictionary<NSString *, id> *)metadata
{
    (void)bridge;
    [self.fileTransferUpdates addObject:[metadata copy]];
}

- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
didUpdateFileTransferReadiness:(BOOL)ready
{
    (void)bridge;
    [self.fileTransferReadinessUpdates addObject:@(ready)];
}

@end

static UINT JTTestAcknowledgeClipboardFormatList(
    CliprdrClientContext *context,
    UINT16 flags)
{
    CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = flags;
    return context->ServerFormatListResponse(context, &response);
}

static UINT JTTestSendServerClipboardCapabilities(
    CliprdrClientContext *context,
    UINT32 generalFlags)
{
    if (!context || !context->ServerCapabilities) {
        return ERROR_INVALID_PARAMETER;
    }
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = generalFlags;

    CLIPRDR_CAPABILITIES capabilities = { 0 };
    capabilities.common.msgType = CB_CLIP_CAPS;
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets =
        (CLIPRDR_CAPABILITY_SET *)&general;
    return context->ServerCapabilities(context, &capabilities);
}

static NSData *JTTestUnicodeClipboardPayload(NSString *text)
{
    NSMutableData *payload = [[text
        dataUsingEncoding:NSUTF16LittleEndianStringEncoding] mutableCopy];
    const uint8_t terminator[2] = { 0, 0 };
    [payload appendBytes:terminator length:sizeof(terminator)];
    return payload;
}

static NSData *JTTestLegacyClipboardPayload(NSString *text)
{
    NSMutableData *payload = [[text
        dataUsingEncoding:NSWindowsCP1252StringEncoding] mutableCopy];
    const uint8_t terminator = 0;
    [payload appendBytes:&terminator length:sizeof(terminator)];
    return payload;
}

static uint16_t JTTestReadUInt16LittleEndian(NSData *data, NSUInteger offset)
{
    const uint8_t *bytes = data.bytes;
    return (uint16_t)bytes[offset] |
        ((uint16_t)bytes[offset + 1] << 8);
}

static uint32_t JTTestReadUInt32LittleEndian(NSData *data, NSUInteger offset)
{
    const uint8_t *bytes = data.bytes;
    return (uint32_t)bytes[offset] |
        ((uint32_t)bytes[offset + 1] << 8) |
        ((uint32_t)bytes[offset + 2] << 16) |
        ((uint32_t)bytes[offset + 3] << 24);
}

static uint64_t JTTestReadUInt64LittleEndian(NSData *data, NSUInteger offset)
{
    return (uint64_t)JTTestReadUInt32LittleEndian(data, offset) |
        ((uint64_t)JTTestReadUInt32LittleEndian(data, offset + 4) << 32);
}

static NSString *JTTestReadUTF16LECString(NSData *data, NSUInteger offset)
{
    NSUInteger length = 0;
    while (offset + length + 1 < data.length &&
           JTTestReadUInt16LittleEndian(data, offset + length) != 0) {
        length += sizeof(uint16_t);
    }
    return [[NSString alloc]
        initWithData:[data subdataWithRange:NSMakeRange(offset, length)]
            encoding:NSUTF16LittleEndianStringEncoding];
}

#define JTAssert(condition, message) do { \
    JTAssertions += 1; \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: %s\n", (message)); \
        return 1; \
    } \
} while (0)

static NSString *JTConnectionAttemptA(void)
{
    return @"11111111-1111-4111-8111-111111111111";
}

static NSString *JTConnectionAttemptB(void)
{
    return @"22222222-2222-4222-8222-222222222222";
}

static NSDictionary<NSString *, id> *JTValidConfiguration(void)
{
    return @{
        @"host": @"192.0.2.10",
        @"username": @"rdp-user",
        @"password": @"test-only-password",
        @"domain": @"",
        @"sessionId": NSUUID.UUID.UUIDString,
        @"port": @3389,
        @"width": @1512,
        @"height": @895,
        @"clipboardEnabled": @YES,
        @"connectionGeneration": @7,
        @"connectionAttemptId": JTConnectionAttemptA(),
    };
}

static NSDictionary<NSString *, id> *JTValidInput(void)
{
    return @{
        @"type": @"scancode",
        @"scancode": @30,
        @"down": @YES,
        @"repeat": @NO,
        @"expectedStateRevision": @9,
    };
}

static NSDictionary<NSString *, id> *JTFrame(
    NSString *frameID,
    uint64_t revision)
{
    return @{
        @"frameId": frameID,
        @"stateRevision": @(revision),
        @"connectionAttemptId": JTConnectionAttemptA(),
        @"width": @1920,
        @"height": @1080,
    };
}

static NSDictionary<NSString *, id> *JTMouseInput(
    NSString *frameID,
    uint64_t revision,
    NSString *action)
{
    return @{
        @"type": @"mouse",
        @"action": action,
        @"x": @960,
        @"y": @540,
        @"expectedFrameId": frameID,
        @"expectedStateRevision": @(revision),
        @"button": @"left",
        @"deltaX": @0,
        @"deltaY": @0,
    };
}

static NSDictionary<NSString *, id> *JTEnvelope(uint64_t deadline)
{
    return @{
        @"requestId": NSUUID.UUID.UUIDString,
        @"connectionGeneration": @7,
        @"connectionAttemptId": JTConnectionAttemptA(),
        @"deadlineUptimeMilliseconds": @(deadline),
    };
}

static int JTTestSchemaValidation(void)
{
    JTAssert(JTFreeRDPIsValidCompanionInstallerRemoteFileName(
                 @"JTS-Companion-0123456789abcdef0123456789abcdef.exe"),
             "helper-generated Companion installer basename was rejected");
    JTAssert(!JTFreeRDPIsValidCompanionInstallerRemoteFileName(
                 @"JTS-Windows-Companion-Setup.exe"),
             "stable Companion installer basename was accepted");
    JTAssert(!JTFreeRDPIsValidCompanionInstallerRemoteFileName(
                 @"JTS-Companion-0123456789ABCDEF0123456789ABCDEF.exe"),
             "mixed-case Companion installer token was accepted");
    JTAssert(!JTFreeRDPIsValidCompanionInstallerRemoteFileName(
                 @"JTS-Companion-../../Setup.exe"),
             "path-like Companion installer basename was accepted");

    NSError *error = nil;
    NSDictionary *configuration = JTFreeRDPSanitizedConfiguration(JTValidConfiguration(), &error);
    JTAssert(configuration != nil && error == nil, "valid RDP configuration was rejected");

    NSMutableDictionary *unknownConfiguration = [JTValidConfiguration() mutableCopy];
    unknownConfiguration[@"ignoreCertificate"] = @YES;
    error = nil;
    JTAssert(JTFreeRDPSanitizedConfiguration(unknownConfiguration, &error) == nil,
             "unknown configuration key was accepted");
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"XPC_SCHEMA_INVALID"], "unknown-key error code is unstable");

    NSMutableDictionary *nulConfiguration = [JTValidConfiguration() mutableCopy];
    nulConfiguration[@"password"] = @"truncated\0secret";
    error = nil;
    JTAssert(JTFreeRDPSanitizedConfiguration(nulConfiguration, &error) == nil,
             "NUL-containing credential was accepted");

    NSMutableDictionary *missingAttemptConfiguration = [JTValidConfiguration() mutableCopy];
    [missingAttemptConfiguration removeObjectForKey:@"connectionAttemptId"];
    error = nil;
    JTAssert(JTFreeRDPSanitizedConfiguration(missingAttemptConfiguration, &error) == nil,
             "configuration without an RDP attempt identifier was accepted");

    NSMutableDictionary *uppercaseAttemptConfiguration = [JTValidConfiguration() mutableCopy];
    uppercaseAttemptConfiguration[@"connectionAttemptId"] =
        JTConnectionAttemptA().uppercaseString;
    error = nil;
    NSDictionary *normalizedConfiguration = JTFreeRDPSanitizedConfiguration(
        uppercaseAttemptConfiguration,
        &error);
    JTAssert([normalizedConfiguration[@"connectionAttemptId"]
        isEqualToString:JTConnectionAttemptA()],
        "configuration attempt identifier was not canonicalized");

    NSMutableDictionary *wrongClipboardBoolean = [JTValidConfiguration() mutableCopy];
    wrongClipboardBoolean[@"clipboardEnabled"] = @1;
    error = nil;
    JTAssert(JTFreeRDPSanitizedConfiguration(wrongClipboardBoolean, &error) == nil,
             "integer masquerading as clipboardEnabled was accepted");

    NSData *clipboardText = [@"clipboard text" dataUsingEncoding:NSUTF8StringEncoding];
    error = nil;
    JTAssert(JTFreeRDPValidateClipboardText(clipboardText, &error),
             "valid clipboard UTF-8 was rejected");
    error = nil;
    JTAssert(JTFreeRDPValidateClipboardText(nil, &error),
             "nil clipboard update was rejected");
    error = nil;
    JTAssert(!JTFreeRDPValidateClipboardText(
        [NSData dataWithBytes:"\xC3\x28" length:2],
        &error), "malformed clipboard UTF-8 was accepted");
    error = nil;
    JTAssert(!JTFreeRDPValidateClipboardText(
        [NSMutableData dataWithLength:JTFreeRDPTextClipboardMaximumUTF8Bytes + 1],
        &error), "oversized clipboard UTF-8 was accepted");

    error = nil;
    JTAssert(JTFreeRDPSanitizedInput(JTValidInput(), &error) != nil,
             "valid scancode input was rejected");
    NSMutableDictionary *wrongBoolean = [JTValidInput() mutableCopy];
    wrongBoolean[@"down"] = @1;
    error = nil;
    JTAssert(JTFreeRDPSanitizedInput(wrongBoolean, &error) == nil,
             "integer masquerading as a boolean was accepted");
    NSMutableDictionary *extraInput = [JTValidInput() mutableCopy];
    extraInput[@"shell"] = @"whoami";
    error = nil;
    JTAssert(JTFreeRDPSanitizedInput(extraInput, &error) == nil,
             "unknown input field was accepted");
    NSMutableDictionary *callerBoundInput = [JTValidInput() mutableCopy];
    callerBoundInput[@"expectedConnectionAttemptId"] = JTConnectionAttemptA();
    error = nil;
    JTAssert(JTFreeRDPSanitizedInput(callerBoundInput, &error) == nil,
             "raw input was allowed to self-assert a helper attempt identifier");

    NSString *frameID = NSUUID.UUID.UUIDString.lowercaseString;
    error = nil;
    JTAssert(JTFreeRDPSanitizedInput(
        JTMouseInput(frameID, 9, @"click"),
        &error) != nil, "atomic click input was rejected");
    error = nil;
    JTAssert(JTFreeRDPSanitizedInput(
        JTMouseInput(frameID, 9, @"doubleClick"),
        &error) != nil, "atomic double-click input was rejected");
    error = nil;
    JTAssert(JTFreeRDPSanitizedInput(@{
        @"type": @"keyChord",
        @"scancodes": @[@29, @56, @83],
        @"expectedStateRevision": @9,
    }, &error) != nil, "atomic key chord input was rejected");
    error = nil;
    JTAssert(JTFreeRDPSanitizedInput(@{
        @"type": @"keyChord",
        @"scancodes": @[],
        @"expectedStateRevision": @9,
    }, &error) == nil, "empty key chord was accepted");
    error = nil;
    JTAssert(JTFreeRDPSanitizedInput(@{
        @"type": @"keyChord",
        @"scancodes": @[@29, @YES],
        @"expectedStateRevision": @9,
    }, &error) == nil, "boolean key chord scancode was accepted");

    error = nil;
    JTFreeRDPXPCRequestEnvelope *envelope =
        [JTFreeRDPXPCRequestEnvelope envelopeFromDictionary:JTEnvelope(11000)
                                         expectedGeneration:7
                                expectedAttemptIdentifier:JTConnectionAttemptA()
                                        currentUptimeMillis:10000
                                                      error:&error];
    JTAssert(envelope != nil && envelope.deadlineUptimeMilliseconds == 11000 &&
             [envelope.connectionAttemptIdentifier isEqualToString:JTConnectionAttemptA()],
             "valid request envelope was rejected");
    error = nil;
    JTAssert([JTFreeRDPXPCRequestEnvelope envelopeFromDictionary:JTEnvelope(10000)
                                              expectedGeneration:7
                                     expectedAttemptIdentifier:JTConnectionAttemptA()
                                             currentUptimeMillis:10000
                                                           error:&error] == nil,
             "expired request envelope was accepted");
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"RDP_XPC_REQUEST_EXPIRED"], "expiry error code is unstable");
    error = nil;
    JTAssert([JTFreeRDPXPCRequestEnvelope envelopeFromDictionary:JTEnvelope(11000)
                                              expectedGeneration:8
                                     expectedAttemptIdentifier:JTConnectionAttemptA()
                                             currentUptimeMillis:10000
                                                           error:&error] == nil,
             "stale connection generation was accepted");

    error = nil;
    JTAssert([JTFreeRDPXPCRequestEnvelope envelopeFromDictionary:JTEnvelope(11000)
                                              expectedGeneration:7
                                     expectedAttemptIdentifier:JTConnectionAttemptB()
                                             currentUptimeMillis:10000
                                                           error:&error] == nil,
             "stale RDP connection attempt was accepted");
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"RDP_XPC_STALE_ATTEMPT"],
        "stale attempt error code is unstable");

    NSDictionary *cancellation = @{
        @"requestId": NSUUID.UUID.UUIDString,
        @"connectionGeneration": @7,
        @"connectionAttemptId": JTConnectionAttemptA(),
    };
    error = nil;
    JTAssert(JTFreeRDPSanitizedCancellation(
        cancellation,
        7,
        JTConnectionAttemptA(),
        &error) != nil,
        "valid attempt-bound cancellation was rejected");
    error = nil;
    JTAssert(JTFreeRDPSanitizedCancellation(
        cancellation,
        7,
        JTConnectionAttemptB(),
        &error) == nil,
        "stale-attempt cancellation was accepted");
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"RDP_XPC_STALE_ATTEMPT"],
        "stale cancellation attempt error code is unstable");
    return 0;
}

static int JTTestTextClipboardBridge(void)
{
    JTClipboardCapabilitiesCount = 0;
    JTClipboardGeneralCapabilityFlags = 0;
    JTClipboardFormatListCount = 0;
    JTClipboardFormatListResponseCount = 0;
    JTClipboardDataRequestCount = 0;
    JTClipboardDataResponseCount = 0;
    JTClipboardFileContentsResponseCount = 0;
    JTClipboardRequestedFormat = 0;
    JTClipboardResponseFlags = 0;
    JTClipboardFileContentsResponseFlags = 0;
    JTClipboardFileContentsResponseStreamID = 0;
    JTClipboardFormats = nil;
    JTClipboardFormatNames = nil;
    JTClipboardResponseData = nil;
    JTClipboardFileContentsResponseData = nil;
    JTClipboardFormatAnnouncements = [NSMutableArray array];
    JTClipboardRequestedFormats = [NSMutableArray array];

    JTFreeRDPTextClipboardBridge *disabled =
        [[JTFreeRDPTextClipboardBridge alloc] initWithEnabled:NO];
    NSError *error = nil;
    JTAssert(![disabled updateLocalUTF8Text:
        [@"blocked" dataUsingEncoding:NSUTF8StringEncoding] error:&error],
        "disabled clipboard bridge accepted local text");

    CliprdrClientContext context = { 0 };
    context.ClientCapabilities = JTTestClipboardClientCapabilities;
    context.ClientFormatList = JTTestClipboardClientFormatList;
    context.ClientFormatListResponse = JTTestClipboardClientFormatListResponse;
    context.ClientFormatDataRequest = JTTestClipboardClientFormatDataRequest;
    context.ClientFormatDataResponse = JTTestClipboardClientFormatDataResponse;
    context.ClientFileContentsResponse =
        JTTestClipboardClientFileContentsResponse;

    JTFreeRDPTextClipboardBridge *bridge =
        [[JTFreeRDPTextClipboardBridge alloc] initWithEnabled:YES];
    JTTestClipboardDelegate *delegate = [[JTTestClipboardDelegate alloc] init];
    bridge.delegate = delegate;
    JTAssert([bridge attachContext:&context],
             "enabled clipboard bridge did not attach its cliprdr context");

    NSData *localText = [@"Mac\n中文" dataUsingEncoding:NSUTF8StringEncoding];
    error = nil;
    JTAssert([bridge updateLocalUTF8Text:localText error:&error] && error == nil,
             "valid local clipboard text was rejected");
    JTAssert(JTClipboardFormatListCount == 0,
             "clipboard formats were announced before monitor-ready");

    CLIPRDR_MONITOR_READY monitorReady = { 0 };
    monitorReady.common.msgType = CB_MONITOR_READY;
    JTAssert(context.MonitorReady(&context, &monitorReady) == CHANNEL_RC_OK,
             "clipboard monitor-ready callback failed");
    JTAssert(JTClipboardCapabilitiesCount == 1,
             "clipboard capabilities were not sent exactly once");
    JTAssert((JTClipboardGeneralCapabilityFlags &
                 CB_STREAM_FILECLIP_ENABLED) != 0 &&
             (JTClipboardGeneralCapabilityFlags &
                 CB_FILECLIP_NO_FILE_PATHS) != 0,
             "clipboard bridge did not negotiate path-free streamed file transfer");
    JTAssert((JTClipboardGeneralCapabilityFlags &
                 CB_CAN_LOCK_CLIPDATA) == 0 &&
             (JTClipboardGeneralCapabilityFlags &
                 CB_HUGE_FILE_SUPPORT_ENABLED) == 0,
             "clipboard bridge negotiated unsupported lock or huge-file capabilities");
    JTAssert((JTClipboardFormatListCount == 1 &&
             [JTClipboardFormats isEqual:@[@(CF_UNICODETEXT), @(CF_TEXT)]]),
             "clipboard bridge advertised formats beyond plain text");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "initial clipboard format list acknowledgement failed");
    JTAssert(delegate.acknowledgedIdentifiers.count == 0,
             "untagged monitor-ready announcement emitted an acknowledgement");

    CLIPRDR_FORMAT_DATA_REQUEST localRequest = { 0 };
    localRequest.common.msgType = CB_FORMAT_DATA_REQUEST;
    localRequest.requestedFormatId = CF_UNICODETEXT;
    JTAssert(context.ServerFormatDataRequest(&context, &localRequest) ==
                 CHANNEL_RC_OK,
             "Windows clipboard data request failed");
    JTAssert(JTClipboardDataResponseCount == 1 &&
             JTClipboardResponseData.length >= 2,
             "local clipboard payload was not returned");
    NSData *localUnicode = [JTClipboardResponseData
        subdataWithRange:NSMakeRange(0, JTClipboardResponseData.length - 2)];
    NSString *localWindowsText = [[NSString alloc]
        initWithData:localUnicode
            encoding:NSUTF16LittleEndianStringEncoding];
    JTAssert([localWindowsText isEqualToString:@"Mac\r\n中文"],
             "local clipboard payload was not UTF-16LE with Windows newlines");

    NSMutableData *maximumNewlineText = [NSMutableData
        dataWithLength:JTFreeRDPTextClipboardMaximumUTF8Bytes];
    memset(maximumNewlineText.mutableBytes, '\n', maximumNewlineText.length);
    error = nil;
    JTAssert([bridge updateLocalUTF8Text:maximumNewlineText error:&error],
             "maximum UTF-8 newline payload exceeded the bounded wire expansion");
    JTAssert(context.ServerFormatDataRequest(&context, &localRequest) ==
                 CHANNEL_RC_OK &&
             JTClipboardResponseData.length ==
                 JTFreeRDPTextClipboardMaximumWireBytes,
             "maximum newline payload did not produce the exact UTF-16LE wire bound");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "maximum-payload format announcement acknowledgement failed");

    NSString *barrierIdentifier = @"clipboard-barrier";
    error = nil;
    JTAssert([bridge
        updateLocalUTF8Text:localText
        acknowledgementIdentifier:barrierIdentifier
        error:&error], "tagged clipboard barrier was rejected");
    JTAssert(delegate.acknowledgedIdentifiers.count == 0,
             "clipboard barrier completed before Windows acknowledged it");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "clipboard barrier acknowledgement callback failed");
    JTAssert(([delegate.acknowledgedIdentifiers
                  isEqual:@[barrierIdentifier]] &&
              [delegate.acknowledgementResults isEqual:@[@YES]]),
             "clipboard barrier did not complete from the matching Windows ACK");

    NSData *fifoFirst = [@"first" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *fifoSecond = [@"second" dataUsingEncoding:NSUTF8StringEncoding];
    error = nil;
    JTAssert([bridge
        updateLocalUTF8Text:fifoFirst
        acknowledgementIdentifier:@"fifo-first"
        error:&error], "first FIFO clipboard announcement was rejected");
    error = nil;
    JTAssert([bridge
        updateLocalUTF8Text:fifoSecond
        acknowledgementIdentifier:@"fifo-second"
        error:&error], "second FIFO clipboard announcement was rejected");
    JTAssert(delegate.acknowledgedIdentifiers.count == 1,
             "FIFO clipboard announcements completed before their responses");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_FAIL) == CHANNEL_RC_OK,
             "FIFO failure response was not consumed");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "FIFO success response was not consumed");
    JTAssert(([delegate.acknowledgedIdentifiers
                  isEqual:@[barrierIdentifier, @"fifo-first", @"fifo-second"]] &&
              [delegate.acknowledgementResults
                  isEqual:@[@YES, @NO, @YES]]),
             "format-list acknowledgements were not matched in FIFO order");

    error = nil;
    JTAssert([bridge
        updateLocalUTF8Text:localText
        acknowledgementIdentifier:@"flags-zero"
        error:&error], "zero-flags test announcement was rejected");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, 0) == CHANNEL_RC_OK,
             "zero-flags format-list response was not consumed");
    error = nil;
    JTAssert([bridge
        updateLocalUTF8Text:localText
        acknowledgementIdentifier:@"flags-conflict"
        error:&error], "conflicting-flags test announcement was rejected");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK | CB_RESPONSE_FAIL) == CHANNEL_RC_OK,
             "conflicting-flags format-list response was not consumed");
    JTAssert(([[delegate.acknowledgedIdentifiers
                   subarrayWithRange:NSMakeRange(3, 2)]
                  isEqual:@[@"flags-zero", @"flags-conflict"]] &&
              [[delegate.acknowledgementResults
                   subarrayWithRange:NSMakeRange(3, 2)]
                  isEqual:@[@NO, @NO]]),
             "malformed format-list response flags were accepted");

    CLIPRDR_FORMAT remoteFormats[2] = {
        { .formatId = CF_TEXT, .formatName = NULL },
        { .formatId = CF_UNICODETEXT, .formatName = NULL }
    };
    CLIPRDR_FORMAT_LIST remoteList = { 0 };
    remoteList.common.msgType = CB_FORMAT_LIST;
    remoteList.numFormats = 2;
    remoteList.formats = remoteFormats;

    CLIPRDR_FORMAT_LIST malformedRemoteList = { 0 };
    malformedRemoteList.common.msgType = CB_FORMAT_LIST;
    malformedRemoteList.numFormats = 1;
    malformedRemoteList.formats = NULL;
    JTAssert(context.ServerFormatList(&context, &malformedRemoteList) ==
                 ERROR_INVALID_PARAMETER,
             "clipboard bridge accepted a missing remote format array");
    malformedRemoteList.numFormats = 4097;
    malformedRemoteList.formats = remoteFormats;
    JTAssert(context.ServerFormatList(&context, &malformedRemoteList) ==
                 ERROR_INVALID_PARAMETER,
             "clipboard bridge accepted an oversized remote format list");

    NSUInteger requestCountBeforePause = JTClipboardDataRequestCount;
    error = nil;
    JTAssert([bridge
        setAIControlIsolation:YES
        localUTF8Text:nil
        acknowledgementIdentifier:@"pause-one"
        error:&error], "AI clipboard isolation pause was rejected");
    JTAssert(JTClipboardFormats.count == 0,
             "AI clipboard pause did not advertise an empty format list");
    JTAssert(delegate.acknowledgedIdentifiers.count == 5,
             "AI clipboard pause completed before Windows acknowledged it");
    JTAssert(context.ServerFormatList(&context, &remoteList) == CHANNEL_RC_OK &&
             JTClipboardDataRequestCount == requestCountBeforePause,
             "remote clipboard intake was not suppressed before the pause ACK");
    JTAssert(context.ServerFormatDataRequest(&context, &localRequest) ==
                 CHANNEL_RC_OK &&
             JTClipboardResponseFlags == CB_RESPONSE_FAIL &&
             JTClipboardResponseData == nil,
             "AI clipboard pause still served the previous local payload");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "AI clipboard pause acknowledgement failed");
    JTAssert(([[delegate.acknowledgedIdentifiers lastObject]
                  isEqualToString:@"pause-one"] &&
              delegate.acknowledgementResults.lastObject.boolValue),
             "AI clipboard pause barrier did not complete successfully");
    JTAssert(context.ServerFormatList(&context, &remoteList) == CHANNEL_RC_OK &&
             JTClipboardDataRequestCount == requestCountBeforePause,
             "remote clipboard intake reopened after a pause ACK");
    error = nil;
    JTAssert(![bridge updateLocalUTF8Text:localText error:&error] &&
             error != nil,
             "ordinary clipboard synchronization bypassed AI isolation");

    NSData *resumeText =
        [@"human clipboard" dataUsingEncoding:NSUTF8StringEncoding];
    error = nil;
    JTAssert([bridge
        setAIControlIsolation:NO
        localUTF8Text:resumeText
        acknowledgementIdentifier:@"resume-one"
        error:&error], "AI clipboard resume was rejected");
    JTAssert(context.ServerFormatList(&context, &remoteList) == CHANNEL_RC_OK &&
             JTClipboardDataRequestCount == requestCountBeforePause,
             "remote clipboard intake reopened before the resume ACK");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "AI clipboard resume acknowledgement failed");
    JTAssert(context.ServerFormatList(&context, &remoteList) == CHANNEL_RC_OK &&
             JTClipboardDataRequestCount == requestCountBeforePause + 1 &&
             JTClipboardRequestedFormat == CF_UNICODETEXT,
             "remote clipboard intake did not reopen after the resume ACK");

    CLIPRDR_FORMAT unicodeOnlyFormat = {
        .formatId = CF_UNICODETEXT,
        .formatName = NULL
    };
    CLIPRDR_FORMAT_LIST unicodeOnlyList = { 0 };
    unicodeOnlyList.common.msgType = CB_FORMAT_LIST;
    unicodeOnlyList.numFormats = 1;
    unicodeOnlyList.formats = &unicodeOnlyFormat;
    CLIPRDR_FORMAT textOnlyFormat = {
        .formatId = CF_TEXT,
        .formatName = NULL
    };
    CLIPRDR_FORMAT_LIST textOnlyList = { 0 };
    textOnlyList.common.msgType = CB_FORMAT_LIST;
    textOnlyList.numFormats = 1;
    textOnlyList.formats = &textOnlyFormat;

    NSUInteger serializedRequestCount = JTClipboardDataRequestCount;
    JTAssert(context.ServerFormatList(&context, &unicodeOnlyList) ==
                 CHANNEL_RC_OK &&
             context.ServerFormatList(&context, &textOnlyList) ==
                 CHANNEL_RC_OK,
             "consecutive remote clipboard format lists were rejected");
    JTAssert(JTClipboardDataRequestCount == serializedRequestCount,
             "more than one remote clipboard data request was in flight");

    NSData *remotePayload =
        JTTestUnicodeClipboardPayload(@"Windows\r\n回传");
    CLIPRDR_FORMAT_DATA_RESPONSE remoteResponse = { 0 };
    remoteResponse.common.msgType = CB_FORMAT_DATA_RESPONSE;
    remoteResponse.common.msgFlags = CB_RESPONSE_OK;
    remoteResponse.common.dataLen = (UINT32)remotePayload.length;
    remoteResponse.requestedFormatData = remotePayload.bytes;
    JTAssert(context.ServerFormatDataResponse(&context, &remoteResponse) ==
                 CHANNEL_RC_OK,
             "remote Unicode clipboard response failed");
    NSString *received = [[NSString alloc] initWithData:delegate.receivedText
                                                encoding:NSUTF8StringEncoding];
    JTAssert([received isEqualToString:@"Windows\n回传"],
             "remote clipboard text was not bounded UTF-8 with macOS newlines");
    JTAssert(JTClipboardDataRequestCount == serializedRequestCount + 1 &&
             JTClipboardRequestedFormat == CF_TEXT &&
             [JTClipboardRequestedFormats.lastObject isEqual:@(CF_TEXT)],
             "latest pending remote format was not requested after the first response");

    NSData *legacyPayload = JTTestLegacyClipboardPayload(@"latest");
    CLIPRDR_FORMAT_DATA_RESPONSE legacyResponse = { 0 };
    legacyResponse.common.msgType = CB_FORMAT_DATA_RESPONSE;
    legacyResponse.common.msgFlags = CB_RESPONSE_OK;
    legacyResponse.common.dataLen = (UINT32)legacyPayload.length;
    legacyResponse.requestedFormatData = legacyPayload.bytes;
    JTAssert(context.ServerFormatDataResponse(&context, &legacyResponse) ==
                 CHANNEL_RC_OK,
             "latest pending remote clipboard response failed");
    NSString *latestReceived = [[NSString alloc]
        initWithData:delegate.receivedText
            encoding:NSUTF8StringEncoding];
    JTAssert([latestReceived isEqualToString:@"latest"],
             "latest pending remote clipboard payload was not delivered");

    NSUInteger receivedCountBeforeInvalidFlags = delegate.receivedTexts.count;
    JTAssert(context.ServerFormatList(&context, &unicodeOnlyList) ==
                 CHANNEL_RC_OK,
             "remote list for failure-flags test was rejected");
    remoteResponse.common.msgFlags = CB_RESPONSE_FAIL;
    JTAssert(context.ServerFormatDataResponse(&context, &remoteResponse) ==
                 CHANNEL_RC_OK &&
             delegate.receivedTexts.count == receivedCountBeforeInvalidFlags,
             "remote clipboard failure response delivered untrusted text");
    JTAssert(context.ServerFormatList(&context, &unicodeOnlyList) ==
                 CHANNEL_RC_OK,
             "remote list for zero-flags test was rejected");
    remoteResponse.common.msgFlags = 0;
    JTAssert(context.ServerFormatDataResponse(&context, &remoteResponse) ==
                 CHANNEL_RC_OK &&
             delegate.receivedTexts.count == receivedCountBeforeInvalidFlags,
             "remote clipboard zero-flags response delivered untrusted text");

    NSUInteger receivedCountBeforeStaleResponse =
        delegate.receivedTexts.count;
    NSUInteger requestCountBeforeStaleResponse =
        JTClipboardDataRequestCount;
    JTAssert(context.ServerFormatList(&context, &unicodeOnlyList) ==
                 CHANNEL_RC_OK &&
             JTClipboardDataRequestCount ==
                 requestCountBeforeStaleResponse + 1 &&
             JTClipboardRequestedFormat == CF_UNICODETEXT,
             "remote request for the isolation transition test was not issued");
    error = nil;
    JTAssert([bridge
        setAIControlIsolation:YES
        localUTF8Text:nil
        acknowledgementIdentifier:@"pause-with-remote-response-pending"
        error:&error] &&
             JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "pause with an outstanding remote response failed");
    error = nil;
    JTAssert([bridge
        setAIControlIsolation:NO
        localUTF8Text:resumeText
        acknowledgementIdentifier:@"resume-with-remote-response-pending"
        error:&error] &&
             JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "resume with an outstanding remote response failed");
    JTAssert(context.ServerFormatList(&context, &textOnlyList) ==
                 CHANNEL_RC_OK &&
             JTClipboardDataRequestCount ==
                 requestCountBeforeStaleResponse + 1,
             "a new remote request bypassed the outstanding response drain");

    NSData *staleRemotePayload =
        JTTestUnicodeClipboardPayload(@"stale-before-isolation");
    CLIPRDR_FORMAT_DATA_RESPONSE staleRemoteResponse = { 0 };
    staleRemoteResponse.common.msgType = CB_FORMAT_DATA_RESPONSE;
    staleRemoteResponse.common.msgFlags = CB_RESPONSE_OK;
    staleRemoteResponse.common.dataLen =
        (UINT32)staleRemotePayload.length;
    staleRemoteResponse.requestedFormatData = staleRemotePayload.bytes;
    JTAssert(context.ServerFormatDataResponse(
                 &context, &staleRemoteResponse) == CHANNEL_RC_OK &&
             delegate.receivedTexts.count ==
                 receivedCountBeforeStaleResponse,
             "a pre-isolation remote response crossed the clipboard boundary");
    JTAssert(JTClipboardDataRequestCount ==
                 requestCountBeforeStaleResponse + 2 &&
             JTClipboardRequestedFormat == CF_TEXT,
             "the latest post-resume remote format was not requested after draining the stale response");

    NSData *freshRemotePayload =
        JTTestLegacyClipboardPayload(@"fresh-after-resume");
    CLIPRDR_FORMAT_DATA_RESPONSE freshRemoteResponse = { 0 };
    freshRemoteResponse.common.msgType = CB_FORMAT_DATA_RESPONSE;
    freshRemoteResponse.common.msgFlags = CB_RESPONSE_OK;
    freshRemoteResponse.common.dataLen =
        (UINT32)freshRemotePayload.length;
    freshRemoteResponse.requestedFormatData = freshRemotePayload.bytes;
    JTAssert(context.ServerFormatDataResponse(
                 &context, &freshRemoteResponse) == CHANNEL_RC_OK &&
             delegate.receivedTexts.count ==
                 receivedCountBeforeStaleResponse + 1,
             "the post-resume remote response was not delivered");
    NSString *freshReceived = [[NSString alloc]
        initWithData:delegate.receivedText
            encoding:NSUTF8StringEncoding];
    JTAssert([freshReceived isEqualToString:@"fresh-after-resume"],
             "the stale remote response was misassociated with the post-resume format");

    error = nil;
    JTAssert([bridge
        setAIControlIsolation:YES
        localUTF8Text:nil
        acknowledgementIdentifier:@"pause-two"
        error:&error] &&
             JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "second AI clipboard pause barrier failed");
    error = nil;
    JTAssert([bridge
        setAIControlIsolation:NO
        localUTF8Text:resumeText
        acknowledgementIdentifier:@"resume-superseded"
        error:&error], "superseded clipboard resume was rejected");
    error = nil;
    JTAssert([bridge
        setAIControlIsolation:YES
        localUTF8Text:nil
        acknowledgementIdentifier:@"pause-after-resume"
        error:&error], "pause that supersedes a pending resume was rejected");
    NSUInteger requestCountBeforeSupersededResumeACK =
        JTClipboardDataRequestCount;
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "superseded resume acknowledgement was not consumed");
    JTAssert(context.ServerFormatList(&context, &remoteList) == CHANNEL_RC_OK &&
             JTClipboardDataRequestCount ==
                 requestCountBeforeSupersededResumeACK,
             "a stale resume ACK reopened clipboard intake during newer AI control");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "pause-after-resume acknowledgement was not consumed");
    JTAssert(context.ServerFormatList(&context, &remoteList) == CHANNEL_RC_OK &&
             JTClipboardDataRequestCount ==
                 requestCountBeforeSupersededResumeACK,
             "newer AI pause did not remain isolated after its acknowledgement");
    error = nil;
    JTAssert([bridge
        setAIControlIsolation:NO
        localUTF8Text:resumeText
        acknowledgementIdentifier:@"resume-failed"
        error:&error] &&
             JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_FAIL) == CHANNEL_RC_OK,
             "failed resume acknowledgement was not consumed");
    NSUInteger requestCountAfterFailedResume = JTClipboardDataRequestCount;
    JTAssert(context.ServerFormatList(&context, &remoteList) == CHANNEL_RC_OK &&
             JTClipboardDataRequestCount == requestCountAfterFailedResume,
             "failed resume ACK reopened remote clipboard intake");
    error = nil;
    JTAssert([bridge
        setAIControlIsolation:NO
        localUTF8Text:resumeText
        acknowledgementIdentifier:@"resume-zero"
        error:&error] &&
             JTTestAcknowledgeClipboardFormatList(
                 &context, 0) == CHANNEL_RC_OK,
             "zero-flags resume acknowledgement was not consumed");
    JTAssert(context.ServerFormatList(&context, &remoteList) == CHANNEL_RC_OK &&
             JTClipboardDataRequestCount == requestCountAfterFailedResume,
             "zero-flags resume ACK reopened remote clipboard intake");
    error = nil;
    JTAssert([bridge
        setAIControlIsolation:NO
        localUTF8Text:resumeText
        acknowledgementIdentifier:@"resume-final"
        error:&error] &&
             JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK,
             "final AI clipboard resume barrier failed");

    CLIPRDR_FILE_CONTENTS_REQUEST fileRequest = { 0 };
    fileRequest.common.msgType = CB_FILECONTENTS_REQUEST;
    fileRequest.streamId = 41;
    fileRequest.listIndex = 0;
    fileRequest.dwFlags = FILECONTENTS_SIZE;
    fileRequest.cbRequested = sizeof(uint64_t);
    JTAssert(context.ServerFileContentsRequest(&context, &fileRequest) ==
                 CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseCount == 1 &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_FAIL &&
             JTClipboardFileContentsResponseStreamID == 41 &&
             JTClipboardFileContentsResponseData == nil,
             "clipboard bridge did not reject a file request without an active offer");

    CLIPRDR_FILE_CONTENTS_RESPONSE inboundFileResponse = { 0 };
    inboundFileResponse.common.msgType = CB_FILECONTENTS_RESPONSE;
    inboundFileResponse.common.msgFlags = CB_RESPONSE_OK;
    JTAssert(context.ServerFileContentsResponse(
                 &context, &inboundFileResponse) == ERROR_NOT_SUPPORTED,
             "clipboard bridge accepted remote-to-local file content");

    NSURL *fileDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                      isDirectory:YES];
    JTAssert([[NSFileManager defaultManager]
        createDirectoryAtURL:fileDirectory
 withIntermediateDirectories:NO
                  attributes:nil
                       error:&error],
             "file-offer test directory could not be created");
    NSURL *installerURL = [fileDirectory
        URLByAppendingPathComponent:@"private-source-name.exe"
                       isDirectory:NO];
    NSData *installerData =
        [@"companion-test-payload" dataUsingEncoding:NSUTF8StringEncoding];
    JTAssert([installerData writeToURL:installerURL
                              options:NSDataWritingAtomic
                                error:&error],
             "file-offer test payload could not be written");

    NSString *installerSHA256 =
        @"dc0a6aeaa9b5b120e5022005d01219be17b398482a62419fa9d0423f080e79a1";
    error = nil;
    JTAssert(!bridge.fileTransferReady &&
             delegate.fileTransferReadinessUpdates.count == 0 &&
             ![bridge
                 offerFileAtURL:installerURL
                 remoteFileName:@"JTS-Windows-Companion-Setup.exe"
                 expectedSHA256:installerSHA256
                 acknowledgementIdentifier:@"missing-capabilities"
                 error:&error] &&
             [error.userInfo[@"JTFreeRDPErrorCode"]
                 isEqualToString:@"RDP_FILE_CLIPBOARD_UNAVAILABLE"],
             "file offer was accepted before Windows sent file clipboard capabilities");

    const UINT32 partialCapabilityFlags[] = {
        CB_STREAM_FILECLIP_ENABLED,
        CB_FILECLIP_NO_FILE_PATHS,
    };
    for (NSUInteger index = 0;
         index < sizeof(partialCapabilityFlags) /
             sizeof(partialCapabilityFlags[0]);
         index++) {
        JTAssert(JTTestSendServerClipboardCapabilities(
                     &context,
                     CB_USE_LONG_FORMAT_NAMES |
                         partialCapabilityFlags[index]) == CHANNEL_RC_OK,
                 "partial Windows clipboard capabilities were rejected");
        error = nil;
        JTAssert(!bridge.fileTransferReady &&
                 delegate.fileTransferReadinessUpdates.count == 0 &&
                 ![bridge
                     offerFileAtURL:installerURL
                     remoteFileName:@"JTS-Windows-Companion-Setup.exe"
                     expectedSHA256:installerSHA256
                     acknowledgementIdentifier:@"partial-capabilities"
                     error:&error] &&
                 [error.userInfo[@"JTFreeRDPErrorCode"]
                     isEqualToString:@"RDP_FILE_CLIPBOARD_UNAVAILABLE"],
                 "file offer accepted incomplete Windows file clipboard capabilities");
    }

    JTAssert(JTTestSendServerClipboardCapabilities(
                 &context,
                 CB_USE_LONG_FORMAT_NAMES |
                     CB_STREAM_FILECLIP_ENABLED |
                     CB_FILECLIP_NO_FILE_PATHS) == CHANNEL_RC_OK &&
             bridge.fileTransferReady &&
             [delegate.fileTransferReadinessUpdates isEqual:@[@YES]],
             "complete Windows file clipboard capabilities did not enable file offers");

    error = nil;
    JTAssert(![bridge
        offerFileAtURL:installerURL
        remoteFileName:@"JTS-Windows-Companion-Setup.exe"
        expectedSHA256:
            @"0000000000000000000000000000000000000000000000000000000000000000"
        acknowledgementIdentifier:@"bad-hash"
        error:&error] &&
             error != nil,
             "clipboard bridge accepted a file whose SHA-256 did not match");

    NSString *fileOfferIdentifier = @"companion-file-offer";
    NSUInteger acknowledgementsBeforeFileOffer =
        delegate.acknowledgedIdentifiers.count;
    error = nil;
    JTAssert([bridge
        offerFileAtURL:installerURL
        remoteFileName:@"JTS-Windows-Companion-Setup.exe"
        expectedSHA256:installerSHA256
        acknowledgementIdentifier:fileOfferIdentifier
        error:&error] &&
             error == nil,
             "valid bounded Companion installer offer was rejected");
    JTAssert([JTClipboardFormats isEqual:@[@(0x0000C0A1)]] &&
             [JTClipboardFormatNames
                 isEqual:@[@"FileGroupDescriptorW"]],
             "file offer advertised anything beyond one path-free file descriptor");
    JTAssert(delegate.acknowledgedIdentifiers.count ==
                 acknowledgementsBeforeFileOffer,
             "file offer completed before Windows acknowledged its format list");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK &&
             [delegate.acknowledgedIdentifiers.lastObject
                 isEqualToString:fileOfferIdentifier] &&
             delegate.acknowledgementResults.lastObject.boolValue,
             "file offer did not complete from its matching Windows acknowledgement");
    JTAssert([delegate.fileTransferUpdates.lastObject[@"fileName"]
                 isEqualToString:@"JTS-Windows-Companion-Setup.exe"] &&
             [delegate.fileTransferUpdates.lastObject[@"fileSize"]
                 unsignedLongLongValue] == installerData.length &&
             ![delegate.fileTransferUpdates.lastObject.allValues
                 containsObject:installerURL.path],
             "file-offer metadata exposed a source path or incorrect fixed metadata");

    error = nil;
    JTAssert(![bridge updateLocalUTF8Text:localText error:&error] &&
             [error.userInfo[@"JTFreeRDPErrorCode"]
                 isEqualToString:@"RDP_CLIPBOARD_FILE_OFFER_ACTIVE"],
             "ordinary text synchronization replaced an active installer offer");

    CLIPRDR_FORMAT_DATA_REQUEST descriptorRequest = { 0 };
    descriptorRequest.common.msgType = CB_FORMAT_DATA_REQUEST;
    descriptorRequest.requestedFormatId = 0x0000C0A1;
    NSUInteger dataResponsesBeforeDescriptor =
        JTClipboardDataResponseCount;
    JTAssert(context.ServerFormatDataRequest(
                 &context, &descriptorRequest) == CHANNEL_RC_OK &&
             JTClipboardDataResponseCount ==
                 dataResponsesBeforeDescriptor + 1 &&
             JTClipboardResponseFlags == CB_RESPONSE_OK &&
             JTClipboardResponseData.length == 596,
             "single-file descriptor payload was not returned");
    JTAssert(JTTestReadUInt32LittleEndian(
                 JTClipboardResponseData, 0) == 1,
             "file descriptor payload did not contain exactly one file");
    uint32_t descriptorFlags =
        JTTestReadUInt32LittleEndian(JTClipboardResponseData, 4);
    JTAssert((descriptorFlags & FD_ATTRIBUTES) != 0 &&
             (descriptorFlags & FD_FILESIZE) != 0 &&
             (((uint64_t)JTTestReadUInt32LittleEndian(
                    JTClipboardResponseData, 68) << 32) |
                JTTestReadUInt32LittleEndian(
                    JTClipboardResponseData, 72)) ==
                 installerData.length,
             "file descriptor omitted its bounded size or attributes");
    NSString *advertisedFileName = JTTestReadUTF16LECString(
        JTClipboardResponseData,
        76);
    JTAssert([advertisedFileName
                 isEqualToString:@"JTS-Windows-Companion-Setup.exe"] &&
             ![advertisedFileName
                 containsString:installerURL.path],
             "packed file descriptor exposed the local source path");

    NSUInteger fileResponsesBeforeSize =
        JTClipboardFileContentsResponseCount;
    JTAssert(context.ServerFileContentsRequest(
                 &context, &fileRequest) == CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseCount ==
                 fileResponsesBeforeSize + 1 &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_OK &&
             JTClipboardFileContentsResponseStreamID == 41 &&
             JTClipboardFileContentsResponseData.length ==
                 sizeof(uint64_t) &&
             JTTestReadUInt64LittleEndian(
                 JTClipboardFileContentsResponseData, 0) ==
                 installerData.length,
             "FILECONTENTS_SIZE did not return the exact fixed offer size");

    CLIPRDR_FILE_CONTENTS_REQUEST rangeRequest = { 0 };
    rangeRequest.common.msgType = CB_FILECONTENTS_REQUEST;
    rangeRequest.streamId = 42;
    rangeRequest.listIndex = 0;
    rangeRequest.dwFlags = FILECONTENTS_RANGE;
    rangeRequest.nPositionLow = 4;
    rangeRequest.cbRequested = 8;
    JTAssert(context.ServerFileContentsRequest(
                 &context, &rangeRequest) == CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_OK &&
             JTClipboardFileContentsResponseStreamID == 42 &&
             [JTClipboardFileContentsResponseData
                 isEqual:[@"anion-te"
                     dataUsingEncoding:NSUTF8StringEncoding]],
             "FILECONTENTS_RANGE returned bytes outside the requested range");

    CLIPRDR_FILE_CONTENTS_REQUEST invalidRequest = rangeRequest;
    invalidRequest.streamId = 43;
    invalidRequest.listIndex = 1;
    JTAssert(context.ServerFileContentsRequest(
                 &context, &invalidRequest) == CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_FAIL &&
             JTClipboardFileContentsResponseStreamID == 43,
             "file offer accepted a nonzero single-file list index");

    invalidRequest = rangeRequest;
    invalidRequest.streamId = 44;
    invalidRequest.haveClipDataId = TRUE;
    invalidRequest.clipDataId = 7;
    JTAssert(context.ServerFileContentsRequest(
                 &context, &invalidRequest) == CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_FAIL,
             "file offer accepted an unnegotiated clipboard lock identifier");

    invalidRequest = rangeRequest;
    invalidRequest.streamId = 45;
    invalidRequest.cbRequested =
        JTFreeRDPFileClipboardMaximumRangeBytes + 1;
    JTAssert(context.ServerFileContentsRequest(
                 &context, &invalidRequest) == CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_FAIL,
             "file offer accepted an oversized range request");

    invalidRequest = rangeRequest;
    invalidRequest.streamId = 46;
    invalidRequest.nPositionLow = (UINT32)installerData.length + 1;
    JTAssert(context.ServerFileContentsRequest(
                 &context, &invalidRequest) == CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_FAIL,
             "file offer accepted a range starting beyond end of file");

    invalidRequest = fileRequest;
    invalidRequest.streamId = 47;
    invalidRequest.cbRequested = sizeof(uint64_t) - 1;
    JTAssert(context.ServerFileContentsRequest(
                 &context, &invalidRequest) == CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_FAIL,
             "file offer accepted a malformed size request");

    rangeRequest.streamId = 48;
    rangeRequest.nPositionLow = 18;
    rangeRequest.cbRequested = 16;
    JTAssert(context.ServerFileContentsRequest(
                 &context, &rangeRequest) == CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_OK &&
             [JTClipboardFileContentsResponseData
                 isEqual:[@"load"
                     dataUsingEncoding:NSUTF8StringEncoding]] &&
             [delegate.fileTransferUpdates.lastObject[@"completed"]
                 boolValue],
             "final bounded range did not truncate at EOF and complete the offer");

    NSString *fileClearIdentifier = @"companion-file-clear";
    error = nil;
    JTAssert(([bridge
        clearFileOfferWithAcknowledgementIdentifier:fileClearIdentifier
        error:&error] &&
             error == nil &&
             [JTClipboardFormats
                 isEqual:@[@(CF_UNICODETEXT), @(CF_TEXT)]]),
             "clearing the file offer did not restore the human text formats");
    JTAssert(JTTestAcknowledgeClipboardFormatList(
                 &context, CB_RESPONSE_OK) == CHANNEL_RC_OK &&
             [delegate.acknowledgedIdentifiers.lastObject
                 isEqualToString:fileClearIdentifier] &&
             delegate.acknowledgementResults.lastObject.boolValue,
             "file-offer revocation was not acknowledged");
    fileRequest.streamId = 49;
    JTAssert(context.ServerFileContentsRequest(
                 &context, &fileRequest) == CHANNEL_RC_OK &&
             JTClipboardFileContentsResponseFlags == CB_RESPONSE_FAIL,
             "file contents remained readable after explicit offer revocation");

    NSArray<NSNumber *> *readinessAfterDowngrade = @[@YES, @NO];
    JTAssert(JTTestSendServerClipboardCapabilities(
                 &context,
                 CB_USE_LONG_FORMAT_NAMES |
                     CB_STREAM_FILECLIP_ENABLED) == CHANNEL_RC_OK &&
             !bridge.fileTransferReady &&
             [delegate.fileTransferReadinessUpdates
                 isEqual:readinessAfterDowngrade],
             "capability downgrade did not revoke file-transfer readiness");
    error = nil;
    JTAssert(![bridge
                 offerFileAtURL:installerURL
                 remoteFileName:@"JTS-Windows-Companion-Setup.exe"
                 expectedSHA256:installerSHA256
                 acknowledgementIdentifier:@"downgraded-capabilities"
                 error:&error] &&
             [error.userInfo[@"JTFreeRDPErrorCode"]
                 isEqualToString:@"RDP_FILE_CLIPBOARD_UNAVAILABLE"],
             "file offer remained available after a capability downgrade");

    error = nil;
    NSData *oversized = [NSMutableData
        dataWithLength:JTFreeRDPTextClipboardMaximumUTF8Bytes + 1];
    JTAssert(![bridge updateLocalUTF8Text:oversized error:&error],
             "clipboard bridge accepted an oversized local payload");

    error = nil;
    JTAssert([bridge
        updateLocalUTF8Text:fifoFirst
        acknowledgementIdentifier:@"detach-first"
        error:&error], "first detach-pending announcement was rejected");
    error = nil;
    JTAssert([bridge
        updateLocalUTF8Text:fifoSecond
        acknowledgementIdentifier:@"detach-second"
        error:&error], "second detach-pending announcement was rejected");
    NSArray<NSNumber *> *readinessAfterRestore = @[@YES, @NO, @YES];
    JTAssert(JTTestSendServerClipboardCapabilities(
                 &context,
                 CB_USE_LONG_FORMAT_NAMES |
                     CB_STREAM_FILECLIP_ENABLED |
                     CB_FILECLIP_NO_FILE_PATHS) == CHANNEL_RC_OK &&
             bridge.fileTransferReady &&
             [delegate.fileTransferReadinessUpdates
                 isEqual:readinessAfterRestore],
             "complete capabilities did not restore file-transfer readiness");
    error = nil;
    JTAssert([bridge
        offerFileAtURL:installerURL
        remoteFileName:@"JTS-Windows-Companion-Setup.exe"
        expectedSHA256:installerSHA256
        acknowledgementIdentifier:nil
        error:&error],
             "file offer used for detach revocation was rejected");
    NSUInteger acknowledgementsBeforeDetach =
        delegate.acknowledgedIdentifiers.count;
    [bridge detachContext:&context];
    JTAssert(context.custom == NULL,
             "clipboard bridge left a dangling cliprdr custom pointer");
    JTAssert((delegate.acknowledgedIdentifiers.count ==
                 acknowledgementsBeforeDetach + 2 &&
             [[delegate.acknowledgedIdentifiers
                   subarrayWithRange:NSMakeRange(
                       acknowledgementsBeforeDetach, 2)]
                  isEqual:@[@"detach-first", @"detach-second"]] &&
             [[delegate.acknowledgementResults
                   subarrayWithRange:NSMakeRange(
                       acknowledgementsBeforeDetach, 2)]
                  isEqual:@[@NO, @NO]]),
             "detach did not reject pending format announcements in FIFO order");
    JTAssert(context.ServerFileContentsRequest(
                 &context, &fileRequest) == ERROR_INVALID_PARAMETER,
             "detached clipboard context continued serving file content");
    JTAssert([delegate.fileTransferUpdates.lastObject[@"errorCode"]
                 isEqualToString:@"RDP_FILE_TRANSFER_DISCONNECTED"],
             "detach did not report revocation of an incomplete file offer");
    [[NSFileManager defaultManager] removeItemAtURL:fileDirectory error:nil];
    return 0;
}

static int JTTestQueueDeadlineCancellationAndReplay(void)
{
    __block uint64_t now = 1000;
    JTFreeRDPCommandQueue *queue = [[JTFreeRDPCommandQueue alloc]
        initWithCapacity:2
                   clock:^uint64_t { return now; }];
    NSString *firstID = NSUUID.UUID.UUIDString.lowercaseString;
    __block BOOL completed = NO;
    NSError *error = nil;
    BOOL accepted = [queue enqueueCommand:@{ @"commandKind": @"input" }
                         requestIdentifier:firstID
              deadlineUptimeMilliseconds:2000
                              queueFullCode:@"INPUT_QUEUE_FULL"
                                 completion:^(NSError *completionError) {
        completed = completionError == nil;
    }
                                      error:&error];
    JTAssert(accepted && error == nil && queue.pendingCount == 1,
             "valid command was not queued");
    __block NSUInteger executions = 0;
    [queue drainWithExecutor:^NSError * _Nullable(NSDictionary *command) {
        (void)command;
        executions += 1;
        return nil;
    }];
    JTAssert(executions == 1 && completed && queue.pendingCount == 0,
             "valid command did not execute exactly once");

    error = nil;
    JTAssert(![queue enqueueCommand:@{ @"commandKind": @"input" }
                      requestIdentifier:firstID
           deadlineUptimeMilliseconds:3000
                           queueFullCode:@"INPUT_QUEUE_FULL"
                              completion:^(NSError *completionError) { (void)completionError; }
                                   error:&error], "replayed request identifier was accepted");
    JTAssert([error.userInfo[JTFreeRDPCommandQueueErrorCodeKey]
        isEqualToString:@"RDP_XPC_REQUEST_DUPLICATE"], "duplicate error code is unstable");

    NSString *expiredID = NSUUID.UUID.UUIDString.lowercaseString;
    __block NSString *expiredCode = nil;
    error = nil;
    JTAssert([queue enqueueCommand:@{ @"commandKind": @"input" }
                   requestIdentifier:expiredID
        deadlineUptimeMilliseconds:1500
                        queueFullCode:@"INPUT_QUEUE_FULL"
                           completion:^(NSError *completionError) {
        expiredCode = completionError.userInfo[JTFreeRDPCommandQueueErrorCodeKey];
    }
                                error:&error], "future command was not queued");
    now = 1501;
    [queue drainWithExecutor:^NSError * _Nullable(NSDictionary *command) {
        (void)command;
        executions += 1;
        return nil;
    }];
    JTAssert(executions == 1, "expired command reached the executor");
    JTAssert([expiredCode isEqualToString:@"RDP_XPC_REQUEST_EXPIRED"],
             "expired command did not receive a stable failure");

    NSString *cancelledID = NSUUID.UUID.UUIDString.lowercaseString;
    __block NSString *cancelledCode = nil;
    error = nil;
    JTAssert([queue enqueueCommand:@{ @"commandKind": @"dvc" }
                   requestIdentifier:cancelledID
        deadlineUptimeMilliseconds:3000
                        queueFullCode:@"DVC_QUEUE_FULL"
                           completion:^(NSError *completionError) {
        cancelledCode = completionError.userInfo[JTFreeRDPCommandQueueErrorCodeKey];
    }
                                error:&error], "cancellable command was not queued");
    JTAssert([queue cancelRequestIdentifier:cancelledID],
             "queued request cancellation did not prevent execution");
    [queue drainWithExecutor:^NSError * _Nullable(NSDictionary *command) {
        (void)command;
        executions += 1;
        return nil;
    }];
    JTAssert(executions == 1, "cancelled command reached the executor");
    JTAssert([cancelledCode isEqualToString:@"RDP_XPC_REQUEST_CANCELLED"],
             "cancelled command did not receive a stable failure");
    return 0;
}

static int JTTestFinalMouseFrameValidation(void)
{
    uint64_t now = 5000;
    JTFreeRDPCommandQueue *queue = [[JTFreeRDPCommandQueue alloc]
        initWithCapacity:2
                   clock:^uint64_t { return now; }];
    NSString *observedFrameID = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *repaintedFrameID = NSUUID.UUID.UUIDString.lowercaseString;
    __block NSDictionary<NSString *, id> *currentFrame =
        JTFrame(observedFrameID, 40);
    NSError *error = nil;
    NSDictionary *mouse = JTFreeRDPSanitizedInput(
        JTMouseInput(observedFrameID, 40, @"click"),
        &error);
    JTAssert(mouse != nil && error == nil, "valid mouse input was not sanitized");

    NSMutableDictionary *command = [mouse mutableCopy];
    command[@"commandKind"] = @"input";
    command[@"expectedConnectionAttemptId"] = JTConnectionAttemptA();
    __block NSUInteger mouseEventCount = 0;
    __block NSString *completionCode = nil;
    JTAssert([queue enqueueCommand:command
                  requestIdentifier:NSUUID.UUID.UUIDString.lowercaseString
       deadlineUptimeMilliseconds:6000
                       queueFullCode:@"INPUT_QUEUE_FULL"
                          completion:^(NSError *completionError) {
        completionCode =
            completionError.userInfo[JTFreeRDPXPCValidationErrorCodeKey] ?:
            completionError.userInfo[JTFreeRDPCommandQueueErrorCodeKey];
    }
                               error:&error], "mouse input was not queued");

    currentFrame = JTFrame(repaintedFrameID, 41);
    [queue drainWithExecutor:^NSError * _Nullable(NSDictionary *queuedCommand) {
        NSError *validationError = nil;
        if (JTFreeRDPInputCommandForExecution(
                queuedCommand,
                currentFrame,
                JTConnectionAttemptA(),
                &validationError)) {
            mouseEventCount += 1;
        }
        return validationError;
    }];
    JTAssert(mouseEventCount == 0,
             "a repaint after enqueue still emitted a mouse event");
    JTAssert([completionCode isEqualToString:@"STATE_CONFLICT"],
             "a repaint after enqueue did not return STATE_CONFLICT");

    error = nil;
    NSDictionary *currentMouse = JTFreeRDPSanitizedInput(
        JTMouseInput(repaintedFrameID, 41, @"doubleClick"),
        &error);
    JTAssert(currentMouse != nil && error == nil,
             "current-frame double-click was not sanitized");
    NSMutableDictionary *currentCommand = [currentMouse mutableCopy];
    currentCommand[@"commandKind"] = @"input";
    currentCommand[@"expectedConnectionAttemptId"] = JTConnectionAttemptA();
    __block NSError *currentCompletionError = nil;
    JTAssert([queue enqueueCommand:currentCommand
                  requestIdentifier:NSUUID.UUID.UUIDString.lowercaseString
       deadlineUptimeMilliseconds:6000
                       queueFullCode:@"INPUT_QUEUE_FULL"
                          completion:^(NSError *completionError) {
        currentCompletionError = completionError;
    }
                               error:&error], "current-frame mouse input was not queued");
    [queue drainWithExecutor:^NSError * _Nullable(NSDictionary *queuedCommand) {
        NSError *validationError = nil;
        if (JTFreeRDPInputCommandForExecution(
                queuedCommand,
                currentFrame,
                JTConnectionAttemptA(),
                &validationError)) {
            mouseEventCount += 1;
        }
        return validationError;
    }];
    JTAssert(mouseEventCount == 1 && currentCompletionError == nil,
             "current-frame mouse input did not execute exactly once");
    return 0;
}

static int JTTestFinalStateValidationAndManualRebind(void)
{
    NSString *observedFrameID = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *currentFrameID = NSUUID.UUID.UUIDString.lowercaseString;
    NSString *exactText = @"A:B_C$D|E{F}G-123";
    NSDictionary *currentFrame = JTFrame(currentFrameID, 41);
    NSArray<NSDictionary<NSString *, id> *> *inputs = @[
        @{
            @"type": @"scancode",
            @"scancode": @30,
            @"down": @YES,
            @"repeat": @NO,
            @"expectedStateRevision": @40,
        },
        @{
            @"type": @"keyChord",
            @"scancodes": @[@29, @56, @83],
            @"expectedStateRevision": @40,
        },
        @{
            @"type": @"text",
            @"text": exactText,
            @"expectedStateRevision": @40,
        },
    ];
    for (NSDictionary *input in inputs) {
        NSError *error = nil;
        NSDictionary *sanitized = JTFreeRDPSanitizedInput(input, &error);
        JTAssert(sanitized != nil && error == nil,
                 "state-bound input was not sanitized");
        if ([input[@"type"] isEqualToString:@"text"]) {
            JTAssert([sanitized[@"text"] isEqualToString:exactText],
                     "AI text input changed during native sanitization");
        }
        NSMutableDictionary *attemptBoundInput = [sanitized mutableCopy];
        attemptBoundInput[@"expectedConnectionAttemptId"] = JTConnectionAttemptA();
        error = nil;
        JTAssert(JTFreeRDPInputCommandForExecution(
            attemptBoundInput,
            currentFrame,
            JTConnectionAttemptA(),
            &error) == nil, "stale AI keyboard or text input was accepted");
        JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
            isEqualToString:@"STATE_CONFLICT"],
                 "stale AI keyboard or text input returned an unstable error");

        NSMutableDictionary *manual = [input mutableCopy];
        manual[@"inputOrigin"] = @"localManual";
        error = nil;
        NSDictionary *manualSanitized = JTFreeRDPSanitizedInput(manual, &error);
        JTAssert(manualSanitized != nil && error == nil,
                 "manual keyboard or text input was not sanitized");
        if ([input[@"type"] isEqualToString:@"text"]) {
            JTAssert([manualSanitized[@"text"] isEqualToString:exactText],
                     "manual text input changed during native sanitization");
        }
        NSMutableDictionary *attemptBoundManual = [manualSanitized mutableCopy];
        attemptBoundManual[@"expectedConnectionAttemptId"] = JTConnectionAttemptA();
        NSDictionary *rebound = JTFreeRDPInputCommandForExecution(
            attemptBoundManual,
            currentFrame,
            JTConnectionAttemptA(),
            &error);
        JTAssert(rebound != nil && error == nil &&
                 [rebound[@"expectedStateRevision"] isEqual:@41],
                 "manual keyboard or text input was not rebound to current state");
        if ([input[@"type"] isEqualToString:@"text"]) {
            JTAssert([rebound[@"text"] isEqualToString:exactText],
                     "manual text input changed during final-state rebind");
        }
    }

    NSMutableDictionary *manualMouse =
        [JTMouseInput(observedFrameID, 40, @"click") mutableCopy];
    manualMouse[@"inputOrigin"] = @"localManual";
    manualMouse[@"coordinateSpaceWidth"] = @1920;
    manualMouse[@"coordinateSpaceHeight"] = @1080;
    NSError *error = nil;
    NSDictionary *sanitizedMouse = JTFreeRDPSanitizedInput(manualMouse, &error);
    JTAssert(sanitizedMouse != nil && error == nil,
             "manual pointer input was not sanitized");
    NSMutableDictionary *attemptBoundMouse = [sanitizedMouse mutableCopy];
    attemptBoundMouse[@"expectedConnectionAttemptId"] = JTConnectionAttemptA();
    NSDictionary *reboundMouse = JTFreeRDPInputCommandForExecution(
        attemptBoundMouse,
        currentFrame,
        JTConnectionAttemptA(),
        &error);
    JTAssert(reboundMouse != nil && error == nil &&
             [reboundMouse[@"expectedFrameId"] isEqual:currentFrameID] &&
             [reboundMouse[@"expectedStateRevision"] isEqual:@41],
             "manual pointer input was not rebound across a same-size repaint");

    NSDictionary *resizedFrame = @{
        @"frameId": NSUUID.UUID.UUIDString.lowercaseString,
        @"stateRevision": @42,
        @"connectionAttemptId": JTConnectionAttemptA(),
        @"width": @1600,
        @"height": @900,
    };
    error = nil;
    JTAssert(JTFreeRDPInputCommandForExecution(
        attemptBoundMouse,
        resizedFrame,
        JTConnectionAttemptA(),
        &error) == nil, "manual pointer input survived a framebuffer resize");
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"STATE_CONFLICT"],
             "manual pointer resize returned an unstable error");
    return 0;
}

static int JTTestAttemptBoundExecution(void)
{
    NSString *frameID = NSUUID.UUID.UUIDString.lowercaseString;
    NSMutableDictionary *replacementFrame = [JTFrame(frameID, 9) mutableCopy];
    replacementFrame[@"connectionAttemptId"] = JTConnectionAttemptB();

    NSMutableDictionary *staleInput = [JTValidInput() mutableCopy];
    staleInput[@"commandKind"] = @"input";
    staleInput[@"expectedConnectionAttemptId"] = JTConnectionAttemptA();
    NSError *error = nil;
    JTAssert(JTFreeRDPInputCommandForExecution(
        staleInput,
        replacementFrame,
        JTConnectionAttemptB(),
        &error) == nil,
        "input crossed attempts when the raw revision collided");
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"RDP_XPC_STALE_ATTEMPT"],
        "cross-attempt input did not return the stable error");

    NSMutableDictionary *manualInput = [staleInput mutableCopy];
    manualInput[@"inputOrigin"] = @"localManual";
    error = nil;
    JTAssert(JTFreeRDPInputCommandForExecution(
        manualInput,
        replacementFrame,
        JTConnectionAttemptB(),
        &error) == nil,
        "manual input rebound across RDP connection attempts");
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"RDP_XPC_STALE_ATTEMPT"],
        "cross-attempt manual input returned an unstable error");

    NSDictionary *staleResize = @{
        @"type": @"resize",
        @"width": @1920,
        @"height": @1080,
        @"commandKind": @"input",
        @"expectedConnectionAttemptId": JTConnectionAttemptA(),
    };
    error = nil;
    JTAssert(JTFreeRDPInputCommandForExecution(
        staleResize,
        @{},
        JTConnectionAttemptB(),
        &error) == nil,
        "resize crossed RDP connection attempts");

    NSDictionary *staleDVC = @{
        @"commandKind": @"dvc",
        @"message": [NSData dataWithBytes:"x" length:1],
        @"expectedConnectionAttemptId": JTConnectionAttemptA(),
        @"expectedDVCGeneration": @7,
    };
    error = JTFreeRDPConnectionAttemptValidationError(
        staleDVC,
        JTConnectionAttemptB(),
        nil);
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"RDP_XPC_STALE_ATTEMPT"],
        "Companion DVC write crossed RDP connection attempts");
    error = JTFreeRDPDVCGenerationValidationError(staleDVC, 8);
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"COMPANION_CHANNEL_CHANGED"],
        "Companion DVC write crossed channel generations");
    error = JTFreeRDPDVCGenerationValidationError(staleDVC, 7);
    JTAssert(error == nil, "current Companion channel generation was rejected");
    NSMutableDictionary *missingDVCGeneration = [staleDVC mutableCopy];
    [missingDVCGeneration removeObjectForKey:@"expectedDVCGeneration"];
    error = JTFreeRDPDVCGenerationValidationError(missingDVCGeneration, 7);
    JTAssert([error.userInfo[JTFreeRDPXPCValidationErrorCodeKey]
        isEqualToString:@"DVC_CHANNEL_GENERATION_INVALID"],
        "missing Companion channel generation returned an unstable error");

    NSMutableDictionary *currentInput = [staleInput mutableCopy];
    currentInput[@"expectedConnectionAttemptId"] = JTConnectionAttemptB();
    error = nil;
    JTAssert(JTFreeRDPInputCommandForExecution(
        currentInput,
        replacementFrame,
        JTConnectionAttemptB(),
        &error) != nil && error == nil,
        "current-attempt input was rejected");

    JTFreeRDPCommandQueue *queue = [[JTFreeRDPCommandQueue alloc]
        initWithCapacity:1
                   clock:^uint64_t { return 1000; }];
    __block NSUInteger executions = 0;
    __block NSString *completionCode = nil;
    error = nil;
    JTAssert([queue enqueueCommand:staleInput
                  requestIdentifier:NSUUID.UUID.UUIDString.lowercaseString
       deadlineUptimeMilliseconds:2000
                       queueFullCode:@"INPUT_QUEUE_FULL"
                          completion:^(NSError *completionError) {
        completionCode = completionError.userInfo[JTFreeRDPXPCValidationErrorCodeKey];
    }
                               error:&error],
        "stale-attempt input could not be queued for execution-boundary coverage");
    [queue drainWithExecutor:^NSError * _Nullable(NSDictionary *command) {
        NSError *validationError = nil;
        if (JTFreeRDPInputCommandForExecution(
                command,
                replacementFrame,
                JTConnectionAttemptB(),
                &validationError)) {
            executions += 1;
        }
        return validationError;
    }];
    JTAssert(executions == 0,
             "stale-attempt input reached the protocol mutation executor");
    JTAssert([completionCode isEqualToString:@"RDP_XPC_STALE_ATTEMPT"],
             "execution-boundary attempt rejection returned an unstable error");
    return 0;
}

static int JTTestDVCGenerationRolloverAtExecution(void)
{
    const uint64_t generationA = 7;
    // Closing A retires its generation, and opening B advances it again.
    // The exact values are intentionally distinct so a queued A command can
    // never be mistaken for a write accepted on B.
    __block uint64_t currentGeneration = generationA;
    JTFreeRDPCommandQueue *queue = [[JTFreeRDPCommandQueue alloc]
        initWithCapacity:2
                   clock:^uint64_t { return 1000; }];
    NSDictionary<NSString *, id> *generationACommand = @{
        @"commandKind": @"dvc",
        @"message": [NSData dataWithBytes:"A" length:1],
        @"expectedConnectionAttemptId": JTConnectionAttemptA(),
        @"expectedDVCGeneration": @(generationA),
    };
    NSError *error = nil;
    JTAssert(JTFreeRDPDVCGenerationValidationError(
        generationACommand,
        currentGeneration) == nil,
        "generation A DVC command was not valid before enqueue");

    __block NSUInteger generationBWriteCount = 0;
    __block NSString *staleCompletionCode = nil;
    JTAssert([queue enqueueCommand:generationACommand
                  requestIdentifier:NSUUID.UUID.UUIDString.lowercaseString
       deadlineUptimeMilliseconds:2000
                       queueFullCode:@"DVC_QUEUE_FULL"
                          completion:^(NSError *completionError) {
        staleCompletionCode =
            completionError.userInfo[JTFreeRDPXPCValidationErrorCodeKey] ?:
            completionError.userInfo[JTFreeRDPCommandQueueErrorCodeKey];
    }
                               error:&error],
        "generation A DVC command could not be queued");

    // A closes and B opens before the event loop drains the command. The
    // executor models the production boundary: attempt and helper-owned DVC
    // generation are both checked before any channel Write can be reached.
    currentGeneration = 9;
    [queue drainWithExecutor:^NSError * _Nullable(NSDictionary *command) {
        NSError *validationError = JTFreeRDPConnectionAttemptValidationError(
            command,
            JTConnectionAttemptA(),
            nil);
        if (!validationError) {
            validationError = JTFreeRDPDVCGenerationValidationError(
                command,
                currentGeneration);
        }
        if (!validationError) {
            generationBWriteCount += 1;
        }
        return validationError;
    }];
    JTAssert(generationBWriteCount == 0,
             "generation A DVC command reached generation B Write");
    JTAssert([staleCompletionCode isEqualToString:@"COMPANION_CHANNEL_CHANGED"],
             "generation rollover returned an unstable completion code");
    JTAssert(queue.pendingCount == 0,
             "generation rollover left the stale DVC command pending");

    NSDictionary<NSString *, id> *generationBCommand = @{
        @"commandKind": @"dvc",
        @"message": [NSData dataWithBytes:"B" length:1],
        @"expectedConnectionAttemptId": JTConnectionAttemptA(),
        @"expectedDVCGeneration": @(currentGeneration),
    };
    __block NSError *currentCompletionError = nil;
    error = nil;
    JTAssert([queue enqueueCommand:generationBCommand
                  requestIdentifier:NSUUID.UUID.UUIDString.lowercaseString
       deadlineUptimeMilliseconds:2000
                       queueFullCode:@"DVC_QUEUE_FULL"
                          completion:^(NSError *completionError) {
        currentCompletionError = completionError;
    }
                               error:&error],
        "generation B DVC command could not be queued");
    [queue drainWithExecutor:^NSError * _Nullable(NSDictionary *command) {
        NSError *validationError = JTFreeRDPConnectionAttemptValidationError(
            command,
            JTConnectionAttemptA(),
            nil);
        if (!validationError) {
            validationError = JTFreeRDPDVCGenerationValidationError(
                command,
                currentGeneration);
        }
        if (!validationError) {
            generationBWriteCount += 1;
        }
        return validationError;
    }];
    JTAssert(generationBWriteCount == 1 && currentCompletionError == nil,
             "current generation B DVC command did not reach Write exactly once");
    return 0;
}

typedef struct {
    uint64_t generation;
    uint8_t payload[32];
} JTTestDVCChannelCallback;

static int JTTestDeferredDVCCallbackReleaseRace(void)
{
    static const NSUInteger pointerCount = 128;
    static const NSUInteger trackingAttemptsPerPointer = 16;
    void **pointers = calloc(pointerCount, sizeof(void *));
    JTAssert(pointers != NULL, "deferred callback pointer table allocation failed");

    for (NSUInteger index = 0; index < pointerCount; index++) {
        JTTestDVCChannelCallback *callback = calloc(1, sizeof(*callback));
        JTAssert(callback != NULL, "deferred callback allocation failed");
        callback->generation = index + 1;
        pointers[index] = callback;
    }

    JTFreeRDPDeferredReleasePool *pool =
        [[JTFreeRDPDeferredReleasePool alloc] init];
    atomic_uint *successfulTracks = calloc(1, sizeof(*successfulTracks));
    JTAssert(successfulTracks != NULL,
             "deferred callback tracking counter allocation failed");
    atomic_init(successfulTracks, 0);
    dispatch_group_t trackingGroup = dispatch_group_create();
    dispatch_semaphore_t trackingStart = dispatch_semaphore_create(0);
    for (NSUInteger worker = 0; worker < trackingAttemptsPerPointer; worker++) {
        dispatch_group_async(
            trackingGroup,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            ^{
                dispatch_semaphore_wait(trackingStart, DISPATCH_TIME_FOREVER);
                for (NSUInteger index = 0; index < pointerCount; index++) {
                    if ([pool trackPointer:pointers[index]]) {
                        atomic_fetch_add_explicit(
                            successfulTracks,
                            1,
                            memory_order_relaxed);
                    }
                }
            });
    }
    for (NSUInteger worker = 0; worker < trackingAttemptsPerPointer; worker++) {
        dispatch_semaphore_signal(trackingStart);
    }
    dispatch_group_wait(trackingGroup, DISPATCH_TIME_FOREVER);

    JTAssert(atomic_load_explicit(successfulTracks, memory_order_relaxed) ==
                 pointerCount,
             "concurrent duplicate callback tracking was not idempotent");
    JTAssert(pool.trackedPointerCount == pointerCount,
             "deferred callback pool lost or duplicated a tracked pointer");

    // Model an OnData callback that resumes after OnClose: retirement must not
    // invalidate the callback until the context teardown boundary drains it.
    for (NSUInteger index = 0; index < pointerCount; index++) {
        JTTestDVCChannelCallback *callback = pointers[index];
        JTAssert(callback->generation == index + 1,
                 "retired callback was released before producer quiescence");
    }

    JTAssert([pool drainTrackedPointers] == pointerCount,
             "deferred callback drain released an unexpected pointer count");
    JTAssert(pool.trackedPointerCount == 0,
             "deferred callback drain left tracked pointers behind");
    JTAssert([pool drainTrackedPointers] == 0,
             "repeated deferred callback drain attempted a double release");
    free(successfulTracks);
    free(pointers);
    return 0;
}

static int JTTestCancelDrainRace(void)
{
    for (NSUInteger iteration = 0; iteration < 10000; iteration++) {
        uint64_t now = 10000;
        JTFreeRDPCommandQueue *queue = [[JTFreeRDPCommandQueue alloc]
            initWithCapacity:1
                       clock:^uint64_t { return now; }];
        NSString *requestID = NSUUID.UUID.UUIDString.lowercaseString;
        dispatch_semaphore_t start = dispatch_semaphore_create(0);
        dispatch_semaphore_t completed = dispatch_semaphore_create(0);
        __block atomic_bool executed = false;
        __block atomic_bool prevented = false;
        NSError *error = nil;
        BOOL accepted = [queue enqueueCommand:@{ @"commandKind": @"input" }
                             requestIdentifier:requestID
                  deadlineUptimeMilliseconds:20000
                                  queueFullCode:@"INPUT_QUEUE_FULL"
                                     completion:^(NSError *completionError) {
            (void)completionError;
            dispatch_semaphore_signal(completed);
        }
                                          error:&error];
        JTAssert(accepted && error == nil, "race command was not queued");

        dispatch_group_t group = dispatch_group_create();
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_semaphore_wait(start, DISPATCH_TIME_FOREVER);
            [queue drainWithExecutor:^NSError * _Nullable(NSDictionary *command) {
                (void)command;
                atomic_store_explicit(&executed, true, memory_order_release);
                return nil;
            }];
        });
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_semaphore_wait(start, DISPATCH_TIME_FOREVER);
            BOOL value = [queue cancelRequestIdentifier:requestID];
            atomic_store_explicit(&prevented, value, memory_order_release);
        });
        dispatch_semaphore_signal(start);
        dispatch_semaphore_signal(start);
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        dispatch_semaphore_wait(completed, DISPATCH_TIME_FOREVER);
        BOOL didExecute = atomic_load_explicit(&executed, memory_order_acquire);
        BOOL didPrevent = atomic_load_explicit(&prevented, memory_order_acquire);
        JTAssert(!(didPrevent && didExecute),
                 "successful cancellation was followed by late execution");
        JTAssert(queue.pendingCount == 0, "race left a pending command behind");
    }
    return 0;
}

int main(void)
{
    @autoreleasepool {
        if (JTTestSchemaValidation() != 0 ||
            JTTestTextClipboardBridge() != 0 ||
            JTTestQueueDeadlineCancellationAndReplay() != 0 ||
            JTTestFinalMouseFrameValidation() != 0 ||
            JTTestFinalStateValidationAndManualRebind() != 0 ||
            JTTestAttemptBoundExecution() != 0 ||
            JTTestDVCGenerationRolloverAtExecution() != 0 ||
            JTTestDeferredDVCCallbackReleaseRace() != 0 ||
            JTTestCancelDrainRace() != 0) {
            return 1;
        }
        printf("PASS: %lu XPC ingress/deadline/cancellation assertions\n",
               (unsigned long)JTAssertions);
    }
    return 0;
}
