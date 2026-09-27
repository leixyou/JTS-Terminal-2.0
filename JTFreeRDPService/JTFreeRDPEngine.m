// CoreFoundation's legacy COM aliases collide with WinPR's Windows-compatible
// REFIID declarations. FreeRDP uses the same guard in its macOS channel code.
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

#import "JTFreeRDPEngine.h"
#import "JTFreeRDPCommandQueue.h"
#import "JTFreeRDPDeferredReleasePool.h"
#import "JTFreeRDPSafety.h"
#import "JTFreeRDPTextClipboardBridge.h"
#import "JTFreeRDPXPCValidation.h"
#import "JTFreeRDPRelayTransport.h"

#import <CommonCrypto/CommonDigest.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#if DEBUG
#import <os/log.h>
#endif

#include <freerdp/addin.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/codec/color.h>
#include <freerdp/constants.h>
#include <freerdp/dvc.h>
#include <freerdp/error.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/transport_io.h>
#include <freerdp/version.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <string.h>

static NSString * const JTFreeRDPEngineErrorDomain = @"com.lljts.JTSTerminal.FreeRDPEngine";
static NSString * const JTCompanionDVCAddinName = @"jtscompanion";
static const char *JTCompanionDVCChannelName = "JTS.Companion.v1";
static const NSUInteger JTMaximumFramebufferBytes = 256 * 1024 * 1024;
static const NSUInteger JTMaximumDVCMessageBytes = 16 * 1024 * 1024;
static const NSUInteger JTMaximumCertificateChainBytes = 4 * 1024 * 1024;
static const NSUInteger JTMaximumQueuedCommands = 4096;
static NSString * const JTFreeRDPErrorCodeKey = @"JTFreeRDPErrorCode";

static NSString *JTLeafCertificateSHA256FromPEM(const BYTE *data, size_t length)
{
    if (!data || length == 0 || length > JTMaximumCertificateChainBytes) {
        return nil;
    }

    NSString *pem = [[NSString alloc] initWithBytes:data
                                             length:length
                                           encoding:NSASCIIStringEncoding];
    if (!pem) {
        return nil;
    }

    static NSString * const beginMarker = @"-----BEGIN CERTIFICATE-----";
    static NSString * const endMarker = @"-----END CERTIFICATE-----";
    NSRange begin = [pem rangeOfString:beginMarker];
    if (begin.location == NSNotFound) {
        return nil;
    }
    NSUInteger bodyStart = NSMaxRange(begin);
    NSRange remainder = NSMakeRange(bodyStart, pem.length - bodyStart);
    NSRange end = [pem rangeOfString:endMarker options:0 range:remainder];
    if (end.location == NSNotFound || end.location <= bodyStart) {
        return nil;
    }

    NSString *base64 = [pem substringWithRange:NSMakeRange(bodyStart, end.location - bodyStart)];
    NSData *certificateDER = [[NSData alloc]
        initWithBase64EncodedString:base64
                           options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!certificateDER || certificateDER.length == 0 || certificateDER.length > UINT32_MAX) {
        return nil;
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = { 0 };
    if (!CC_SHA256(certificateDER.bytes, (CC_LONG)certificateDER.length, digest)) {
        return nil;
    }

    NSMutableString *fingerprint = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        [fingerprint appendFormat:@"%02X", digest[index]];
    }
    return fingerprint;
}

#if DEBUG
static os_log_t JTCompanionDVCLog(void)
{
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.lljts.JTSTerminal.CompanionDVC", "transport");
    });
    return log;
}

// Numeric transport metadata only. Never log frame bytes, request identifiers,
// device identities, or decoded protocol fields, even in diagnostic builds.
static void JTLogCompanionDVCStream(size_t total, size_t position, size_t remaining)
{
    os_log_debug(JTCompanionDVCLog(),
                 "inbound stream total=%{public}zu position=%{public}zu remaining=%{public}zu",
                 total, position, remaining);
}

static void JTLogCompanionDVCDispatch(size_t length,
                                    uint64_t callbackGeneration,
                                    uint64_t currentGeneration,
                                    BOOL forwarded)
{
    os_log_debug(JTCompanionDVCLog(),
                 "inbound dispatch bytes=%{public}zu callbackGeneration=%{public}llu currentGeneration=%{public}llu forwarded=%{public}d",
                 length, (unsigned long long)callbackGeneration,
                 (unsigned long long)currentGeneration, (int)forwarded);
}

static void JTEnableScopedFreeRDPDiagnostics(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        wLog *root = WLog_GetRoot();
        if (!root) {
            return;
        }
        // Keep authentication payloads out of diagnostics. Only the protocol
        // negotiation, connection-state, and transport modules are raised to
        // DEBUG; NLA remains WARN-only.
        WLog_SetLogLevel(root, WLOG_ERROR);
        WLog_SetLogAppenderType(root, WLOG_APPENDER_SYSLOG);
        WLog_AddStringLogFilters(
            "com.freerdp.core.transport:DEBUG,"
            "com.freerdp.core.connection:DEBUG,"
            "com.freerdp.core.nego:DEBUG,"
            "com.freerdp.core.nla:WARN");
    });
}
#endif

static NSError *JTFreeRDPError(NSInteger code, NSString *machineCode, NSString *message)
{
    return [NSError errorWithDomain:JTFreeRDPEngineErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey: message,
                               JTFreeRDPErrorCodeKey: machineCode
                           }];
}

static uint64_t JTNextDVCGeneration(uint64_t current)
{
    return current == UINT64_MAX ? 1 : current + 1;
}

