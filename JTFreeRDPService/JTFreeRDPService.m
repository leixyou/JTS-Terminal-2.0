#import "JTFreeRDPService.h"

#import "JTFreeRDPEngine.h"
#import "JTFreeRDPXPCValidation.h"

#include <freerdp/version.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

NSString * const JTFreeRDPXPCServiceName = @"com.lljts.JTSTerminal.FreeRDPService";

static const NSUInteger JTFreeRDPMaximumDVCMessageBytes = 16 * 1024 * 1024;
static NSString * const JTCompanionInstallerFileName =
    @"JTS-Windows-Companion-Setup.exe";
static NSString * const JTCompanionInstallerDigestFileName =
    @"JTS-Windows-Companion-Setup.sha256";

static NSString *JTCompanionInstallerRemoteFileName(void)
{
    NSString *token = [[[NSUUID UUID].UUIDString
        stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    return [NSString stringWithFormat:@"JTS-Companion-%@.exe", token];
}

@interface JTCompanionInstallerArtifact : NSObject

@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, copy) NSString *sha256;
@property (nonatomic) unsigned long long fileSize;

@end

@implementation JTCompanionInstallerArtifact
@end

static NSError *JTCompanionInstallerError(NSString *code, NSString *message)
{
    return [NSError errorWithDomain:@"com.lljts.JTSTerminal.CompanionInstaller"
                               code:1
                           userInfo:@{
                               NSLocalizedDescriptionKey: message,
                               @"JTFreeRDPErrorCode": code
                           }];
}

static BOOL JTIsLowercaseSHA256(NSString *value)
{
    if (value.length != 64) {
        return NO;
    }
    NSCharacterSet *invalid = [[NSCharacterSet
        characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static JTCompanionInstallerArtifact * _Nullable
JTResolveCompanionInstallerArtifact(NSError **error)
{
    NSURL *xpcBundleURL = NSBundle.mainBundle.bundleURL.URLByStandardizingPath;
    NSURL *xpcServicesURL = xpcBundleURL.URLByDeletingLastPathComponent;
    NSURL *contentsURL = xpcServicesURL.URLByDeletingLastPathComponent;
    NSURL *resourcesURL = [[contentsURL URLByAppendingPathComponent:@"Resources"
                                                        isDirectory:YES]
        URLByStandardizingPath];
    NSURL *fileURL = [[resourcesURL URLByAppendingPathComponent:
        JTCompanionInstallerFileName isDirectory:NO] URLByStandardizingPath];
    NSURL *digestURL = [[resourcesURL URLByAppendingPathComponent:
        JTCompanionInstallerDigestFileName isDirectory:NO] URLByStandardizingPath];
    if (![fileURL.URLByDeletingLastPathComponent.path isEqualToString:resourcesURL.path] ||
        ![digestURL.URLByDeletingLastPathComponent.path isEqualToString:resourcesURL.path]) {
        if (error) {
            *error = JTCompanionInstallerError(
                @"COMPANION_INSTALLER_PATH_INVALID",
                @"The bundled Companion installer path is invalid.");
        }
        return nil;
    }

    struct stat fileStat = { 0 };
    if (lstat(fileURL.fileSystemRepresentation, &fileStat) != 0 ||
        !S_ISREG(fileStat.st_mode) || S_ISLNK(fileStat.st_mode) ||
        fileStat.st_size <= 0 || (uint64_t)fileStat.st_size > UINT32_MAX) {
        if (error) {
            *error = JTCompanionInstallerError(
                @"COMPANION_INSTALLER_UNAVAILABLE",
                @"This JTS Terminal build does not contain a valid signed Windows Companion installer.");
        }
        return nil;
    }
    struct stat digestStat = { 0 };
    if (lstat(digestURL.fileSystemRepresentation, &digestStat) != 0 ||
        !S_ISREG(digestStat.st_mode) || S_ISLNK(digestStat.st_mode) ||
        digestStat.st_size <= 0 || digestStat.st_size > 1024) {
        if (error) {
            *error = JTCompanionInstallerError(
                @"COMPANION_INSTALLER_MANIFEST_MISSING",
                @"The Companion installer integrity manifest is missing.");
        }
        return nil;
    }

    NSData *manifestData = [NSData dataWithContentsOfURL:digestURL
                                                 options:NSDataReadingMappedIfSafe
                                                   error:error];
    NSString *manifest = manifestData
        ? [[NSString alloc] initWithData:manifestData encoding:NSASCIIStringEncoding]
        : nil;
    NSArray<NSString *> *parts = [manifest componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) {
            [tokens addObject:part];
        }
    }
    NSString *digest = tokens.count > 0 ? tokens[0].lowercaseString : nil;
    NSString *manifestFileName = tokens.count > 1 ? tokens[1] : nil;
    if (!JTIsLowercaseSHA256(digest) ||
        (manifestFileName.length > 0 &&
         ![manifestFileName isEqualToString:JTCompanionInstallerFileName])) {
        if (error) {
            *error = JTCompanionInstallerError(
                @"COMPANION_INSTALLER_MANIFEST_INVALID",
                @"The Companion installer integrity manifest is invalid.");
        }
        return nil;
    }

    JTCompanionInstallerArtifact *artifact =
        [[JTCompanionInstallerArtifact alloc] init];
    artifact.fileURL = fileURL;
    artifact.sha256 = digest;
    artifact.fileSize = (unsigned long long)fileStat.st_size;
    return artifact;
}

static NSDictionary<NSString *, id> *JTFreeRDPFailureResult(
    NSError *error,
    NSString *fallbackCode,
    NSString *fallbackMessage)
{
    return @{
        @"ok": @NO,
        @"code": error.userInfo[JTFreeRDPXPCValidationErrorCodeKey] ?:
            error.userInfo[@"JTFreeRDPErrorCode"] ?: fallbackCode,
        @"message": error.localizedDescription ?: fallbackMessage
    };
}

@interface JTFreeRDPService () <JTFreeRDPEngineDelegate>

@property (nonatomic, strong) NSXPCConnection *connection;
@property (nonatomic, strong) JTFreeRDPEngine *engine;
@property (nonatomic) uint64_t connectionGeneration;
@property (nonatomic, copy) NSString *connectionAttemptIdentifier;

@end


@implementation JTFreeRDPService

- (instancetype)initWithConnection:(NSXPCConnection *)connection
{
    self = [super init];
    if (self) {
        _connection = connection;
        _engine = [[JTFreeRDPEngine alloc] init];
        _engine.delegate = self;
        _connectionAttemptIdentifier = @"";
    }
    return self;
}

- (void)connectWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                           reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    [self performConnectWithConfiguration:configuration relaySocket:nil reply:reply];
}

- (void)connectWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                    relaySocket:(NSFileHandle *)relaySocket
                          reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    if (!relaySocket) {
        reply(@{@"ok": @NO, @"code": @"RDP_RELAY_SOCKET_INVALID",
                @"message": @"The authenticated relay stream is missing."});
        return;
    }
    [self performConnectWithConfiguration:configuration relaySocket:relaySocket reply:reply];
}

- (void)performConnectWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                            relaySocket:(NSFileHandle * _Nullable)relaySocket
                                  reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    NSError *error = nil;
    NSDictionary<NSString *, id> *sanitized =
        JTFreeRDPSanitizedConfiguration(configuration, &error);
    if (!sanitized) {
        reply(JTFreeRDPFailureResult(
            error, @"INVALID_CONFIGURATION", @"The RDP configuration was rejected."));
        return;
    }
    uint64_t generation = [sanitized[@"connectionGeneration"] unsignedLongLongValue];
    NSString *attemptIdentifier = sanitized[@"connectionAttemptId"];
    BOOL accepted = [self.engine startWithConfiguration:sanitized relaySocket:relaySocket error:&error];
    if (!accepted) {
        reply(JTFreeRDPFailureResult(
            error, @"INVALID_CONFIGURATION", @"The RDP configuration was rejected."));
        return;
    }
    self.connectionGeneration = generation;
    self.connectionAttemptIdentifier = attemptIdentifier;

    reply(@{
        @"ok": @YES,
        @"sessionId": sanitized[@"sessionId"] ?: @"",
        @"connectionAttemptId": attemptIdentifier
    });
}