static NSLock *JTFreeRDPAddinSetupLock(void)
{
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

typedef struct {
    rdpClientContext context;
    void *engine;
} JTFreeRDPContext;

typedef struct {
    GENERIC_DYNVC_PLUGIN base;
    void *engine;
} JTCompanionDVCPlugin;

typedef struct {
    GENERIC_CHANNEL_CALLBACK base;
    uint64_t generation;
} JTCompanionDVCChannelCallback;

typedef struct {
    freerdp *instance;
    IOSurfaceRef surface;
    IWTSVirtualChannel *dvcChannel;
    uint64_t dvcGeneration;
    DispClientContext *displayControl;
    uint64_t stateRevision;
    BOOL connected;
    BOOL gdiInitialized;
} JTFreeRDPEngineState;

@interface JTFreeRDPPendingClipboardAcknowledgement : NSObject

@property (nonatomic, copy) JTFreeRDPEngineCommandCompletion completion;
@property (nonatomic, nullable) NSNumber *isolationState;

@end

@implementation JTFreeRDPPendingClipboardAcknowledgement
@end

@interface JTFreeRDPEngine () <JTFreeRDPTextClipboardBridgeDelegate>

@property (nonatomic, assign) JTFreeRDPEngineState *engineState;
@property (nonatomic, strong) dispatch_queue_t workerQueue;
@property (nonatomic, strong) dispatch_queue_t frameCopyQueue;
@property (nonatomic, strong) JTFreeRDPCommandQueue *commandQueue;
@property (nonatomic, strong) JTFreeRDPDeferredReleasePool *dvcCallbackReleasePool;
@property (nonatomic, strong) JTFreeRDPTextClipboardBridge *clipboardBridge;
@property (nonatomic, strong) NSLock *clipboardAcknowledgementLock;
@property (nonatomic, strong)
    NSMutableDictionary<NSString *, JTFreeRDPPendingClipboardAcknowledgement *>
        *pendingClipboardAcknowledgements;
@property (atomic) uint64_t clipboardIsolationGeneration;
@property (nonatomic, strong) NSLock *stateLock;
@property (nonatomic, strong) NSRecursiveLock *dvcChannelLock;
@property (atomic, readwrite, getter=isRunning) BOOL running;
@property (atomic) BOOL disconnectRequested;
@property (atomic) BOOL preConnectCompleted;
@property (atomic, copy, nullable) NSString *preConnectFailureCode;
@property (atomic, copy, nullable) NSString *preConnectFailureMessage;
@property (nonatomic, copy) NSString *sessionID;
@property (atomic, copy) NSString *connectionAttemptIdentifier;
@property (nonatomic, copy, nullable) NSString *pinnedFingerprint;
@property (nonatomic, copy, nullable) NSString *trustOnceFingerprint;
@property (nonatomic, copy) NSDictionary<NSString *, id> *latestFrameMetadata;
@property (nonatomic, strong, nullable) NSFileHandle *relaySocket;
@property (nonatomic) BOOL usesRelayTransport;
- (int)takeRelaySocketDescriptor;

- (BOOL)createSurfaceForContext:(rdpContext *)context;
- (BOOL)handleBeginPaint:(rdpContext *)context;
- (BOOL)handleEndPaint:(rdpContext *)context;
- (BOOL)handleDesktopResize:(rdpContext *)context;
- (nullable NSError *)sendInputCommand:(NSDictionary<NSString *, id> *)command
                               context:(rdpContext *)context;
- (nullable NSError *)sendResizeCommand:(NSDictionary<NSString *, id> *)command;
- (nullable NSError *)sendClipboardCommand:(NSDictionary<NSString *, id> *)command;
- (BOOL)registerClipboardAcknowledgement:
    (JTFreeRDPEngineCommandCompletion)completion
                    requestIdentifier:(NSString *)requestIdentifier
                       isolationState:(nullable NSNumber *)isolationState;
- (BOOL)completeClipboardAcknowledgement:(NSString *)requestIdentifier
                                   error:(nullable NSError *)error;
- (BOOL)discardClipboardAcknowledgement:(NSString *)requestIdentifier;
- (void)failAllClipboardAcknowledgementsWithCode:(NSString *)code
                                         message:(NSString *)message;
- (void)clearSurface;
- (BOOL)isDVCChannelConnected;
- (void)clearDVCChannel;
- (nullable NSError *)writeDVCMessage:(NSData *)message
                   expectedGeneration:(uint64_t)expectedGeneration;
- (BOOL)handleDVCOpenCallback:(JTCompanionDVCChannelCallback *)callback;
- (void)handleDVCCloseAndRetireCallback:(JTCompanionDVCChannelCallback *)callback;
- (void)handleDVCData:(const BYTE *)bytes
               length:(size_t)length
             callback:(JTCompanionDVCChannelCallback *)callback;
- (void)handleChannelConnected:(const ChannelConnectedEventArgs *)event;
- (void)handleChannelDisconnected:(const ChannelDisconnectedEventArgs *)event;
- (nullable NSString *)certificateFingerprintFromCString:(const char * _Nullable)fingerprint
                                                    flags:(DWORD)flags;
- (void)notifyState:(NSString *)phase
               code:(nullable NSString *)code
            message:(nullable NSString *)message;
- (void)notifyState:(NSString *)phase
               code:(nullable NSString *)code
            message:(nullable NSString *)message
        certificate:(nullable NSDictionary<NSString *, id> *)certificate;
- (DWORD)verifyCertificateForHost:(const char *)host
                             port:(UINT16)port
                       commonName:(const char *)commonName
                          subject:(const char *)subject
                           issuer:(const char *)issuer
                      fingerprint:(const char *)fingerprint
                            flags:(DWORD)flags
                          changed:(BOOL)changed
                   oldFingerprint:(const char * _Nullable)oldFingerprint;
- (int)verifyPinnedCertificatePEM:(const BYTE *)data
                           length:(size_t)length
                         hostname:(const char *)hostname
                             port:(UINT16)port
                            flags:(DWORD)flags;

@end

static JTFreeRDPEngine *JTEngineFromContext(rdpContext *context)
{
    if (!context) {
        return nil;
    }
    JTFreeRDPContext *jtsContext = (JTFreeRDPContext *)context;
    return (__bridge JTFreeRDPEngine *)jtsContext->engine;
}

static int JTRelayTCPConnect(rdpContext *context, __unused rdpSettings *settings,
                             __unused const char *hostname, __unused int port,
                             __unused DWORD timeout)
{
    // One attempt owns one authenticated lane. A retry/redirect must obtain a
    // fresh lane from the application; it must never dial the profile address.
    JTFreeRDPEngine *engine = JTEngineFromContext(context);
    return engine ? [engine takeRelaySocketDescriptor] : -1;
}

static BOOL JTRecordConnectionSetupFailure(
    freerdp *instance,
    NSString *code,
    NSString *message)
{
    JTFreeRDPEngine *engine = JTEngineFromContext(instance ? instance->context : NULL);
    engine.preConnectCompleted = NO;
    engine.preConnectFailureCode = code;
    engine.preConnectFailureMessage = message;
    return FALSE;
}

static BOOL JTBeginPaint(rdpContext *context)
{
    return [JTEngineFromContext(context) handleBeginPaint:context];
}

static BOOL JTEndPaint(rdpContext *context)
{
    return [JTEngineFromContext(context) handleEndPaint:context];
}

static BOOL JTDesktopResize(rdpContext *context)
{
    return [JTEngineFromContext(context) handleDesktopResize:context];
}

static void JTChannelConnected(void *context, const ChannelConnectedEventArgs *event)
{
    [JTEngineFromContext((rdpContext *)context) handleChannelConnected:event];
    freerdp_client_OnChannelConnectedEventHandler(context, event);
}

static void JTChannelDisconnected(void *context, const ChannelDisconnectedEventArgs *event)
{
    [JTEngineFromContext((rdpContext *)context) handleChannelDisconnected:event];
    freerdp_client_OnChannelDisconnectedEventHandler(context, event);
}

static DWORD JTVerifyCertificate(
    freerdp *instance,
    const char *host,
    UINT16 port,
    const char *commonName,
    const char *subject,
    const char *issuer,
    const char *fingerprint,
    DWORD flags)
{
    return [JTEngineFromContext(instance ? instance->context : NULL)
        verifyCertificateForHost:host
                             port:port
                       commonName:commonName
                          subject:subject
                           issuer:issuer
                      fingerprint:fingerprint
                            flags:flags
                          changed:NO
                   oldFingerprint:NULL];
}

static DWORD JTVerifyChangedCertificate(
    freerdp *instance,
    const char *host,
    UINT16 port,
    const char *commonName,
    const char *subject,
    const char *issuer,
    const char *newFingerprint,
    const char *oldSubject,
    const char *oldIssuer,
    const char *oldFingerprint,
    DWORD flags)
{
    (void)oldSubject;
    (void)oldIssuer;
    return [JTEngineFromContext(instance ? instance->context : NULL)
        verifyCertificateForHost:host
                             port:port
                       commonName:commonName
                          subject:subject
                           issuer:issuer
                      fingerprint:newFingerprint
                            flags:flags
                          changed:YES
                   oldFingerprint:oldFingerprint];
}

static int JTVerifyX509Certificate(
    freerdp *instance,
    const BYTE *data,
    size_t length,
    const char *hostname,
    UINT16 port,
    DWORD flags)
{
    return [JTEngineFromContext(instance ? instance->context : NULL)
        verifyPinnedCertificatePEM:data
                           length:length
                         hostname:hostname
                             port:port
                            flags:flags];
}

static UINT JTCompanionDVCOnData(IWTSVirtualChannelCallback *channelCallback, wStream *stream)
{
    JTCompanionDVCChannelCallback *callback =
        (JTCompanionDVCChannelCallback *)channelCallback;
    JTCompanionDVCPlugin *plugin = callback
        ? (JTCompanionDVCPlugin *)callback->base.plugin : NULL;
    if (!plugin || !stream) {
        return ERROR_INVALID_PARAMETER;
    }

    size_t length = Stream_GetRemainingLength(stream);
#if DEBUG
    JTLogCompanionDVCStream(Stream_Length(stream), Stream_GetPosition(stream), length);
#endif
    if (length > JTMaximumDVCMessageBytes) {
        return ERROR_INSUFFICIENT_BUFFER;
    }

    JTFreeRDPEngine *engine = (__bridge JTFreeRDPEngine *)plugin->engine;
    [engine handleDVCData:Stream_ConstPointer(stream)
                   length:length
                 callback:callback];
    return CHANNEL_RC_OK;
}

static UINT JTCompanionDVCOnOpen(IWTSVirtualChannelCallback *channelCallback)
{
    JTCompanionDVCChannelCallback *callback =
        (JTCompanionDVCChannelCallback *)channelCallback;
    JTCompanionDVCPlugin *plugin = callback
        ? (JTCompanionDVCPlugin *)callback->base.plugin : NULL;
    if (!callback || !plugin || !plugin->engine) {
        return ERROR_INVALID_PARAMETER;
    }

    JTFreeRDPEngine *engine = (__bridge JTFreeRDPEngine *)plugin->engine;
    return [engine handleDVCOpenCallback:callback]
        ? CHANNEL_RC_OK
        : ERROR_INVALID_PARAMETER;
}

static UINT JTCompanionDVCOnClose(IWTSVirtualChannelCallback *channelCallback)
{
    JTCompanionDVCChannelCallback *callback =
        (JTCompanionDVCChannelCallback *)channelCallback;
    JTCompanionDVCPlugin *plugin = callback
        ? (JTCompanionDVCPlugin *)callback->base.plugin : NULL;
    if (!callback || !plugin || !plugin->engine) {
        // Without the owning engine we cannot prove that freeing this callback
        // is serialized with an in-flight Write. Prefer a bounded orphan over
        // an uncoordinated release on this invalid FreeRDP callback path.
        return ERROR_INVALID_PARAMETER;
    }

    JTFreeRDPEngine *engine = (__bridge JTFreeRDPEngine *)plugin->engine;
    [engine handleDVCCloseAndRetireCallback:callback];
    return CHANNEL_RC_OK;
}

static const IWTSVirtualChannelCallback JTCompanionDVCCallbacks = {
    JTCompanionDVCOnData,
    JTCompanionDVCOnOpen,
    JTCompanionDVCOnClose,
    NULL
};

static UINT JTCompanionDVCInitialize(
    GENERIC_DYNVC_PLUGIN *genericPlugin,
    rdpContext *context,
    rdpSettings *settings)
{
    (void)settings;
    JTCompanionDVCPlugin *plugin = (JTCompanionDVCPlugin *)genericPlugin;
    JTFreeRDPContext *jtsContext = (JTFreeRDPContext *)context;
    plugin->engine = jtsContext ? jtsContext->engine : NULL;
    return plugin->engine ? CHANNEL_RC_OK : ERROR_INVALID_PARAMETER;
}

static UINT VCAPITYPE JTCompanionDVCPluginEntry(IDRDYNVC_ENTRY_POINTS *entryPoints)
{
    return freerdp_generic_DVCPluginEntry(
        entryPoints,
        "com.lljts.JTSTerminal.companion",
        JTCompanionDVCChannelName,
        sizeof(JTCompanionDVCPlugin),
        sizeof(JTCompanionDVCChannelCallback),
        &JTCompanionDVCCallbacks,
        JTCompanionDVCInitialize,
        NULL);
}

static PVIRTUALCHANNELENTRY JTAddinProvider(
    LPCSTR name,
    LPCSTR subsystem,
    LPCSTR type,
    DWORD flags)
{
    if (name && strcmp(name, JTCompanionDVCAddinName.UTF8String) == 0 &&
        (flags & FREERDP_ADDIN_CHANNEL_DYNAMIC)) {
        return WINPR_FUNC_PTR_CAST(&JTCompanionDVCPluginEntry, PVIRTUALCHANNELENTRY);
    }
    return freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
}

static BOOL JTPreConnect(freerdp *instance)
{
    if (!instance || !instance->context || !instance->context->settings) {
        return JTRecordConnectionSetupFailure(
            instance,
            @"RDP_PRECONNECT_CONTEXT_INVALID",
            @"FreeRDP did not provide a valid client context before connecting.");
    }

    rdpContext *context = instance->context;
    rdpSettings *settings = context->settings;
    UINT32 width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    UINT32 height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    if (width < 640 || height < 480 || width > 7680 || height > 4320) {
        return JTRecordConnectionSetupFailure(
            instance,
            @"RDP_PRECONNECT_DIMENSIONS_INVALID",
            @"FreeRDP rejected the requested desktop dimensions before connecting.");
    }

    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH) ||
        !freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, FALSE)) {
        return JTRecordConnectionSetupFailure(
            instance,
            @"RDP_PRECONNECT_CLIENT_SETTINGS_FAILED",
            @"FreeRDP could not apply the macOS client and certificate callback settings.");
    }

    const char *channel[] = { JTCompanionDVCAddinName.UTF8String };
    if (!freerdp_client_add_dynamic_channel(settings, 1, channel)) {
        return JTRecordConnectionSetupFailure(
            instance,
            @"RDP_PRECONNECT_COMPANION_CHANNEL_FAILED",
            @"FreeRDP could not register the optional Windows Companion channel.");
    }

    if (PubSub_SubscribeChannelConnected(context->pubSub, JTChannelConnected) != CHANNEL_RC_OK) {
        return JTRecordConnectionSetupFailure(
            instance,
            @"RDP_PRECONNECT_CHANNEL_EVENTS_FAILED",
            @"FreeRDP could not subscribe to virtual-channel connection events.");
    }
    if (PubSub_SubscribeChannelDisconnected(context->pubSub, JTChannelDisconnected) != CHANNEL_RC_OK) {
        PubSub_UnsubscribeChannelConnected(context->pubSub, JTChannelConnected);
        return JTRecordConnectionSetupFailure(
            instance,
            @"RDP_PRECONNECT_CHANNEL_EVENTS_FAILED",
            @"FreeRDP could not subscribe to virtual-channel disconnection events.");
    }
    JTFreeRDPEngine *engine = JTEngineFromContext(context);
    engine.preConnectCompleted = YES;
    engine.preConnectFailureCode = nil;
    engine.preConnectFailureMessage = nil;
    return TRUE;
}

static BOOL JTLoadChannels(freerdp *instance)
{
    if (!instance || !instance->context || !instance->context->channels ||
        !instance->context->settings) {
        return JTRecordConnectionSetupFailure(
            instance,
            @"RDP_CHANNEL_CONTEXT_INVALID",
            @"FreeRDP did not provide a valid channel context while preparing the connection.");
    }
    if (!freerdp_client_load_addins(instance->context->channels, instance->context->settings)) {
        return JTRecordConnectionSetupFailure(
            instance,
            @"RDP_CHANNEL_ADDINS_FAILED",
            @"FreeRDP could not load the requested display and Companion channels.");
    }
    return TRUE;
}

static BOOL JTPostConnect(freerdp *instance)
{
    if (!instance || !instance->context || !instance->context->update) {
        return FALSE;
    }
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
        return FALSE;
    }

    JTFreeRDPEngine *engine = JTEngineFromContext(instance->context);
    engine.engineState->gdiInitialized = YES;
    instance->context->update->BeginPaint = JTBeginPaint;
    instance->context->update->EndPaint = JTEndPaint;
    instance->context->update->DesktopResize = JTDesktopResize;
    return [engine createSurfaceForContext:instance->context];
}

static BOOL JTRejectRedirect(freerdp *instance)
{
    JTFreeRDPEngine *engine = JTEngineFromContext(instance ? instance->context : NULL);
    [engine notifyState:@"failed"
                   code:@"RDP_REDIRECTION_BLOCKED"
                message:@"The RDP server attempted to redirect this direct-LAN session to another target."];
    return FALSE;
}

static void JTPostDisconnect(freerdp *instance)
{
    if (!instance || !instance->context) {
        return;
    }

    PubSub_UnsubscribeChannelConnected(instance->context->pubSub, JTChannelConnected);
    PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, JTChannelDisconnected);

    JTFreeRDPEngine *engine = JTEngineFromContext(instance->context);
    [engine.stateLock lock];
    engine.engineState->displayControl = NULL;
    engine.engineState->connected = NO;
    [engine.stateLock unlock];
    [engine clearDVCChannel];
    [engine.clipboardBridge detachCurrentContext];
    [engine clearSurface];
    if (engine.engineState->gdiInitialized) {
        gdi_free(instance);
        engine.engineState->gdiInitialized = NO;
    }
}

static BOOL JTClientNew(freerdp *instance, rdpContext *context)
{
    (void)context;
    if (!instance) {
        return FALSE;
    }
    instance->PreConnect = JTPreConnect;
    instance->LoadChannels = JTLoadChannels;
    instance->PostConnect = JTPostConnect;
    instance->PostDisconnect = JTPostDisconnect;
    instance->VerifyCertificateEx = JTVerifyCertificate;
    instance->VerifyChangedCertificateEx = JTVerifyChangedCertificate;
    instance->VerifyX509Certificate = JTVerifyX509Certificate;
    instance->Redirect = JTRejectRedirect;
    return TRUE;
}

static void JTClientFree(freerdp *instance, rdpContext *context)
{
    (void)instance;
    (void)context;
}

static void JTConfigureEntryPoints(RDP_CLIENT_ENTRY_POINTS *entryPoints)
{
    ZeroMemory(entryPoints, sizeof(*entryPoints));
    entryPoints->Version = RDP_CLIENT_INTERFACE_VERSION;
    entryPoints->Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    entryPoints->ContextSize = sizeof(JTFreeRDPContext);
    entryPoints->ClientNew = JTClientNew;
    entryPoints->ClientFree = JTClientFree;
}

@implementation JTFreeRDPEngine

- (instancetype)init
{
    self = [super init];
    if (self) {
        _engineState = calloc(1, sizeof(JTFreeRDPEngineState));
        if (!_engineState) {
            return nil;
        }
        _workerQueue = dispatch_queue_create("com.lljts.JTSTerminal.FreeRDP.worker", DISPATCH_QUEUE_SERIAL);
        _frameCopyQueue = dispatch_queue_create("com.lljts.JTSTerminal.FreeRDP.frame-copy", DISPATCH_QUEUE_SERIAL);
        _commandQueue = [[JTFreeRDPCommandQueue alloc] initWithCapacity:JTMaximumQueuedCommands];
        _dvcCallbackReleasePool = [[JTFreeRDPDeferredReleasePool alloc] init];
        _clipboardBridge = [[JTFreeRDPTextClipboardBridge alloc] initWithEnabled:NO];
        _clipboardBridge.delegate = self;
        _clipboardAcknowledgementLock = [[NSLock alloc] init];
        _pendingClipboardAcknowledgements = [NSMutableDictionary dictionary];
        _stateLock = [[NSLock alloc] init];
        _dvcChannelLock = [[NSRecursiveLock alloc] init];
        _sessionID = @"";
        _connectionAttemptIdentifier = @"";
        _latestFrameMetadata = @{};
    }
    return self;
}

- (void)dealloc
{
    [self disconnect];
    [_dvcCallbackReleasePool drainTrackedPointers];
    if (_engineState) {
        [self clearSurface];
        free(_engineState);
        _engineState = NULL;
    }
}

- (BOOL)startWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                         error:(NSError **)error
{
    return [self startWithConfiguration:configuration relaySocket:nil error:error];
}

- (BOOL)startWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                   relaySocket:(NSFileHandle * _Nullable)relaySocket
                         error:(NSError **)error
{
    @synchronized (self) {
        if (self.running) {
            if (error) {
                *error = [NSError errorWithDomain:JTFreeRDPEngineErrorDomain
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"An RDP connection is already active in this helper."}];
            }
            return NO;
        }

        NSString *host = [configuration[@"host"] isKindOfClass:NSString.class] ? configuration[@"host"] : @"";
        NSString *username = [configuration[@"username"] isKindOfClass:NSString.class] ? configuration[@"username"] : @"";
        NSString *password = [configuration[@"password"] isKindOfClass:NSString.class] ? configuration[@"password"] : @"";
        NSString *domain = [configuration[@"domain"] isKindOfClass:NSString.class] ? configuration[@"domain"] : @"";
        NSString *sessionID = [configuration[@"sessionId"] isKindOfClass:NSString.class]
            ? configuration[@"sessionId"] : @"";
        NSString *attemptIdentifier =
            [configuration[@"connectionAttemptId"] isKindOfClass:NSString.class]
                ? configuration[@"connectionAttemptId"] : @"";
        NSUUID *attemptUUID = [[NSUUID alloc] initWithUUIDString:attemptIdentifier];
        NSNumber *portValue = [configuration[@"port"] isKindOfClass:NSNumber.class] ? configuration[@"port"] : nil;
        NSNumber *widthValue = [configuration[@"width"] isKindOfClass:NSNumber.class] ? configuration[@"width"] : nil;
        NSNumber *heightValue = [configuration[@"height"] isKindOfClass:NSNumber.class] ? configuration[@"height"] : nil;
        NSNumber *clipboardEnabledValue =
            [configuration[@"clipboardEnabled"] isKindOfClass:NSNumber.class]
                ? configuration[@"clipboardEnabled"] : nil;
        NSInteger port = portValue.integerValue;
        NSInteger width = widthValue.integerValue;
        NSInteger height = heightValue.integerValue;
        BOOL clipboardValueIsBoolean = clipboardEnabledValue &&
            CFGetTypeID((__bridge CFTypeRef)clipboardEnabledValue) ==
                CFBooleanGetTypeID();

        if (host.length == 0 || host.length > 255 ||
            username.length == 0 || username.length > 512 ||
            password.length == 0 || password.length > 4096 ||
            domain.length > 255 || sessionID.length > 128 ||
            attemptIdentifier.length != 36 || !attemptUUID ||
            !portValue || !widthValue || !heightValue || !clipboardValueIsBoolean ||
            port < 1 || port > UINT16_MAX || width < 640 || width > 7680 ||
            height < 480 || height > 4320) {
            if (error) {
                *error = [NSError errorWithDomain:JTFreeRDPEngineErrorDomain
                                             code:2
                                         userInfo:@{NSLocalizedDescriptionKey: @"Host, username, password, port, and framebuffer dimensions must be valid."}];
            }
            return NO;
        }

        int relayDescriptor = relaySocket ? JTDuplicateRelaySocket(relaySocket) : -1;
        if (relaySocket && relayDescriptor < 0) {
            if (error) *error = JTFreeRDPError(2, @"RDP_RELAY_SOCKET_INVALID",
                @"The authenticated relay stream is not a connected private socket.");
            return NO;
        }
        [self.relaySocket closeFile];
        self.relaySocket = relaySocket
            ? [[NSFileHandle alloc] initWithFileDescriptor:relayDescriptor closeOnDealloc:YES] : nil;
        self.usesRelayTransport = relaySocket != nil;
        self.sessionID = sessionID.length > 0 ? sessionID : NSUUID.UUID.UUIDString;
        self.connectionAttemptIdentifier = attemptUUID.UUIDString.lowercaseString;
        self.pinnedFingerprint = [self.class normalizeFingerprint:configuration[@"pinnedFingerprint"]];
        self.trustOnceFingerprint = [self.class normalizeFingerprint:configuration[@"trustOnceFingerprint"]];
        [self.clipboardBridge detachCurrentContext];
        self.clipboardBridge = [[JTFreeRDPTextClipboardBridge alloc]
            initWithEnabled:clipboardEnabledValue.boolValue];
        self.clipboardBridge.delegate = self;
        self.disconnectRequested = NO;
        self.preConnectCompleted = NO;
        self.preConnectFailureCode = nil;
        self.preConnectFailureMessage = nil;
        self.clipboardIsolationGeneration = 0;
        self.running = YES;
        [self failAllClipboardAcknowledgementsWithCode:@"RDP_XPC_SESSION_REPLACED"
                                               message:@"The previous RDP helper session was replaced."];
        [self.commandQueue cancelAllWithCode:@"RDP_XPC_SESSION_REPLACED"
                                     message:@"The previous RDP helper session was replaced."];

        NSDictionary *configurationCopy = [configuration copy];
        [self notifyState:@"connecting" code:nil message:nil];
        dispatch_async(self.workerQueue, ^{
            [self runConnectionWithConfiguration:configurationCopy];
        });
        return YES;
    }
}

- (void)disconnect
{
    self.disconnectRequested = YES;
    @synchronized (self) {
        [self.relaySocket closeFile];
        self.relaySocket = nil;
    }
    [self failAllClipboardAcknowledgementsWithCode:@"RDP_XPC_DISCONNECTED"
                                           message:@"The RDP desktop disconnected before Windows acknowledged the clipboard update."];
    [self.commandQueue cancelAllWithCode:@"RDP_XPC_DISCONNECTED"
                                 message:@"The RDP desktop disconnected before the queued request executed."];
    [self.stateLock lock];
    freerdp *instance = self.engineState ? self.engineState->instance : NULL;
    if (instance && instance->context) {
        freerdp_abort_connect_context(instance->context);
    }
    [self.stateLock unlock];
}

- (int)takeRelaySocketDescriptor
{
    @synchronized (self) {
        if (self.disconnectRequested || !self.relaySocket) return -1;
        int result = JTDuplicateRelaySocket(self.relaySocket);
        [self.relaySocket closeFile];
        self.relaySocket = nil;
        return result;
    }
}

- (BOOL)enqueueInput:(NSDictionary<NSString *, id> *)input
              request:(JTFreeRDPXPCRequestEnvelope *)request
           completion:(JTFreeRDPEngineCommandCompletion)completion
                error:(NSError **)error
{
    [self.stateLock lock];
    BOOL connected = self.engineState && self.engineState->connected;
    [self.stateLock unlock];
    if (!self.running || !connected) {
        if (error) {
            *error = JTFreeRDPError(3, @"DESKTOP_NOT_CONNECTED",
                                    @"The RDP desktop is not connected.");
        }
        return NO;
    }
    NSString *type = [input[@"type"] isKindOfClass:NSString.class] ? input[@"type"] : nil;
    NSSet<NSString *> *allowedTypes = [NSSet setWithArray:@[
        @"mouse", @"scancode", @"keyChord", @"text", @"resize"
    ]];
    if (!type || ![allowedTypes containsObject:type]) {
        if (error) {
            *error = JTFreeRDPError(4, @"INPUT_TYPE_INVALID",
                                    @"Input events require a supported type.");
        }
        return NO;
    }
    NSMutableDictionary<NSString *, id> *command = [input mutableCopy];
    command[@"expectedConnectionAttemptId"] = request.connectionAttemptIdentifier;

    BOOL requiresDesktopState = [type isEqualToString:@"mouse"] ||
        [type isEqualToString:@"scancode"] ||
        [type isEqualToString:@"keyChord"] ||
        [type isEqualToString:@"text"];
    NSDictionary<NSString *, id> *frame = @{};
    if (requiresDesktopState) {
        [self.stateLock lock];
        frame = [self.latestFrameMetadata copy];
        [self.stateLock unlock];
    }
    NSError *stateError = nil;
    NSDictionary<NSString *, id> *validated =
        JTFreeRDPInputCommandForExecution(
            command,
            frame,
            self.connectionAttemptIdentifier,
            &stateError);
    if (!validated) {
        if (error) {
            *error = stateError;
        }
        return NO;
    }
    command = [validated mutableCopy];

    if ([type isEqualToString:@"scancode"]) {
        if (![input[@"scancode"] isKindOfClass:NSNumber.class] ||
            [input[@"scancode"] unsignedIntegerValue] > UINT16_MAX) {
            if (error) {
                *error = JTFreeRDPError(9, @"SCANCODE_INVALID",
                                        @"Keyboard scancodes must be 16-bit numeric values.");
            }
            return NO;
        }
    } else if ([type isEqualToString:@"keyChord"]) {
        NSArray *scanCodes = [input[@"scancodes"] isKindOfClass:NSArray.class]
            ? input[@"scancodes"] : nil;
        if (scanCodes.count == 0 || scanCodes.count > 32) {
            if (error) {
                *error = JTFreeRDPError(9, @"SCANCODE_INVALID",
                                        @"Key chords require one to thirty-two scancodes.");
            }
            return NO;
        }
    } else if ([type isEqualToString:@"text"]) {
        NSString *text = [input[@"text"] isKindOfClass:NSString.class] ? input[@"text"] : nil;
        if (!text || text.length > 32768) {
            if (error) {
                *error = JTFreeRDPError(10, @"TEXT_INPUT_INVALID",
                                        @"Text input must be a string no longer than 32,768 UTF-16 code units.");
            }
            return NO;
        }
    } else if ([type isEqualToString:@"resize"]) {
        NSNumber *widthValue = [input[@"width"] isKindOfClass:NSNumber.class] ? input[@"width"] : nil;
        NSNumber *heightValue = [input[@"height"] isKindOfClass:NSNumber.class] ? input[@"height"] : nil;
        NSInteger width = widthValue.integerValue;
        NSInteger height = heightValue.integerValue;
        if (!widthValue || !heightValue || width < 640 || width > 7680 ||
            height < 480 || height > 4320) {
            if (error) {
                *error = JTFreeRDPError(11, @"RESOLUTION_INVALID",
                                        @"Desktop size must be between 640x480 and 7680x4320.");
            }
            return NO;
        }
    }

    command[@"commandKind"] = @"input";
    return [self.commandQueue enqueueCommand:command
                           requestIdentifier:request.requestIdentifier
                deadlineUptimeMilliseconds:request.deadlineUptimeMilliseconds
                                queueFullCode:@"INPUT_QUEUE_FULL"
                                   completion:completion
                                        error:error];
}

- (BOOL)enqueueDVCMessage:(NSData *)message
                   request:(JTFreeRDPXPCRequestEnvelope *)request
 expectedChannelGeneration:(uint64_t)expectedChannelGeneration
                completion:(JTFreeRDPEngineCommandCompletion)completion
                     error:(NSError **)error
{
    [self.stateLock lock];
    BOOL desktopConnected = self.engineState && self.engineState->connected;
    [self.stateLock unlock];
    if (message.length == 0 || message.length > JTMaximumDVCMessageBytes) {
        if (error) {
            *error = JTFreeRDPError(6, @"DVC_MESSAGE_SIZE_INVALID",
                                    @"DVC message length is outside the allowed range.");
        }
        return NO;
    }

    NSDictionary<NSString *, id> *command = @{
        @"commandKind": @"dvc",
        @"message": [message copy],
        @"expectedConnectionAttemptId": request.connectionAttemptIdentifier,
        @"expectedDVCGeneration": @(expectedChannelGeneration)
    };
    NSError *attemptError = JTFreeRDPConnectionAttemptValidationError(
        command,
        self.connectionAttemptIdentifier,
        nil);
    if (attemptError) {
        if (error) {
            *error = attemptError;
        }
        return NO;
    }
    [self.dvcChannelLock lock];
    BOOL companionConnected = desktopConnected && self.engineState &&
        self.engineState->dvcChannel != NULL;
    uint64_t currentDVCGeneration = self.engineState
        ? self.engineState->dvcGeneration : 0;
    [self.dvcChannelLock unlock];
    NSError *generationError = JTFreeRDPDVCGenerationValidationError(
        command,
        currentDVCGeneration);
    if (generationError) {
        if (error) {
            *error = generationError;
        }
        return NO;
    }
    if (!self.running || !companionConnected) {
        if (error) {
            *error = JTFreeRDPError(5, @"COMPANION_REQUIRED",
                                    @"Windows Companion is not connected on JTS.Companion.v1.");
        }
        return NO;
    }

    return [self.commandQueue enqueueCommand:command
                           requestIdentifier:request.requestIdentifier
                deadlineUptimeMilliseconds:request.deadlineUptimeMilliseconds
                                queueFullCode:@"DVC_QUEUE_FULL"
                                   completion:completion
                                        error:error];
}