- (void)disconnectWithReply:(void (^)(void))reply
{
    [self.engine disconnect];
    reply();
}

- (void)sendInput:(NSDictionary<NSString *, id> *)input
           request:(NSDictionary<NSString *, id> *)request
             reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    NSError *error = nil;
    NSDictionary<NSString *, id> *sanitized = JTFreeRDPSanitizedInput(input, &error);
    JTFreeRDPXPCRequestEnvelope *envelope = sanitized
        ? [JTFreeRDPXPCRequestEnvelope envelopeFromDictionary:request
                                           expectedGeneration:self.connectionGeneration
                                  expectedAttemptIdentifier:self.connectionAttemptIdentifier
                                          currentUptimeMillis:JTFreeRDPCurrentUptimeMilliseconds()
                                                        error:&error]
        : nil;
    if (!sanitized || !envelope) {
        reply(JTFreeRDPFailureResult(
            error, @"INPUT_REJECTED", @"The input event was rejected."));
        return;
    }
    BOOL accepted = [self.engine enqueueInput:sanitized
                                       request:envelope
                                    completion:^(NSError *executionError) {
        reply(executionError
            ? JTFreeRDPFailureResult(executionError, @"INPUT_REJECTED",
                                     @"The input event did not execute.")
            : @{ @"ok": @YES });
    }
                                         error:&error];
    if (!accepted) {
        reply(JTFreeRDPFailureResult(
            error, @"INPUT_REJECTED", @"The input event was rejected."));
    }
}