- (BOOL)enqueueClipboardText:(NSData * _Nullable)text
                     request:(JTFreeRDPXPCRequestEnvelope *)request
                  completion:(JTFreeRDPEngineCommandCompletion)completion
                       error:(NSError **)error
{
    [self.stateLock lock];
    BOOL connected = self.engineState && self.engineState->connected;
    [self.stateLock unlock];
    if (!self.running || !connected) {
        if (error) {
            *error = JTFreeRDPError(
                3,
                @"DESKTOP_NOT_CONNECTED",
                @"The RDP desktop is not connected.");
        }
        return NO;
    }
    if (!self.clipboardBridge.isEnabled) {
        if (error) {
            *error = JTFreeRDPError(
                17,
                @"RDP_CLIPBOARD_DISABLED",
                @"Text clipboard redirection is disabled for this RDP profile.");
        }
        return NO;
    }
    if (!JTFreeRDPValidateClipboardText(text, error)) {
        return NO;
    }

    NSDictionary<NSString *, id> *command = @{
        @"commandKind": @"clipboard",
        @"hasText": @(text != nil),
        @"text": text ? [text copy] : NSData.data,
        @"acknowledgementIdentifier": request.requestIdentifier,
        @"expectedConnectionAttemptId": request.connectionAttemptIdentifier
    };
    NSError *attemptError = JTFreeRDPConnectionAttemptValidationError(
        command,
        self.connectionAttemptIdentifier,
        nil);
    if (attemptError) {
        if (error) {
            *error = attemptError;
        }
        return NO;
    }
    if (![self registerClipboardAcknowledgement:completion
                             requestIdentifier:request.requestIdentifier
                                isolationState:nil]) {
        if (error) {
            *error = JTFreeRDPError(
                17,
                @"RDP_CLIPBOARD_ACK_DUPLICATE",
                @"The clipboard acknowledgement identifier was already pending.");
        }
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    JTFreeRDPEngineCommandCompletion queueCompletion =
        ^(NSError *executionError) {
        if (executionError) {
            [weakSelf
                completeClipboardAcknowledgement:request.requestIdentifier
                                           error:executionError];
        }
    };
    BOOL accepted = [self.commandQueue
        enqueueCommand:command
        requestIdentifier:request.requestIdentifier
        deadlineUptimeMilliseconds:request.deadlineUptimeMilliseconds
        queueFullCode:@"RDP_CLIPBOARD_QUEUE_FULL"
        completion:queueCompletion
        error:error];
    if (!accepted) {
        [self discardClipboardAcknowledgement:request.requestIdentifier];
    }
    return accepted;
}

- (BOOL)enqueueClipboardIsolation:(BOOL)isolated
                             text:(NSData * _Nullable)text
                          request:(JTFreeRDPXPCRequestEnvelope *)request
                       completion:(JTFreeRDPEngineCommandCompletion)completion
                            error:(NSError **)error
{
    [self.stateLock lock];
    BOOL connected = self.engineState && self.engineState->connected;
    [self.stateLock unlock];
    if (!self.running || !connected) {
        if (error) {
            *error = JTFreeRDPError(
                3,
                @"DESKTOP_NOT_CONNECTED",
                @"The RDP desktop is not connected.");
        }
        return NO;
    }
    if (!self.clipboardBridge.isEnabled) {
        if (error) {
            *error = JTFreeRDPError(
                17,
                @"RDP_CLIPBOARD_DISABLED",
                @"Text clipboard redirection is disabled for this RDP profile.");
        }
        return NO;
    }
    if ((isolated && text != nil) ||
        !JTFreeRDPValidateClipboardText(text, error)) {
        if (isolated && text != nil && error) {
            *error = JTFreeRDPError(
                17,
                @"RDP_CLIPBOARD_ISOLATION_INVALID",
                @"Clipboard isolation requires an empty pause payload.");
        }
        return NO;
    }

    NSDictionary<NSString *, id> *command = @{
        @"commandKind": @"clipboardIsolation",
        @"isolated": @(isolated),
        @"hasText": @(text != nil),
        @"text": text ? [text copy] : NSData.data,
        @"acknowledgementIdentifier": request.requestIdentifier,
        @"expectedConnectionAttemptId": request.connectionAttemptIdentifier
    };
    NSError *attemptError = JTFreeRDPConnectionAttemptValidationError(
        command,
        self.connectionAttemptIdentifier,
        nil);
    if (attemptError) {
        if (error) {
            *error = attemptError;
        }
        return NO;
    }
    if (![self registerClipboardAcknowledgement:completion
                             requestIdentifier:request.requestIdentifier
                                isolationState:@(isolated)]) {
        if (error) {
            *error = JTFreeRDPError(
                17,
                @"RDP_CLIPBOARD_ACK_DUPLICATE",
                @"The clipboard isolation acknowledgement was already pending.");
        }
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    BOOL accepted = [self.commandQueue
        enqueueCommand:command
        requestIdentifier:request.requestIdentifier
        deadlineUptimeMilliseconds:request.deadlineUptimeMilliseconds
        queueFullCode:@"RDP_CLIPBOARD_QUEUE_FULL"
        completion:^(NSError *executionError) {
            if (executionError) {
                [weakSelf
                    completeClipboardAcknowledgement:request.requestIdentifier
                                               error:executionError];
            }
        }
        error:error];
    if (!accepted) {
        [self discardClipboardAcknowledgement:request.requestIdentifier];
    }
    return accepted;
}

- (BOOL)enqueueCompanionInstallerOfferAtURL:(NSURL *)installerURL
                             remoteFileName:(NSString *)remoteFileName
                             expectedSHA256:(NSString *)expectedSHA256
                                    request:(JTFreeRDPXPCRequestEnvelope *)request
                                 completion:(JTFreeRDPEngineCommandCompletion)completion
                                      error:(NSError **)error
{
    [self.stateLock lock];
    BOOL connected = self.engineState && self.engineState->connected;
    [self.stateLock unlock];
    NSCharacterSet *invalidDigestCharacters = [[NSCharacterSet
        characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    BOOL digestIsValid = expectedSHA256.length == 64 &&
        [expectedSHA256 rangeOfCharacterFromSet:invalidDigestCharacters].location == NSNotFound;
    if (!self.running || !connected) {
        if (error) {
            *error = JTFreeRDPError(
                3,
                @"DESKTOP_NOT_CONNECTED",
                @"The RDP desktop is not connected.");
        }
        return NO;
    }
    if (!self.clipboardBridge.isEnabled) {
        if (error) {
            *error = JTFreeRDPError(
                17,
                @"RDP_CLIPBOARD_DISABLED",
                @"RDP clipboard redirection must be enabled to install Windows Companion.");
        }
        return NO;
    }
    if (!installerURL.isFileURL ||
        !JTFreeRDPIsValidCompanionInstallerRemoteFileName(remoteFileName) ||
        !digestIsValid) {
        if (error) {
            *error = JTFreeRDPError(
                17,
                @"COMPANION_INSTALLER_INVALID",
                @"The Companion installer artifact is invalid.");
        }
        return NO;
    }

    NSDictionary<NSString *, id> *command = @{
        @"commandKind": @"companionInstallerOffer",
        @"installerURL": installerURL,
        @"remoteFileName": remoteFileName,
        @"expectedSHA256": expectedSHA256,
        @"acknowledgementIdentifier": request.requestIdentifier,
        @"expectedConnectionAttemptId": request.connectionAttemptIdentifier
    };
    NSError *attemptError = JTFreeRDPConnectionAttemptValidationError(
        command,
        self.connectionAttemptIdentifier,
        nil);
    if (attemptError) {
        if (error) {
            *error = attemptError;
        }
        return NO;
    }
    if (![self registerClipboardAcknowledgement:completion
                             requestIdentifier:request.requestIdentifier
                                isolationState:nil]) {
        if (error) {
            *error = JTFreeRDPError(
                17,
                @"RDP_CLIPBOARD_ACK_DUPLICATE",
                @"The Companion installer acknowledgement identifier was already pending.");
        }
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    BOOL accepted = [self.commandQueue
        enqueueCommand:command
        requestIdentifier:request.requestIdentifier
        deadlineUptimeMilliseconds:request.deadlineUptimeMilliseconds
        queueFullCode:@"RDP_CLIPBOARD_QUEUE_FULL"
        completion:^(NSError *executionError) {
            if (executionError) {
                [weakSelf
                    completeClipboardAcknowledgement:request.requestIdentifier
                                               error:executionError];
            }
        }
        error:error];
    if (!accepted) {
        [self discardClipboardAcknowledgement:request.requestIdentifier];
    }
    return accepted;
}

- (BOOL)enqueueCompanionInstallerClearWithRequest:
    (JTFreeRDPXPCRequestEnvelope *)request
                                      completion:
    (JTFreeRDPEngineCommandCompletion)completion
                                           error:(NSError **)error
{
    [self.stateLock lock];
    BOOL connected = self.engineState && self.engineState->connected;
    [self.stateLock unlock];
    if (!self.running || !connected) {
        if (error) {
            *error = JTFreeRDPError(
                3,
                @"DESKTOP_NOT_CONNECTED",
                @"The RDP desktop is not connected.");
        }
        return NO;
    }
    if (!self.clipboardBridge.isEnabled) {
        if (error) {
            *error = JTFreeRDPError(
                17,
                @"RDP_CLIPBOARD_DISABLED",
                @"RDP clipboard redirection is disabled for this profile.");
        }
        return NO;
    }
    NSDictionary<NSString *, id> *command = @{
        @"commandKind": @"companionInstallerClear",
        @"acknowledgementIdentifier": request.requestIdentifier,
        @"expectedConnectionAttemptId": request.connectionAttemptIdentifier
    };
    NSError *attemptError = JTFreeRDPConnectionAttemptValidationError(
        command,
        self.connectionAttemptIdentifier,
        nil);
    if (attemptError) {
        if (error) {
            *error = attemptError;
        }
        return NO;
    }
    if (![self registerClipboardAcknowledgement:completion
                             requestIdentifier:request.requestIdentifier
                                isolationState:nil]) {
        if (error) {
            *error = JTFreeRDPError(
                17,
                @"RDP_CLIPBOARD_ACK_DUPLICATE",
                @"The Companion installer clear acknowledgement was already pending.");
        }
        return NO;
    }
    __weak typeof(self) weakSelf = self;
    BOOL accepted = [self.commandQueue
        enqueueCommand:command
        requestIdentifier:request.requestIdentifier
        deadlineUptimeMilliseconds:request.deadlineUptimeMilliseconds
        queueFullCode:@"RDP_CLIPBOARD_QUEUE_FULL"
        completion:^(NSError *executionError) {
            if (executionError) {
                [weakSelf
                    completeClipboardAcknowledgement:request.requestIdentifier
                                               error:executionError];
            }
        }
        error:error];
    if (!accepted) {
        [self discardClipboardAcknowledgement:request.requestIdentifier];
    }
    return accepted;
}

- (BOOL)cancelRequestIdentifier:(NSString *)requestIdentifier
{
    BOOL prevented = [self.commandQueue
        cancelRequestIdentifier:requestIdentifier];
    NSError *cancellation = JTFreeRDPError(
        17,
        @"RDP_XPC_REQUEST_CANCELLED",
        @"The clipboard acknowledgement wait was cancelled.");
    BOOL cancelledAcknowledgement = [self
        completeClipboardAcknowledgement:requestIdentifier
                                   error:cancellation];
    return prevented || cancelledAcknowledgement;
}

- (BOOL)registerClipboardAcknowledgement:
    (JTFreeRDPEngineCommandCompletion)completion
                    requestIdentifier:(NSString *)requestIdentifier
                       isolationState:(NSNumber * _Nullable)isolationState
{
    if (!completion || requestIdentifier.length == 0) {
        return NO;
    }
    JTFreeRDPPendingClipboardAcknowledgement *pending =
        [[JTFreeRDPPendingClipboardAcknowledgement alloc] init];
    pending.completion = completion;
    pending.isolationState = isolationState;
    [self.clipboardAcknowledgementLock lock];
    BOOL accepted = self.pendingClipboardAcknowledgements[requestIdentifier] == nil;
    if (accepted) {
        self.pendingClipboardAcknowledgements[requestIdentifier] = pending;
    }
    [self.clipboardAcknowledgementLock unlock];
    return accepted;
}

- (BOOL)completeClipboardAcknowledgement:(NSString *)requestIdentifier
                                   error:(NSError * _Nullable)error
{
    if (requestIdentifier.length == 0) {
        return NO;
    }
    [self.clipboardAcknowledgementLock lock];
    JTFreeRDPPendingClipboardAcknowledgement *pending =
        self.pendingClipboardAcknowledgements[requestIdentifier];
    if (pending) {
        [self.pendingClipboardAcknowledgements
            removeObjectForKey:requestIdentifier];
    }
    [self.clipboardAcknowledgementLock unlock];
    if (pending) {
        if (!error && pending.isolationState != nil) {
            self.clipboardIsolationGeneration = JTNextDVCGeneration(
                self.clipboardIsolationGeneration);
        }
        pending.completion(error);
    }
    return pending != nil;
}

- (BOOL)discardClipboardAcknowledgement:(NSString *)requestIdentifier
{
    if (requestIdentifier.length == 0) {
        return NO;
    }
    [self.clipboardAcknowledgementLock lock];
    BOOL existed = self.pendingClipboardAcknowledgements[requestIdentifier] != nil;
    [self.pendingClipboardAcknowledgements removeObjectForKey:requestIdentifier];
    [self.clipboardAcknowledgementLock unlock];
    return existed;
}

- (void)failAllClipboardAcknowledgementsWithCode:(NSString *)code
                                         message:(NSString *)message
{
    [self.clipboardAcknowledgementLock lock];
    NSArray<JTFreeRDPPendingClipboardAcknowledgement *> *pending =
        self.pendingClipboardAcknowledgements.allValues;
    [self.pendingClipboardAcknowledgements removeAllObjects];
    [self.clipboardAcknowledgementLock unlock];
    NSError *failure = JTFreeRDPError(17, code, message);
    for (JTFreeRDPPendingClipboardAcknowledgement *acknowledgement in pending) {
        acknowledgement.completion(failure);
    }
}

- (void)copyFrameWithReply:(void (^)(NSData * _Nullable,
                                     NSDictionary<NSString *, id> *))reply
{
    dispatch_async(self.frameCopyQueue, ^{
        [self.stateLock lock];
        IOSurfaceRef surface = self.engineState->surface;
        NSDictionary<NSString *, id> *metadata = [self.latestFrameMetadata copy];
        if (surface) {
            CFRetain(surface);
        }
        if (!surface || metadata.count == 0) {
            [self.stateLock unlock];
            if (surface) {
                CFRelease(surface);
            }
            reply(nil, @{});
            return;
        }
        if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != kIOReturnSuccess) {
            [self.stateLock unlock];
            CFRelease(surface);
            reply(nil, @{});
            return;
        }
        NSNumber *metadataSeed = metadata[@"surfaceSeed"];
        uint32_t lockedSeed = IOSurfaceGetSeed(surface);
        if (![metadataSeed isKindOfClass:NSNumber.class] ||
            metadataSeed.unsignedLongLongValue != lockedSeed) {
            IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
            [self.stateLock unlock];
            CFRelease(surface);
            reply(nil, @{});
            return;
        }
        size_t allocationSize = IOSurfaceGetAllocSize(surface);
        void *baseAddress = IOSurfaceGetBaseAddress(surface);
        NSData *pixels = baseAddress && allocationSize > 0 &&
            allocationSize <= JTMaximumFramebufferBytes
            ? [NSData dataWithBytes:baseAddress length:allocationSize] : nil;
        if (IOSurfaceGetSeed(surface) != lockedSeed) {
            pixels = nil;
        }
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        [self.stateLock unlock];
        CFRelease(surface);
        reply(pixels, metadata);
    });
}

+ (nullable NSString *)normalizeFingerprint:(id)value
{
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
    NSMutableString *normalized = [NSMutableString stringWithCapacity:64];
    NSString *uppercase = [(NSString *)value uppercaseString];
    for (NSUInteger index = 0; index < uppercase.length; index++) {
        unichar character = [uppercase characterAtIndex:index];
        if ([hex characterIsMember:character]) {
            [normalized appendFormat:@"%C", character];
        }
    }
    return normalized.length == 64 ? normalized : nil;
}

- (void)runConnectionWithConfiguration:(NSDictionary<NSString *, id> *)configuration
{
    @autoreleasepool {
        NSLock *addinSetupLock = JTFreeRDPAddinSetupLock();
        [addinSetupLock lock];
#if DEBUG
        JTEnableScopedFreeRDPDiagnostics();
#endif
        RDP_CLIENT_ENTRY_POINTS entryPoints;
        JTConfigureEntryPoints(&entryPoints);
        rdpContext *context = freerdp_client_context_new(&entryPoints);
        if (!context) {
            [addinSetupLock unlock];
            [self finishWithCode:@"RDP_CONTEXT_CREATE_FAILED"
                         message:@"FreeRDP could not allocate a client context."];
            return;
        }

        // freerdp_client_context_new installs the built-in provider globally.
        // Replace it only after context creation so our named Companion DVC is
        // visible when FreeRDP's LoadChannels callback resolves the channel set.
        freerdp_register_addin_provider(JTAddinProvider, 0);

        freerdp *instance = context->instance;
        ((JTFreeRDPContext *)context)->engine = (__bridge void *)self;
        [self.stateLock lock];
        self.engineState->instance = instance;
        [self.stateLock unlock];

        BOOL relayConfigured = YES;
        if (self.usesRelayTransport) {
            rdpTransportIo callbacks = *freerdp_get_io_callbacks(context);
            callbacks.TCPConnect = JTRelayTCPConnect;
            relayConfigured = freerdp_set_io_callbacks(context, &callbacks);
        }
        if (!relayConfigured || ![self configureSettings:context->settings configuration:configuration]) {
            [addinSetupLock unlock];
            [self.stateLock lock];
            self.engineState->instance = NULL;
            [self.stateLock unlock];
            [self.clipboardBridge detachCurrentContext];
            freerdp_client_context_free(context);
            [self.dvcCallbackReleasePool drainTrackedPointers];
            [self finishWithCode:@"RDP_SETTINGS_REJECTED"
                         message:@"FreeRDP rejected one or more secure connection settings."];
            return;
        }

        // FreeRDP's external certificate-management mode is reserved for an
        // explicit JTS Terminal SHA-256 pin. Unpinned connections continue to
        // use FreeRDP's normal certificate validation and rich Ex callbacks;
        // pinned connections must match the exact leaf certificate below.
        BOOL enforcePinnedCertificate = self.pinnedFingerprint.length == 64 ||
            self.trustOnceFingerprint.length == 64;
        instance->VerifyX509Certificate = enforcePinnedCertificate
            ? JTVerifyX509Certificate : NULL;

        if (self.disconnectRequested) {
            [addinSetupLock unlock];
            [self.stateLock lock];
            self.engineState->instance = NULL;
            [self.stateLock unlock];
            [self.clipboardBridge detachCurrentContext];
            freerdp_client_context_free(context);
            [self.dvcCallbackReleasePool drainTrackedPointers];
            [self finishWithCode:@"RDP_CONNECT_CANCELLED" message:@"The RDP connection was cancelled."];
            return;
        }

        [self notifyState:@"authenticating" code:nil message:nil];
        BOOL connected = freerdp_connect(instance);
        [addinSetupLock unlock];
        if (!connected) {
            UINT32 lastError = freerdp_get_last_error(context);
            NSString *code = [self stringFromCString:freerdp_get_last_error_name(lastError)
                                            fallback:@"RDP_CONNECT_FAILED"];
            NSString *message = [self stringFromCString:freerdp_get_last_error_string(lastError)
                                               fallback:@"The RDP connection failed."];
            NSString *stage = [self stringFromCString:freerdp_state_string(freerdp_get_state(context))
                                             fallback:@""];
            if (stage.length > 0) {
                message = [message stringByAppendingFormat:@" (FreeRDP stage: %@.)", stage];
            }
            if (lastError == FREERDP_ERROR_PRE_CONNECT_FAILED) {
                if (self.preConnectFailureCode.length > 0) {
                    code = self.preConnectFailureCode;
                    message = self.preConnectFailureMessage ?: message;
                } else if (self.preConnectCompleted) {
                    code = @"RDP_POST_PRECONNECT_VALIDATION_FAILED";
                    message = @"FreeRDP rejected the connection after client setup while validating monitors or reloading channels.";
                }
            }
            [self.stateLock lock];
            self.engineState->instance = NULL;
            [self.stateLock unlock];
            [self.clipboardBridge detachCurrentContext];
            freerdp_client_context_free(context);
            [self.dvcCallbackReleasePool drainTrackedPointers];
            [self finishWithCode:code message:message];
            return;
        }

        [self.stateLock lock];
        self.engineState->connected = YES;
        [self.stateLock unlock];
        [self notifyState:@"connected" code:nil message:nil];
        [self runEventLoop:context];

        // Capture the server's protocol-level termination reason before
        // freerdp_disconnect() and context teardown can replace or discard it.
        // Error Info PDUs populate both the raw RDP errorInfo and LastError,
        // but errorInfo remains authoritative if a later transport operation
        // overwrites LastError while the event loop is unwinding.
        UINT32 sessionErrorInfo = freerdp_error_info(instance);
        UINT32 sessionLastError = freerdp_get_last_error(context);

        [self.stateLock lock];
        self.engineState->connected = NO;
        self.engineState->instance = NULL;
        [self.stateLock unlock];
        freerdp_disconnect(instance);
        [self.clipboardBridge detachCurrentContext];
        freerdp_client_context_free(context);
        [self.dvcCallbackReleasePool drainTrackedPointers];
        [self clearDVCChannel];
        [self.stateLock lock];
        self.engineState->displayControl = NULL;
        [self.stateLock unlock];

        self.running = NO;
        if (self.disconnectRequested) {
            [self notifyState:@"closed" code:nil message:nil];
        } else if (sessionErrorInfo == ERRINFO_LOGOFF_BY_USER ||
                   sessionLastError == FREERDP_ERROR_LOGOFF_BY_USER) {
            [self notifyState:@"failed"
                         code:@"RDP_LOGOFF_BY_USER"
                      message:@"Windows ended the RDP session after a user logoff or an unconfirmed sign-in/session handoff. Reconnect manually when ready."];
        } else {
            [self notifyState:@"failed"
                         code:@"RDP_CONNECTION_LOST"
                      message:@"The RDP transport closed unexpectedly."];
        }
    }
}

- (BOOL)configureSettings:(rdpSettings *)settings
            configuration:(NSDictionary<NSString *, id> *)configuration
{
    NSString *host = configuration[@"host"];
    NSString *username = configuration[@"username"];
    NSString *password = configuration[@"password"];
    NSString *domain = [configuration[@"domain"] isKindOfClass:NSString.class] ? configuration[@"domain"] : @"";
    UINT32 port = (UINT32)[configuration[@"port"] unsignedIntegerValue];
    UINT32 width = (UINT32)[configuration[@"width"] unsignedIntegerValue];
    UINT32 height = (UINT32)[configuration[@"height"] unsignedIntegerValue];
    BOOL clipboardEnabled = [configuration[@"clipboardEnabled"] boolValue] &&
        self.clipboardBridge.isEnabled;
    BOOL enforcePinnedCertificate = self.pinnedFingerprint.length == 64 ||
        self.trustOnceFingerprint.length == 64;

    return freerdp_settings_set_string(settings, FreeRDP_ServerHostname, host.UTF8String) &&
        freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, port) &&
        freerdp_settings_set_string(settings, FreeRDP_Username, username.UTF8String) &&
        freerdp_settings_set_string(settings, FreeRDP_Password, password.UTF8String) &&
        freerdp_settings_set_string(settings, FreeRDP_Domain, domain.UTF8String) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height) &&
        freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
        freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE) &&
        // Use FreeRDP's standard /sec:nla posture: negotiate the protocol while
        // advertising only TLS-protected CredSSP. TLS-only and legacy RDP
        // Security remain disabled, so negotiation cannot downgrade them.
        freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_UseRdpSecurityLayer, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AadSecurity, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AutoDenyCertificate, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_ExternalCertificateManagement,
                                  enforcePinnedCertificate) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard,
                                  clipboardEnabled) &&
        freerdp_settings_set_uint32(
            settings,
            FreeRDP_ClipboardFeatureMask,
            clipboardEnabled
                ? (CLIPRDR_FLAG_LOCAL_TO_REMOTE |
                   CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES |
                   CLIPRDR_FLAG_REMOTE_TO_LOCAL)
                : 0) &&
        freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectDrives, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectPrinters, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectSmartCards, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectSerialPorts, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectParallelPorts, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportSSHAgentChannel, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_UseMultimon, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SpanMonitors, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_ForceMultimon, FALSE) &&
        // FreeRDP enables network auto-detection and heartbeat by default.
        // Those RDP8 features force rdpdr device redirection, which this
        // least-privilege client intentionally does not compile or expose.
        freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE);
}