- (void)sendDVCMessage:(NSData *)message
                 request:(NSDictionary<NSString *, id> *)request
 expectedChannelGeneration:(uint64_t)expectedChannelGeneration
                  reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    if (message.length == 0 || message.length > JTFreeRDPMaximumDVCMessageBytes) {
        reply(@{
            @"ok": @NO,
            @"code": @"DVC_MESSAGE_SIZE_INVALID",
            @"message": @"DVC messages must be between 1 byte and 16 MiB."
        });
        return;
    }

    NSError *error = nil;
    JTFreeRDPXPCRequestEnvelope *envelope =
        [JTFreeRDPXPCRequestEnvelope envelopeFromDictionary:request
                                         expectedGeneration:self.connectionGeneration
                                expectedAttemptIdentifier:self.connectionAttemptIdentifier
                                        currentUptimeMillis:JTFreeRDPCurrentUptimeMilliseconds()
                                                      error:&error];
    if (!envelope) {
        reply(JTFreeRDPFailureResult(
            error, @"DVC_MESSAGE_REJECTED", @"The Companion DVC request was rejected."));
        return;
    }
    BOOL accepted = [self.engine enqueueDVCMessage:message
                                            request:envelope
                         expectedChannelGeneration:expectedChannelGeneration
                                         completion:^(NSError *executionError) {
        reply(executionError
            ? JTFreeRDPFailureResult(executionError, @"COMPANION_REQUIRED",
                                     @"The Windows Companion DVC request did not execute.")
            : @{ @"ok": @YES });
    }
                                              error:&error];
    if (!accepted) {
        reply(JTFreeRDPFailureResult(
            error, @"COMPANION_REQUIRED", @"The Windows Companion DVC is not connected."));
    }
}

- (void)updateClipboardText:(NSData * _Nullable)text
                    request:(NSDictionary<NSString *, id> *)request
                      reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    NSError *error = nil;
    BOOL textIsValid = JTFreeRDPValidateClipboardText(text, &error);
    JTFreeRDPXPCRequestEnvelope *envelope = textIsValid
        ? [JTFreeRDPXPCRequestEnvelope
            envelopeFromDictionary:request
                expectedGeneration:self.connectionGeneration
       expectedAttemptIdentifier:self.connectionAttemptIdentifier
               currentUptimeMillis:JTFreeRDPCurrentUptimeMilliseconds()
                             error:&error]
        : nil;
    if (!textIsValid || !envelope) {
        reply(JTFreeRDPFailureResult(
            error,
            @"RDP_CLIPBOARD_TEXT_INVALID",
            @"The clipboard update was rejected."));
        return;
    }
    BOOL accepted = [self.engine
        enqueueClipboardText:text ? [text copy] : nil
                      request:envelope
                   completion:^(NSError *executionError) {
        reply(executionError
            ? JTFreeRDPFailureResult(
                executionError,
                @"RDP_CLIPBOARD_UPDATE_FAILED",
                @"The clipboard update did not execute.")
            : @{ @"ok": @YES });
    }
                        error:&error];
    if (!accepted) {
        reply(JTFreeRDPFailureResult(
            error,
            @"RDP_CLIPBOARD_UPDATE_FAILED",
            @"The clipboard update was rejected."));
    }
}

- (void)setClipboardIsolation:(BOOL)isolated
                         text:(NSData * _Nullable)text
                      request:(NSDictionary<NSString *, id> *)request
                        reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    NSError *error = nil;
    BOOL textIsValid = JTFreeRDPValidateClipboardText(text, &error);
    JTFreeRDPXPCRequestEnvelope *envelope = textIsValid
        ? [JTFreeRDPXPCRequestEnvelope
            envelopeFromDictionary:request
                expectedGeneration:self.connectionGeneration
       expectedAttemptIdentifier:self.connectionAttemptIdentifier
               currentUptimeMillis:JTFreeRDPCurrentUptimeMilliseconds()
                             error:&error]
        : nil;
    if (!textIsValid || !envelope || (isolated && text != nil)) {
        reply(JTFreeRDPFailureResult(
            error,
            @"RDP_CLIPBOARD_ISOLATION_INVALID",
            @"The clipboard isolation request was rejected."));
        return;
    }
    BOOL accepted = [self.engine
        enqueueClipboardIsolation:isolated
                             text:text ? [text copy] : nil
                          request:envelope
                       completion:^(NSError *executionError) {
        reply(executionError
            ? JTFreeRDPFailureResult(
                executionError,
                @"RDP_CLIPBOARD_ISOLATION_FAILED",
                @"Windows did not acknowledge the clipboard isolation boundary.")
            : @{ @"ok": @YES });
    }
                            error:&error];
    if (!accepted) {
        reply(JTFreeRDPFailureResult(
            error,
            @"RDP_CLIPBOARD_ISOLATION_FAILED",
            @"The clipboard isolation request was rejected."));
    }
}

- (void)offerCompanionInstallerWithRequest:(NSDictionary<NSString *, id> *)request
                                      reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    NSError *error = nil;
    JTCompanionInstallerArtifact *artifact =
        JTResolveCompanionInstallerArtifact(&error);
    JTFreeRDPXPCRequestEnvelope *envelope = artifact
        ? [JTFreeRDPXPCRequestEnvelope
            envelopeFromDictionary:request
                expectedGeneration:self.connectionGeneration
       expectedAttemptIdentifier:self.connectionAttemptIdentifier
               currentUptimeMillis:JTFreeRDPCurrentUptimeMilliseconds()
                             error:&error]
        : nil;
    if (!artifact || !envelope) {
        reply(JTFreeRDPFailureResult(
            error,
            @"COMPANION_INSTALLER_UNAVAILABLE",
            @"The bundled Windows Companion installer is unavailable."));
        return;
    }
    // A unique Windows basename prevents a stale interrupted installation from
    // racing or prompting over the next clipboard paste in %TEMP%.
    NSString *remoteFileName = JTCompanionInstallerRemoteFileName();
    BOOL accepted = [self.engine
        enqueueCompanionInstallerOfferAtURL:artifact.fileURL
                             remoteFileName:remoteFileName
                             expectedSHA256:artifact.sha256
                                    request:envelope
                                 completion:^(NSError *executionError) {
        reply(executionError
            ? JTFreeRDPFailureResult(
                executionError,
                @"COMPANION_INSTALLER_OFFER_FAILED",
                @"Windows did not accept the Companion installer transfer.")
            : @{
                @"ok": @YES,
                @"fileName": remoteFileName,
                @"fileSize": @(artifact.fileSize),
                @"sha256": artifact.sha256,
                @"connectionAttemptId": self.connectionAttemptIdentifier ?: @""
            });
    }
                                      error:&error];
    if (!accepted) {
        reply(JTFreeRDPFailureResult(
            error,
            @"COMPANION_INSTALLER_OFFER_FAILED",
            @"The Companion installer transfer was rejected."));
    }
}