- (void)runEventLoop:(rdpContext *)context
{
    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
    while (!self.disconnectRequested && !freerdp_shall_disconnect_context(context)) {
        DWORD count = freerdp_get_event_handles(context, handles, MAXIMUM_WAIT_OBJECTS);
        if (count == 0) {
            break;
        }

        DWORD waitResult = WaitForMultipleObjects(count, handles, FALSE, 50);
        if (waitResult == WAIT_FAILED) {
            break;
        }
        if (waitResult != WAIT_TIMEOUT && !freerdp_check_event_handles(context)) {
            break;
        }
        [self drainCommands:context];
    }
}

- (void)drainCommands:(rdpContext *)context
{
    [self.commandQueue drainWithExecutor:^NSError * _Nullable(
        NSDictionary<NSString *, id> *command
    ) {
        if ([command[@"commandKind"] isEqual:@"dvc"]) {
            NSError *attemptError = JTFreeRDPConnectionAttemptValidationError(
                command,
                self.connectionAttemptIdentifier,
                nil);
            if (attemptError) {
                return attemptError;
            }
            [self.dvcChannelLock lock];
            uint64_t currentDVCGeneration = self.engineState
                ? self.engineState->dvcGeneration : 0;
            [self.dvcChannelLock unlock];
            NSError *generationError = JTFreeRDPDVCGenerationValidationError(
                command,
                currentDVCGeneration);
            if (generationError) {
                return generationError;
            }
            NSData *message = command[@"message"];
            return [self writeDVCMessage:message
                      expectedGeneration:[command[@"expectedDVCGeneration"] unsignedLongLongValue]];
        }
        if ([command[@"commandKind"] isEqual:@"clipboard"] ||
            [command[@"commandKind"] isEqual:@"clipboardIsolation"] ||
            [command[@"commandKind"] isEqual:@"companionInstallerOffer"] ||
            [command[@"commandKind"] isEqual:@"companionInstallerClear"]) {
            return [self sendClipboardCommand:command];
        }
        return [self sendInputCommand:command context:context];
    }];
}

- (NSError * _Nullable)sendClipboardCommand:(NSDictionary<NSString *, id> *)command
{
    NSError *attemptError = JTFreeRDPConnectionAttemptValidationError(
        command,
        self.connectionAttemptIdentifier,
        nil);
    if (attemptError) {
        return attemptError;
    }
    NSString *commandKind = [command[@"commandKind"] isKindOfClass:NSString.class]
        ? command[@"commandKind"] : @"";
    NSString *acknowledgementIdentifier =
        [command[@"acknowledgementIdentifier"] isKindOfClass:NSString.class]
            ? command[@"acknowledgementIdentifier"] : nil;
    if ([commandKind isEqualToString:@"companionInstallerOffer"]) {
        NSURL *installerURL = [command[@"installerURL"] isKindOfClass:NSURL.class]
            ? command[@"installerURL"] : nil;
        NSString *remoteFileName =
            [command[@"remoteFileName"] isKindOfClass:NSString.class]
                ? command[@"remoteFileName"] : nil;
        NSString *expectedSHA256 =
            [command[@"expectedSHA256"] isKindOfClass:NSString.class]
                ? command[@"expectedSHA256"] : nil;
        if (!installerURL ||
            !JTFreeRDPIsValidCompanionInstallerRemoteFileName(remoteFileName) ||
            expectedSHA256.length != 64 || acknowledgementIdentifier.length == 0) {
            return JTFreeRDPError(
                17,
                @"COMPANION_INSTALLER_INVALID",
                @"The queued Companion installer offer is invalid.");
        }
        NSError *error = nil;
        BOOL offered = [self.clipboardBridge
            offerFileAtURL:installerURL
            remoteFileName:remoteFileName
            expectedSHA256:expectedSHA256
            acknowledgementIdentifier:acknowledgementIdentifier
            error:&error];
        return offered
            ? nil
            : error ?: JTFreeRDPError(
                17,
                @"COMPANION_INSTALLER_OFFER_FAILED",
                @"FreeRDP rejected the Companion installer offer.");
    }
    if ([commandKind isEqualToString:@"companionInstallerClear"]) {
        if (acknowledgementIdentifier.length == 0) {
            return JTFreeRDPError(
                17,
                @"COMPANION_INSTALLER_CLEAR_FAILED",
                @"The queued Companion installer clear request is invalid.");
        }
        NSError *error = nil;
        BOOL cleared = [self.clipboardBridge
            clearFileOfferWithAcknowledgementIdentifier:acknowledgementIdentifier
            error:&error];
        return cleared
            ? nil
            : error ?: JTFreeRDPError(
                17,
                @"COMPANION_INSTALLER_CLEAR_FAILED",
                @"FreeRDP rejected removal of the Companion installer offer.");
    }
    NSNumber *hasText = [command[@"hasText"] isKindOfClass:NSNumber.class]
        ? command[@"hasText"] : nil;
    NSData *text = [command[@"text"] isKindOfClass:NSData.class]
        ? command[@"text"] : nil;
    BOOL isIsolationCommand =
        [command[@"commandKind"] isEqual:@"clipboardIsolation"];
    NSNumber *isolated = [command[@"isolated"] isKindOfClass:NSNumber.class]
        ? command[@"isolated"] : nil;
    if (!hasText || !text || !JTFreeRDPValidateClipboardText(
            hasText.boolValue ? text : nil,
            NULL) || acknowledgementIdentifier.length == 0 ||
        (isIsolationCommand && !isolated) ||
        (!isIsolationCommand && isolated != nil) ||
        (isIsolationCommand && isolated.boolValue && hasText.boolValue)) {
        return JTFreeRDPError(
            17,
            @"RDP_CLIPBOARD_TEXT_INVALID",
            @"The queued clipboard update was invalid.");
    }
    NSError *error = nil;
    BOOL updated = isIsolationCommand
        ? [self.clipboardBridge
            setAIControlIsolation:isolated.boolValue
                    localUTF8Text:hasText.boolValue ? text : nil
        acknowledgementIdentifier:acknowledgementIdentifier
                             error:&error]
        : [self.clipboardBridge
            updateLocalUTF8Text:hasText.boolValue ? text : nil
        acknowledgementIdentifier:acknowledgementIdentifier
                             error:&error];
    return updated
        ? nil
        : error ?: JTFreeRDPError(
            17,
            @"RDP_CLIPBOARD_UPDATE_FAILED",
            @"FreeRDP rejected the local clipboard update.");
}

- (NSError * _Nullable)sendInputCommand:(NSDictionary<NSString *, id> *)command
                                context:(rdpContext *)context
{
    NSString *type = command[@"type"];
    if (![type isKindOfClass:NSString.class]) {
        return JTFreeRDPError(
            4,
            @"INPUT_TYPE_INVALID",
            @"The queued input command type is unsupported.");
    }

    BOOL requiresDesktopState = [type isEqualToString:@"mouse"] ||
        [type isEqualToString:@"scancode"] ||
        [type isEqualToString:@"keyChord"] ||
        [type isEqualToString:@"text"];
    NSDictionary<NSString *, id> *frame = @{};
    if (requiresDesktopState) {
        [self.stateLock lock];
        frame = [self.latestFrameMetadata copy];
        [self.stateLock unlock];
    }
    NSError *stateError = nil;
    NSDictionary<NSString *, id> *validated =
        JTFreeRDPInputCommandForExecution(
            command,
            frame,
            self.connectionAttemptIdentifier,
            &stateError);
    if (!validated) {
        return stateError ?: JTFreeRDPError(
            7,
            @"STATE_CONFLICT",
            @"The desktop state changed before the input command could execute.");
    }
    command = validated;

    rdpInput *input = context ? context->input : NULL;
    if (!input) {
        return JTFreeRDPError(
            3,
            @"DESKTOP_NOT_CONNECTED",
            @"The RDP desktop disconnected before the queued input executed.");
    }

    if ([type isEqualToString:@"mouse"]) {
        UINT16 x = (UINT16)MIN(MAX([command[@"x"] integerValue], 0), UINT16_MAX);
        UINT16 y = (UINT16)MIN(MAX([command[@"y"] integerValue], 0), UINT16_MAX);
        NSString *action = command[@"action"];
        NSString *button = command[@"button"];
        UINT16 buttonFlags = PTR_FLAGS_BUTTON1;
        if ([button isEqualToString:@"right"]) {
            buttonFlags = PTR_FLAGS_BUTTON2;
        } else if ([button isEqualToString:@"middle"]) {
            buttonFlags = PTR_FLAGS_BUTTON3;
        }

        BOOL sent = NO;
        if ([action isEqualToString:@"move"]) {
            sent = freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y);
        } else if ([action isEqualToString:@"scroll"]) {
            NSInteger delta = [command[@"deltaY"] integerValue];
            UINT16 magnitude = (UINT16)MIN(labs(delta), WheelRotationMask);
            UINT16 flags = PTR_FLAGS_WHEEL | magnitude;
            if (delta < 0) {
                flags |= PTR_FLAGS_WHEEL_NEGATIVE;
            }
            sent = freerdp_input_send_mouse_event(input, flags, x, y);
        } else if ([action isEqualToString:@"click"] ||
                   [action isEqualToString:@"doubleClick"]) {
            NSUInteger clickCount = [action isEqualToString:@"doubleClick"] ? 2 : 1;
            sent = YES;
            for (NSUInteger index = 0; index < clickCount; index++) {
                BOOL downSent = freerdp_input_send_mouse_event(
                    input,
                    buttonFlags | PTR_FLAGS_DOWN,
                    x,
                    y);
                BOOL upSent = freerdp_input_send_mouse_event(input, buttonFlags, x, y);
                if (!upSent) {
                    // A release is harmless when the matching press was not
                    // accepted, and is mandatory when it was. Retry once before
                    // returning the compound command's failure.
                    (void)freerdp_input_send_mouse_event(input, buttonFlags, x, y);
                }
                if (!downSent || !upSent) {
                    sent = NO;
                    break;
                }
            }
        } else if ([action isEqualToString:@"down"]) {
            sent = freerdp_input_send_mouse_event(
                input,
                buttonFlags | PTR_FLAGS_DOWN,
                x,
                y);
        } else if ([action isEqualToString:@"up"]) {
            sent = freerdp_input_send_mouse_event(input, buttonFlags, x, y);
        }
        return sent ? nil : JTFreeRDPError(
            15,
            @"INPUT_SEND_FAILED",
            @"FreeRDP could not send the complete mouse input command.");
    }

    if ([type isEqualToString:@"scancode"]) {
        UINT32 scanCode = (UINT32)[command[@"scancode"] unsignedIntegerValue];
        BOOL down = [command[@"down"] boolValue];
        BOOL repeat = [command[@"repeat"] boolValue];
        return freerdp_input_send_keyboard_event_ex(input, down, repeat, scanCode)
            ? nil
            : JTFreeRDPError(
                15,
                @"INPUT_SEND_FAILED",
                @"FreeRDP could not send the keyboard input command.");
    }

    if ([type isEqualToString:@"keyChord"]) {
        NSArray<NSNumber *> *scanCodes = command[@"scancodes"];
        NSUInteger attemptedCount = 0;
        BOOL sent = YES;
        for (NSNumber *scanCode in scanCodes) {
            attemptedCount += 1;
            if (!freerdp_input_send_keyboard_event_ex(
                    input,
                    TRUE,
                    FALSE,
                    scanCode.unsignedIntValue)) {
                sent = NO;
                break;
            }
        }
        for (NSUInteger index = attemptedCount; index > 0; index--) {
            UINT32 scanCode = scanCodes[index - 1].unsignedIntValue;
            BOOL released = freerdp_input_send_keyboard_event_ex(
                input,
                FALSE,
                FALSE,
                scanCode);
            if (!released) {
                (void)freerdp_input_send_keyboard_event_ex(
                    input,
                    FALSE,
                    FALSE,
                    scanCode);
                sent = NO;
            }
        }
        return sent ? nil : JTFreeRDPError(
            15,
            @"INPUT_SEND_FAILED",
            @"FreeRDP could not send the complete key chord.");
    }

    if ([type isEqualToString:@"text"]) {
        NSString *text = [command[@"text"] isKindOfClass:NSString.class] ? command[@"text"] : @"";
        for (NSUInteger index = 0; index < text.length; index++) {
            UINT16 codeUnit = [text characterAtIndex:index];
            BOOL downSent = freerdp_input_send_unicode_keyboard_event(input, 0, codeUnit);
            BOOL upSent = freerdp_input_send_unicode_keyboard_event(
                input,
                KBD_FLAGS_RELEASE,
                codeUnit);
            if (!upSent) {
                (void)freerdp_input_send_unicode_keyboard_event(
                    input,
                    KBD_FLAGS_RELEASE,
                    codeUnit);
            }
            if (!downSent || !upSent) {
                return JTFreeRDPError(
                    15,
                    @"INPUT_SEND_FAILED",
                    @"FreeRDP could not send the complete text input command.");
            }
        }
        return nil;
    }

    if ([type isEqualToString:@"resize"]) {
        return [self sendResizeCommand:command];
    }
    return JTFreeRDPError(
        4,
        @"INPUT_TYPE_INVALID",
        @"The queued input command type is unsupported.");
}