- (void)clearCompanionInstallerWithRequest:(NSDictionary<NSString *, id> *)request
                                      reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    NSError *error = nil;
    JTFreeRDPXPCRequestEnvelope *envelope =
        [JTFreeRDPXPCRequestEnvelope
            envelopeFromDictionary:request
                expectedGeneration:self.connectionGeneration
       expectedAttemptIdentifier:self.connectionAttemptIdentifier
               currentUptimeMillis:JTFreeRDPCurrentUptimeMilliseconds()
                             error:&error];
    if (!envelope) {
        reply(JTFreeRDPFailureResult(
            error,
            @"COMPANION_INSTALLER_CLEAR_FAILED",
            @"The Companion installer transfer could not be cleared."));
        return;
    }
    BOOL accepted = [self.engine
        enqueueCompanionInstallerClearWithRequest:envelope
                                      completion:^(NSError *executionError) {
        reply(executionError
            ? JTFreeRDPFailureResult(
                executionError,
                @"COMPANION_INSTALLER_CLEAR_FAILED",
                @"Windows did not acknowledge removal of the Companion installer transfer.")
            : @{ @"ok": @YES });
    }
                                           error:&error];
    if (!accepted) {
        reply(JTFreeRDPFailureResult(
            error,
            @"COMPANION_INSTALLER_CLEAR_FAILED",
            @"The Companion installer transfer could not be cleared."));
    }
}

- (void)cancelRequest:(NSDictionary<NSString *, id> *)cancellation
                 reply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    NSError *error = nil;
    NSDictionary<NSString *, id> *sanitized = JTFreeRDPSanitizedCancellation(
        cancellation,
        self.connectionGeneration,
        self.connectionAttemptIdentifier,
        &error);
    if (!sanitized) {
        reply(JTFreeRDPFailureResult(
            error, @"XPC_REQUEST_ENVELOPE_INVALID", @"The cancellation request was rejected."));
        return;
    }
    BOOL prevented = [self.engine cancelRequestIdentifier:sanitized[@"requestId"]];
    reply(@{
        @"ok": @YES,
        @"executionPrevented": @(prevented)
    });
}

- (void)copyFrameWithReply:(void (^)(NSData * _Nullable,
                                     NSDictionary<NSString *, id> *))reply
{
    [self.engine copyFrameWithReply:reply];
}

- (void)pingWithReply:(void (^)(NSDictionary<NSString *, id> *))reply
{
    NSMutableDictionary<NSString *, id> *result = [@{
        @"ok": @YES,
        @"runtime": @"FreeRDP",
        @"version": [NSString stringWithUTF8String:FREERDP_VERSION],
        @"running": @(self.engine.isRunning)
    } mutableCopy];
#if DEBUG
    result[@"helperPID"] = @(getpid());
#endif
    reply(result);
}

#if DEBUG
- (void)crashForTestingWithReply:(void (^)(void))reply
{
    (void)reply;
    abort();
}
#endif

- (id<JTFreeRDPClientProtocol>)clientProxy
{
    return [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        (void)error;
    }];
}

- (void)rdpEngineDidChangeState:(NSDictionary<NSString *, id> *)state
{
    [[self clientProxy] desktopDidChangeState:state];
}

- (void)rdpEngineDidUpdateSurface:(IOSurface *)surface
                         metadata:(NSDictionary<NSString *, id> *)metadata
{
    [[self clientProxy] desktopDidUpdateSurface:surface metadata:metadata];
}

- (void)rdpEngineDidReceiveDVCMessage:(NSData *)message
                             metadata:(NSDictionary<NSString *, id> *)metadata
{
    [[self clientProxy] desktopDidReceiveDVCMessage:message metadata:metadata];
}

- (void)rdpEngineDidReceiveClipboardText:(NSData *)text
                                metadata:(NSDictionary<NSString *, id> *)metadata
{
    [[self clientProxy] desktopDidReceiveClipboardText:text metadata:metadata];
}

- (void)rdpEngineDidRequireCertificateDecision:(NSDictionary<NSString *, id> *)certificate
{
    [[self clientProxy] desktopDidRequireCertificateDecision:certificate];
}

@end