- (NSError * _Nullable)sendResizeCommand:(NSDictionary<NSString *, id> *)command
{
    DispClientContext *displayControl = self.engineState->displayControl;
    if (!displayControl || !displayControl->SendMonitorLayout) {
        return JTFreeRDPError(
            17,
            @"DISPLAY_CONTROL_UNAVAILABLE",
            @"The RDP Display Control channel is unavailable, so the desktop could not be resized.");
    }

    UINT32 width = (UINT32)MIN(MAX([command[@"width"] integerValue], 200), 8192);
    UINT32 height = (UINT32)MIN(MAX([command[@"height"] integerValue], 200), 8192);
    DISPLAY_CONTROL_MONITOR_LAYOUT monitor = { 0 };
    monitor.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    monitor.Width = width;
    monitor.Height = height;
    monitor.PhysicalWidth = 0;
    monitor.PhysicalHeight = 0;
    monitor.Orientation = 0;
    monitor.DesktopScaleFactor = 100;
    monitor.DeviceScaleFactor = 100;
    UINT result = displayControl->SendMonitorLayout(displayControl, 1, &monitor);
    return result == CHANNEL_RC_OK ? nil : JTFreeRDPError(
        18,
        @"DISPLAY_RESIZE_FAILED",
        @"FreeRDP could not send the requested desktop size through Display Control.");
}

- (BOOL)createSurfaceForContext:(rdpContext *)context
{
    if (!context || !context->gdi) {
        return NO;
    }

    JTFreeRDPFramebufferLayout layout = { 0 };
    if (!JTFreeRDPValidateFramebufferLayout(
            context->gdi->width,
            context->gdi->height,
            JTMaximumFramebufferBytes,
            &layout)) {
        return NO;
    }
    size_t width = (size_t)context->gdi->width;
    size_t height = (size_t)context->gdi->height;

    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(layout.bytesPerRow),
        (id)kIOSurfaceAllocSize: @(layout.allocationSize),
        (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA)
    };
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!surface) {
        return NO;
    }

    JTFreeRDPSurfaceCopyLayout surfaceLayout = { 0 };
    if (IOSurfaceGetWidth(surface) != width ||
        IOSurfaceGetHeight(surface) != height ||
        !JTFreeRDPValidateSurfaceCopyLayout(
            context->gdi->width,
            context->gdi->height,
            (int64_t)layout.bytesPerRow,
            IOSurfaceGetBytesPerRow(surface),
            IOSurfaceGetAllocSize(surface),
            JTMaximumFramebufferBytes,
            &surfaceLayout)) {
        CFRelease(surface);
        return NO;
    }

    [self.stateLock lock];
    if (!self.engineState ||
        self.engineState->instance != context->instance ||
        !self.engineState->gdiInitialized) {
        [self.stateLock unlock];
        CFRelease(surface);
        return NO;
    }
    IOSurfaceRef previous = self.engineState->surface;
    self.engineState->surface = surface;
    self.latestFrameMetadata = @{};
    [self.stateLock unlock];
    if (previous) {
        CFRelease(previous);
    }
    return YES;
}

- (void)clearSurface
{
    [self.stateLock lock];
    IOSurfaceRef surface = self.engineState ? self.engineState->surface : NULL;
    if (self.engineState) {
        self.engineState->surface = NULL;
    }
    self.latestFrameMetadata = @{};
    [self.stateLock unlock];
    if (!surface) {
        return;
    }

    if (IOSurfaceLock(surface, 0, NULL) == kIOReturnSuccess) {
        void *baseAddress = IOSurfaceGetBaseAddress(surface);
        size_t allocationSize = IOSurfaceGetAllocSize(surface);
        if (baseAddress && allocationSize <= JTMaximumFramebufferBytes) {
            memset(baseAddress, 0, allocationSize);
        }
        IOSurfaceUnlock(surface, 0, NULL);
    }
    CFRelease(surface);
}

- (BOOL)handleBeginPaint:(rdpContext *)context
{
    if (!context || !context->gdi || !context->gdi->primary ||
        !context->gdi->primary->hdc || !context->gdi->primary->hdc->hwnd ||
        !context->gdi->primary->hdc->hwnd->invalid) {
        return FALSE;
    }
    context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

- (BOOL)handleEndPaint:(rdpContext *)context
{
    rdpGdi *gdi = context ? context->gdi : NULL;
    [self.stateLock lock];
    JTFreeRDPEngineState *engineState = self.engineState;
    IOSurfaceRef surface = engineState ? engineState->surface : NULL;
    GDI_BITMAP *sourceBitmap =
        (gdi && gdi->primary) ? gdi->primary->bitmap : NULL;
    if (!gdi || gdi->context != context ||
        !JTFreeRDPValidatePaintState(
            engineState,
            engineState ? engineState->instance : NULL,
            context ? context->instance : NULL,
            engineState ? engineState->gdiInitialized : false,
            surface) ||
        !sourceBitmap ||
        !JTFreeRDPValidateSourceBitmap(
            gdi->width,
            gdi->height,
            gdi->stride,
            sourceBitmap->width,
            sourceBitmap->height,
            sourceBitmap->scanline,
            gdi->primary_buffer,
            sourceBitmap->data)) {
        [self.stateLock unlock];
        return FALSE;
    }

    JTFreeRDPDirtyRect dirtyRect = {
        .x = 0,
        .y = 0,
        .width = gdi->width,
        .height = gdi->height,
    };
    GDI_WND *window = gdi->primary && gdi->primary->hdc ? gdi->primary->hdc->hwnd : NULL;
    if (window && window->invalid && !window->invalid->null) {
        if (!JTFreeRDPIntersectDirtyRect(
                gdi->width,
                gdi->height,
                window->invalid->x,
                window->invalid->y,
                window->invalid->w,
                window->invalid->h,
                &dirtyRect)) {
            [self.stateLock unlock];
            return TRUE;
        }
    }

    if (IOSurfaceLock(surface, 0, NULL) != kIOReturnSuccess) {
        [self.stateLock unlock];
        return FALSE;
    }
    BYTE *destination = IOSurfaceGetBaseAddress(surface);
    size_t destinationStride = IOSurfaceGetBytesPerRow(surface);
    size_t destinationAllocationSize = IOSurfaceGetAllocSize(surface);
    JTFreeRDPSurfaceCopyLayout copyLayout = { 0 };
    JTFreeRDPCopyRegion copyRegion = { 0 };
    if (!destination ||
        IOSurfaceGetWidth(surface) != (size_t)gdi->width ||
        IOSurfaceGetHeight(surface) != (size_t)gdi->height ||
        !JTFreeRDPValidateSurfaceCopyLayout(
            gdi->width,
            gdi->height,
            gdi->stride,
            destinationStride,
            destinationAllocationSize,
            JTMaximumFramebufferBytes,
            &copyLayout) ||
        !JTFreeRDPValidateCopyRegion(
            gdi->width,
            gdi->height,
            &copyLayout,
            dirtyRect,
            &copyRegion)) {
        IOSurfaceUnlock(surface, 0, NULL);
        [self.stateLock unlock];
        return FALSE;
    }
    for (INT32 row = 0; row < dirtyRect.height; row++) {
        memcpy(
            destination + copyRegion.destinationFirstByteOffset +
                (size_t)row * copyLayout.destinationStride,
            gdi->primary_buffer + copyRegion.sourceFirstByteOffset +
                (size_t)row * copyLayout.sourceStride,
            copyRegion.rowBytes);
    }
    IOSurfaceUnlock(surface, 0, NULL);
    uint32_t surfaceSeed = IOSurfaceGetSeed(surface);

    uint64_t revision = [self nextStateRevision];
    NSDictionary *metadata = @{
        @"sessionId": self.sessionID ?: @"",
        @"connectionAttemptId": self.connectionAttemptIdentifier ?: @"",
        @"frameId": NSUUID.UUID.UUIDString,
        @"stateRevision": @(revision),
        @"width": @(gdi->width),
        @"height": @(gdi->height),
        @"bytesPerRow": @(copyLayout.destinationStride),
        @"pixelFormat": @"BGRA32",
        @"dirtyX": @(dirtyRect.x),
        @"dirtyY": @(dirtyRect.y),
        @"dirtyWidth": @(dirtyRect.width),
        @"dirtyHeight": @(dirtyRect.height),
        @"capturedAt": @([NSDate date].timeIntervalSince1970),
        @"surfaceSeed": @(surfaceSeed)
    };
    self.latestFrameMetadata = metadata;
    CFRetain(surface);
    [self.stateLock unlock];
    [self.delegate rdpEngineDidUpdateSurface:(__bridge IOSurface *)surface metadata:metadata];
    CFRelease(surface);
    return TRUE;
}

- (BOOL)handleDesktopResize:(rdpContext *)context
{
    if (!context || !context->gdi || !context->settings) {
        return FALSE;
    }
    UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!JTFreeRDPValidateFramebufferLayout(
            width,
            height,
            JTMaximumFramebufferBytes,
            NULL)) {
        [self notifyState:@"failed"
                     code:@"RDP_RESOLUTION_REJECTED"
                  message:@"The RDP server requested a framebuffer outside the supported safety limits."];
        return FALSE;
    }
    if (!gdi_resize(context->gdi, width, height)) {
        return FALSE;
    }
    return [self createSurfaceForContext:context];
}

- (BOOL)isDVCChannelConnected
{
    [self.dvcChannelLock lock];
    BOOL connected = self.engineState && self.engineState->dvcChannel != NULL;
    [self.dvcChannelLock unlock];
    return connected;
}

- (void)clearDVCChannel
{
    [self.dvcChannelLock lock];
    if (self.engineState) {
        self.engineState->dvcChannel = NULL;
        self.engineState->dvcGeneration = JTNextDVCGeneration(
            self.engineState->dvcGeneration);
    }
    [self.dvcChannelLock unlock];
}

- (NSError * _Nullable)writeDVCMessage:(NSData *)message
                   expectedGeneration:(uint64_t)expectedGeneration
{
    BOOL shouldNotifyWriteFailure = NO;
    NSError *failure = nil;
    [self.dvcChannelLock lock];
    IWTSVirtualChannel *channel = self.engineState ? self.engineState->dvcChannel : NULL;
    uint64_t currentGeneration = self.engineState
        ? self.engineState->dvcGeneration : 0;
    NSError *generationError = JTFreeRDPDVCGenerationValidationError(
        @{ @"expectedDVCGeneration": @(expectedGeneration) },
        currentGeneration);
    if (generationError) {
        failure = generationError;
    } else if (!channel) {
        failure = JTFreeRDPError(
            5,
            @"COMPANION_REQUIRED",
            @"Windows Companion disconnected before the queued message executed.");
    } else {
        UINT writeResult = ERROR_INVALID_PARAMETER;
        if (channel->Write && message.length > 0 && message.length <= UINT32_MAX) {
            writeResult = channel->Write(
                channel,
                (ULONG)message.length,
                message.bytes,
                NULL);
        }
        if (writeResult != CHANNEL_RC_OK &&
            self.engineState && self.engineState->dvcChannel == channel &&
            self.engineState->dvcGeneration == expectedGeneration) {
            self.engineState->dvcChannel = NULL;
            self.engineState->dvcGeneration = JTNextDVCGeneration(
                self.engineState->dvcGeneration);
            shouldNotifyWriteFailure = YES;
        }
        if (writeResult != CHANNEL_RC_OK) {
            failure = JTFreeRDPError(
                16,
                @"COMPANION_WRITE_FAILED",
                @"The Windows Companion channel rejected the queued message.");
        }
    }
    [self.dvcChannelLock unlock];

    if (shouldNotifyWriteFailure) {
        [self notifyState:@"connected"
                     code:@"COMPANION_WRITE_FAILED"
                  message:@"The Windows Companion channel rejected an outbound message and was disabled; desktop viewing and input remain available."];
    }
    return failure;
}

- (BOOL)handleDVCOpenCallback:(JTCompanionDVCChannelCallback *)callback
{
    BOOL didOpen = NO;
    [self.dvcChannelLock lock];
    [self.dvcCallbackReleasePool trackPointer:callback];
    IWTSVirtualChannel *channel = callback ? callback->base.channel : NULL;
    if (self.engineState && channel) {
        uint64_t generation = JTNextDVCGeneration(
            self.engineState->dvcGeneration);
        self.engineState->dvcChannel = channel;
        self.engineState->dvcGeneration = generation;
        callback->generation = generation;
        didOpen = YES;
    }
    [self.dvcChannelLock unlock];
    if (didOpen) {
        [self notifyState:@"connected" code:nil message:nil];
    }
    return didOpen;
}

- (void)handleDVCCloseAndRetireCallback:(JTCompanionDVCChannelCallback *)callback
{
    BOOL shouldNotifyClose = NO;
    [self.dvcChannelLock lock];
    [self.dvcCallbackReleasePool trackPointer:callback];
    IWTSVirtualChannel *channel = callback ? callback->base.channel : NULL;
    uint64_t callbackGeneration = callback ? callback->generation : 0;
    if (self.engineState && self.engineState->dvcChannel == channel &&
        callbackGeneration != 0 &&
        self.engineState->dvcGeneration == callbackGeneration) {
        self.engineState->dvcChannel = NULL;
        self.engineState->dvcGeneration = JTNextDVCGeneration(
            self.engineState->dvcGeneration);
        shouldNotifyClose = YES;
    }
    // A local Write can enter OnClose while an inbound OnData callback has
    // already captured this pointer and is blocked on the lifecycle lock.
    // Keep it alive until context teardown joins FreeRDP's channel worker.
    [self.dvcChannelLock unlock];

    if (shouldNotifyClose) {
        [self notifyState:@"connected"
                     code:@"COMPANION_DISCONNECTED"
                  message:@"The Windows Companion DVC closed; desktop viewing and input remain available."];
    }
}

- (void)handleDVCData:(const BYTE *)bytes
               length:(size_t)length
             callback:(JTCompanionDVCChannelCallback *)callback
{
    if (!bytes || length == 0 || length > JTMaximumDVCMessageBytes || !callback) {
        return;
    }
    NSData *message = [NSData dataWithBytes:bytes length:length];
    [self.dvcChannelLock lock];
    uint64_t generation = callback->generation;
    BOOL isCurrentChannel = self.engineState && generation != 0 &&
        self.engineState->dvcChannel == callback->base.channel &&
        self.engineState->dvcGeneration == generation;
#if DEBUG
    JTLogCompanionDVCDispatch(length, generation,
                             self.engineState ? self.engineState->dvcGeneration : 0,
                             isCurrentChannel && self.delegate != nil);
#endif
    if (isCurrentChannel) {
        NSDictionary<NSString *, id> *metadata = @{
            @"sessionId": self.sessionID ?: @"",
            @"connectionAttemptId": self.connectionAttemptIdentifier ?: @"",
            @"companionDVCGeneration": @(generation)
        };
        [self.delegate rdpEngineDidReceiveDVCMessage:message metadata:metadata];
    }
    [self.dvcChannelLock unlock];
}

- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
         didReceiveUTF8Text:(NSData *)text
{
    if (bridge != self.clipboardBridge || !bridge.isEnabled ||
        text.length > JTFreeRDPTextClipboardMaximumUTF8Bytes) {
        return;
    }
    NSDictionary<NSString *, id> *metadata = @{
        @"sessionId": self.sessionID ?: @"",
        @"connectionAttemptId": self.connectionAttemptIdentifier ?: @"",
        @"clipboardIsolationGeneration": @(self.clipboardIsolationGeneration)
    };
    [self.delegate rdpEngineDidReceiveClipboardText:text metadata:metadata];
}

- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
didAcknowledgeLocalFormatList:(NSString *)acknowledgementIdentifier
                    accepted:(BOOL)accepted
{
    if (bridge != self.clipboardBridge || !bridge.isEnabled ||
        acknowledgementIdentifier.length == 0) {
        return;
    }
    NSError *error = accepted
        ? nil
        : JTFreeRDPError(
            17,
            @"RDP_CLIPBOARD_ANNOUNCE_REJECTED",
            @"Windows rejected the clipboard format update.");
    [self completeClipboardAcknowledgement:acknowledgementIdentifier
                                     error:error];
}

- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
didUpdateFileTransferReadiness:(BOOL)ready
{
    if (bridge != self.clipboardBridge || !bridge.isEnabled) {
        return;
    }
    [self.stateLock lock];
    BOOL connected = self.engineState && self.engineState->connected;
    [self.stateLock unlock];
    if (connected) {
        [self notifyState:@"connected" code:nil message:nil];
    }
}

- (void)handleChannelConnected:(const ChannelConnectedEventArgs *)event
{
    if (!event || !event->name) {
        return;
    }
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        self.engineState->displayControl = (DispClientContext *)event->pInterface;
        return;
    }
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0 &&
        self.clipboardBridge.isEnabled) {
        (void)[self.clipboardBridge
            attachContext:(CliprdrClientContext *)event->pInterface];
        return;
    }
}

- (void)handleChannelDisconnected:(const ChannelDisconnectedEventArgs *)event
{
    if (!event || !event->name) {
        return;
    }
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        self.engineState->displayControl = NULL;
        return;
    }
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        [self.clipboardBridge
            detachContext:(CliprdrClientContext *)event->pInterface];
        return;
    }
}

- (int)verifyPinnedCertificatePEM:(const BYTE *)data
                           length:(size_t)length
                         hostname:(const char *)hostname
                             port:(UINT16)port
                            flags:(DWORD)flags
{
    if (!data || length == 0 || length > JTMaximumCertificateChainBytes) {
        [self notifyState:@"failed"
                     code:@"RDP_CERTIFICATE_INVALID"
                  message:@"The RDP certificate chain was empty or exceeded the safety limit."];
        return 0;
    }

    NSString *normalized = JTLeafCertificateSHA256FromPEM(data, length);
    if (normalized.length != 64) {
        [self notifyState:@"failed"
                     code:@"RDP_CERTIFICATE_INVALID"
                  message:@"JTS Terminal could not decode the leaf RDP certificate fingerprint."];
        return 0;
    }
    BOOL hasPinnedFingerprint = self.pinnedFingerprint.length == 64;
    BOOL hasTrustOnceFingerprint = !hasPinnedFingerprint && self.trustOnceFingerprint.length == 64;
    NSString *expected = hasPinnedFingerprint
        ? self.pinnedFingerprint
        : (hasTrustOnceFingerprint ? self.trustOnceFingerprint : nil);
    BOOL hasExpectedFingerprint = expected.length == 64;
    BOOL certificateChanged = hasExpectedFingerprint || (flags & VERIFY_CERT_FLAG_CHANGED) != 0;
    BOOL exactMatch = normalized.length == 64 && expected.length == 64 &&
        [normalized isEqualToString:expected];
    if (exactMatch) {
        return 2;
    }

    NSDictionary *challenge = @{
        @"sessionId": self.sessionID ?: @"",
        @"connectionAttemptId": self.connectionAttemptIdentifier ?: @"",
        @"host": [self stringFromCString:hostname fallback:@""],
        @"port": @(port),
        @"commonName": @"",
        @"subject": @"",
        @"issuer": @"",
        @"sha256": normalized ?: @"",
        @"oldSha256": expected ?: @"",
        @"changed": @(certificateChanged),
        @"hostMismatch": @((BOOL)((flags & VERIFY_CERT_FLAG_MISMATCH) != 0)),
        @"pinnedMismatch": @(hasPinnedFingerprint),
        @"flags": @(flags)
    };

    [self notifyState:@"awaitingCertificateTrust"
                 code:certificateChanged ? @"RDP_CERTIFICATE_CHANGED" : @"RDP_CERTIFICATE_UNTRUSTED"
              message:(certificateChanged
                  ? (hasPinnedFingerprint
                      ? @"The RDP certificate no longer matches the pinned SHA-256 fingerprint. The connection was blocked."
                      : @"The RDP certificate no longer matches the fingerprint trusted for this connection. The connection was blocked.")
                  : @"The RDP certificate requires an explicit trust decision.")
          certificate:challenge];
    [self.delegate rdpEngineDidRequireCertificateDecision:challenge];
    return 0;
}

- (DWORD)verifyCertificateForHost:(const char *)host
                             port:(UINT16)port
                       commonName:(const char *)commonName
                          subject:(const char *)subject
                           issuer:(const char *)issuer
                      fingerprint:(const char *)fingerprint
                            flags:(DWORD)flags
                          changed:(BOOL)changed
                   oldFingerprint:(const char *)oldFingerprint
{
    NSString *normalized = [self certificateFingerprintFromCString:fingerprint flags:flags];
    if (normalized.length != 64) {
        [self notifyState:@"failed"
                     code:@"RDP_CERTIFICATE_INVALID"
                  message:@"JTS Terminal could not decode the leaf RDP certificate fingerprint."];
        return 0;
    }

    NSString *oldNormalized = [self certificateFingerprintFromCString:oldFingerprint flags:flags];
    BOOL hasPinnedFingerprint = self.pinnedFingerprint.length == 64;
    BOOL hasTrustOnceFingerprint = !hasPinnedFingerprint && self.trustOnceFingerprint.length == 64;
    NSString *expected = hasPinnedFingerprint
        ? self.pinnedFingerprint
        : (hasTrustOnceFingerprint ? self.trustOnceFingerprint : nil);
    BOOL exactPinMatch = expected.length == 64 && [normalized isEqualToString:expected];

    if (exactPinMatch) {
        return 2;
    }

    BOOL pinnedMismatch = hasPinnedFingerprint && ![self.pinnedFingerprint isEqualToString:normalized];
    BOOL trustOnceMismatch = hasTrustOnceFingerprint && ![self.trustOnceFingerprint isEqualToString:normalized];
    BOOL certificateChanged = changed || pinnedMismatch || trustOnceMismatch ||
        (flags & VERIFY_CERT_FLAG_CHANGED) != 0;
    NSString *previousFingerprint = expected ?: oldNormalized;

    NSDictionary *certificate = @{
        @"sessionId": self.sessionID ?: @"",
        @"connectionAttemptId": self.connectionAttemptIdentifier ?: @"",
        @"host": [self stringFromCString:host fallback:@""],
        @"port": @(port),
        @"commonName": [self stringFromCString:commonName fallback:@""],
        @"subject": [self stringFromCString:subject fallback:@""],
        @"issuer": [self stringFromCString:issuer fallback:@""],
        @"sha256": normalized ?: @"",
        @"oldSha256": previousFingerprint ?: @"",
        @"changed": @(certificateChanged),
        @"hostMismatch": @((BOOL)((flags & VERIFY_CERT_FLAG_MISMATCH) != 0)),
        @"pinnedMismatch": @(pinnedMismatch),
        @"flags": @(flags)
    };
    [self notifyState:@"awaitingCertificateTrust"
                 code:certificateChanged ? @"RDP_CERTIFICATE_CHANGED" : @"RDP_CERTIFICATE_UNTRUSTED"
              message:(certificateChanged
                  ? (pinnedMismatch
                      ? @"The RDP certificate no longer matches the pinned SHA-256 fingerprint. The connection was blocked."
                      : @"The RDP certificate changed. The connection was blocked.")
                  : @"The RDP certificate requires an explicit trust decision.")
          certificate:certificate];
    [self.delegate rdpEngineDidRequireCertificateDecision:certificate];
    return 0;
}

- (nullable NSString *)certificateFingerprintFromCString:(const char *)fingerprint
                                                    flags:(DWORD)flags
{
    if (!fingerprint) {
        return nil;
    }
    if ((flags & VERIFY_CERT_FLAG_FP_IS_PEM) != 0) {
        size_t length = strnlen(fingerprint, JTMaximumCertificateChainBytes + 1);
        if (length == 0 || length > JTMaximumCertificateChainBytes) {
            return nil;
        }
        return JTLeafCertificateSHA256FromPEM((const BYTE *)fingerprint, length);
    }
    return [self.class normalizeFingerprint:[self stringFromCString:fingerprint fallback:@""]];
}

- (void)notifyState:(NSString *)phase
               code:(nullable NSString *)code
            message:(nullable NSString *)message
{
    [self notifyState:phase code:code message:message certificate:nil];
}

- (void)notifyState:(NSString *)phase
               code:(nullable NSString *)code
            message:(nullable NSString *)message
        certificate:(nullable NSDictionary<NSString *, id> *)certificate
{
    uint64_t revision = [self nextStateRevision];
    [self.dvcChannelLock lock];
    BOOL companionConnected = self.engineState && self.engineState->dvcChannel != NULL;
    uint64_t companionGeneration = self.engineState
        ? self.engineState->dvcGeneration : 0;
    [self.dvcChannelLock unlock];
    NSMutableDictionary *state = [@{
        @"sessionId": self.sessionID ?: @"",
        @"connectionAttemptId": self.connectionAttemptIdentifier ?: @"",
        @"phase": phase,
        @"stateRevision": @(revision),
        @"runtime": @"FreeRDP",
        @"runtimeVersion": [NSString stringWithUTF8String:FREERDP_VERSION],
        @"companionDVCConnected": @(companionConnected),
        @"companionDVCGeneration": @(companionGeneration),
        @"companionInstallerClipboardReady": @(self.clipboardBridge.fileTransferReady)
    } mutableCopy];
    if (code) {
        state[@"code"] = code;
    }
    if (message) {
        state[@"message"] = message;
    }
    if (certificate) {
        state[@"certificate"] = certificate;
    }
    [self.delegate rdpEngineDidChangeState:state];
}

- (uint64_t)nextStateRevision
{
    @synchronized (self) {
        self.engineState->stateRevision += 1;
        return self.engineState->stateRevision;
    }
}

- (void)finishWithCode:(NSString *)code message:(NSString *)message
{
    // Initialization can fail before FreeRDP consumes the private descriptor.
    // Release the unused endpoint so the bridge can observe the failure.
    @synchronized (self) {
        [self.relaySocket closeFile];
        self.relaySocket = nil;
    }
    self.running = NO;
    [self notifyState:self.disconnectRequested ? @"closed" : @"failed"
                 code:self.disconnectRequested ? nil : code
              message:self.disconnectRequested ? nil : message];
}

- (NSString *)stringFromCString:(const char *)value fallback:(NSString *)fallback
{
    if (!value) {
        return fallback;
    }
    NSString *string = [NSString stringWithUTF8String:value];
    return string ?: fallback;
}

@end
