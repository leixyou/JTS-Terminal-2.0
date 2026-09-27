// CoreFoundation's legacy COM aliases collide with WinPR's Windows-compatible
// declarations. Match the guard used by the RDP engine and FreeRDP itself.
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

#import "JTFreeRDPTextClipboardBridge.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/client/cliprdr.h>
#include <winpr/clipboard.h>
#include <winpr/error.h>
#include <winpr/file.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString * const JTFreeRDPTextClipboardErrorDomain =
    @"com.lljts.JTSTerminal.FreeRDPTextClipboard";
static const UINT32 JTFreeRDPMaximumRemoteClipboardFormats = 4096;
static const NSUInteger JTFreeRDPMaximumPendingFormatLists = 4096;
static const uint64_t JTFreeRDPFileClipboardMaximumFileBytes =
    (2ULL * 1024ULL * 1024ULL * 1024ULL) - 1ULL;
static const UINT32 JTFreeRDPFileGroupDescriptorFormatID = 0x0000C0A1;
static const NSUInteger JTFreeRDPPackedFileDescriptorBytes = 592;
static char JTFreeRDPFileGroupDescriptorFormatName[] =
    "FileGroupDescriptorW";

static NSError *JTClipboardError(NSString *code, NSString *message)
{
    return [NSError errorWithDomain:JTFreeRDPTextClipboardErrorDomain
                               code:1
                           userInfo:@{
                               NSLocalizedDescriptionKey: message,
                               @"JTFreeRDPErrorCode": code
                           }];
}

static BOOL JTIsValidSHA256(NSString *value)
{
    if (value.length != CC_SHA256_DIGEST_LENGTH * 2) {
        return NO;
    }
    static NSCharacterSet *nonHexadecimalCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        nonHexadecimalCharacters = [[NSCharacterSet
            characterSetWithCharactersInString:@"0123456789abcdefABCDEF"]
            invertedSet];
    });
    return [value rangeOfCharacterFromSet:nonHexadecimalCharacters].location ==
        NSNotFound;
}

static BOOL JTIsReservedWindowsBaseName(NSString *fileName)
{
    NSString *stem = [[fileName componentsSeparatedByString:@"."]
        firstObject].uppercaseString;
    if ([stem isEqualToString:@"CON"] ||
        [stem isEqualToString:@"PRN"] ||
        [stem isEqualToString:@"AUX"] ||
        [stem isEqualToString:@"NUL"]) {
        return YES;
    }
    if (stem.length == 4) {
        NSString *prefix = [stem substringToIndex:3];
        unichar suffix = [stem characterAtIndex:3];
        if (([prefix isEqualToString:@"COM"] ||
             [prefix isEqualToString:@"LPT"]) &&
            suffix >= '1' && suffix <= '9') {
            return YES;
        }
    }
    return NO;
}

static BOOL JTIsValidRemoteFileName(NSString *fileName)
{
    if (fileName.length == 0 || fileName.length >= 260 ||
        [fileName isEqualToString:@"."] ||
        [fileName isEqualToString:@".."] ||
        [fileName hasSuffix:@" "] ||
        [fileName hasSuffix:@"."] ||
        JTIsReservedWindowsBaseName(fileName)) {
        return NO;
    }
    static NSCharacterSet *invalidCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *characters =
            [[NSCharacterSet controlCharacterSet] mutableCopy];
        [characters addCharactersInString:@"<>:\"/\\|?*"];
        invalidCharacters = [characters copy];
    });
    return [fileName rangeOfCharacterFromSet:invalidCharacters].location ==
        NSNotFound;
}

static NSString * _Nullable JTSHA256ForFileDescriptor(
    int fileDescriptor,
    NSError **error)
{
    CC_SHA256_CTX context;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (CC_SHA256_Init(&context) != 1) {
#pragma clang diagnostic pop
        if (error) {
            *error = JTClipboardError(
                @"RDP_FILE_OFFER_HASH_FAILED",
                @"The Companion installer could not be hashed.");
        }
        return nil;
    }

    uint8_t buffer[64 * 1024];
    off_t offset = 0;
    for (;;) {
        ssize_t count = pread(
            fileDescriptor,
            buffer,
            sizeof(buffer),
            offset);
        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            if (error) {
                *error = JTClipboardError(
                    @"RDP_FILE_OFFER_HASH_FAILED",
                    @"The Companion installer could not be read for verification.");
            }
            return nil;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (CC_SHA256_Update(&context, buffer, (CC_LONG)count) != 1) {
#pragma clang diagnostic pop
            if (error) {
                *error = JTClipboardError(
                    @"RDP_FILE_OFFER_HASH_FAILED",
                    @"The Companion installer hash could not be updated.");
            }
            return nil;
        }
        offset += count;
    }

    uint8_t digest[CC_SHA256_DIGEST_LENGTH] = { 0 };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (CC_SHA256_Final(digest, &context) != 1) {
#pragma clang diagnostic pop
        if (error) {
            *error = JTClipboardError(
                @"RDP_FILE_OFFER_HASH_FAILED",
                @"The Companion installer hash could not be completed.");
        }
        return nil;
    }
    NSMutableString *result = [NSMutableString
        stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger index = 0; index < sizeof(digest); index++) {
        [result appendFormat:@"%02x", digest[index]];
    }
    return result;
}

static void JTWriteUInt16LittleEndian(
    NSMutableData *data,
    NSUInteger offset,
    uint16_t value)
{
    uint8_t *bytes = data.mutableBytes;
    bytes[offset] = (uint8_t)(value & 0xFF);
    bytes[offset + 1] = (uint8_t)(value >> 8);
}

static void JTWriteUInt32LittleEndian(
    NSMutableData *data,
    NSUInteger offset,
    uint32_t value)
{
    uint8_t *bytes = data.mutableBytes;
    bytes[offset] = (uint8_t)(value & 0xFF);
    bytes[offset + 1] = (uint8_t)((value >> 8) & 0xFF);
    bytes[offset + 2] = (uint8_t)((value >> 16) & 0xFF);
    bytes[offset + 3] = (uint8_t)((value >> 24) & 0xFF);
}

static NSData *JTPackedSingleFileList(
    NSString *remoteFileName,
    uint64_t fileSize)
{
    // MS-RDPECLIP 2.2.5.2.3: cItems followed by one packed 592-byte
    // FILEDESCRIPTORW. Reserved structures and FILETIMEs remain zero.
    NSMutableData *data = [NSMutableData
        dataWithLength:sizeof(uint32_t) +
            JTFreeRDPPackedFileDescriptorBytes];
    JTWriteUInt32LittleEndian(data, 0, 1);
    NSUInteger descriptorOffset = sizeof(uint32_t);
    JTWriteUInt32LittleEndian(
        data,
        descriptorOffset,
        FD_ATTRIBUTES | FD_FILESIZE | FD_PROGRESSUI);
    JTWriteUInt32LittleEndian(
        data,
        descriptorOffset + 36,
        FILE_ATTRIBUTE_NORMAL);
    JTWriteUInt32LittleEndian(
        data,
        descriptorOffset + 64,
        (uint32_t)(fileSize >> 32));
    JTWriteUInt32LittleEndian(
        data,
        descriptorOffset + 68,
        (uint32_t)(fileSize & UINT32_MAX));
    NSUInteger nameOffset = descriptorOffset + 72;
    for (NSUInteger index = 0; index < remoteFileName.length; index++) {
        JTWriteUInt16LittleEndian(
            data,
            nameOffset + index * sizeof(uint16_t),
            [remoteFileName characterAtIndex:index]);
    }
    return data;
}

static NSString *JTWindowsNewlines(NSString *text)
{
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\r\n"
                                                            withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\r"
                                                        withString:@"\n"];
    return [normalized stringByReplacingOccurrencesOfString:@"\n"
                                                 withString:@"\r\n"];
}

static NSString *JTMacNewlines(NSString *text)
{
    NSString *normalized = [text stringByReplacingOccurrencesOfString:@"\r\n"
                                                            withString:@"\n"];
    return [normalized stringByReplacingOccurrencesOfString:@"\r"
                                                 withString:@"\n"];
}

static NSData * _Nullable JTUnicodePayload(NSString *text)
{
    NSMutableData *payload = [[JTWindowsNewlines(text)
        dataUsingEncoding:NSUTF16LittleEndianStringEncoding
     allowLossyConversion:NO] mutableCopy];
    if (!payload || payload.length > JTFreeRDPTextClipboardMaximumWireBytes - 2) {
        return nil;
    }
    const uint8_t terminator[2] = { 0, 0 };
    [payload appendBytes:terminator length:sizeof(terminator)];
    return payload;
}

static NSData * _Nullable JTLegacyPayload(NSString *text)
{
    NSMutableData *payload = [[JTWindowsNewlines(text)
        dataUsingEncoding:NSWindowsCP1252StringEncoding
     allowLossyConversion:YES] mutableCopy];
    if (!payload || payload.length >= JTFreeRDPTextClipboardMaximumWireBytes) {
        return nil;
    }
    const uint8_t terminator = 0;
    [payload appendBytes:&terminator length:sizeof(terminator)];
    return payload;
}

static NSUInteger JTUTF16TerminatorOffset(NSData *data)
{
    const uint8_t *bytes = data.bytes;
    for (NSUInteger offset = 0; offset + 1 < data.length; offset += 2) {
        if (bytes[offset] == 0 && bytes[offset + 1] == 0) {
            return offset;
        }
    }
    return data.length;
}

static NSString * _Nullable JTStringFromRemotePayload(
    UINT32 format,
    const BYTE *bytes,
    NSUInteger length)
{
    if (!bytes || length == 0 ||
        length > JTFreeRDPTextClipboardMaximumWireBytes) {
        return nil;
    }

    NSData *payload = [NSData dataWithBytes:bytes length:length];
    NSString *text = nil;
    if (format == CF_UNICODETEXT) {
        if (payload.length % 2 != 0) {
            return nil;
        }
        NSUInteger textLength = JTUTF16TerminatorOffset(payload);
        text = [[NSString alloc]
            initWithData:[payload subdataWithRange:NSMakeRange(0, textLength)]
                encoding:NSUTF16LittleEndianStringEncoding];
        if ([text hasPrefix:@"\uFEFF"]) {
            text = [text substringFromIndex:1];
        }
    } else if (format == CF_TEXT) {
        const uint8_t *payloadBytes = payload.bytes;
        NSUInteger textLength = 0;
        while (textLength < payload.length && payloadBytes[textLength] != 0) {
            textLength += 1;
        }
        NSData *textData = [payload subdataWithRange:NSMakeRange(0, textLength)];
        text = [[NSString alloc] initWithData:textData
                                     encoding:NSWindowsCP1252StringEncoding];
    }
    return text ? JTMacNewlines(text) : nil;
}

@interface JTClipboardFormatAnnouncement : NSObject

@property (nonatomic, copy, nullable) NSString *acknowledgementIdentifier;
@property (nonatomic) BOOL resumeRemoteReceiveOnSuccess;
@property (nonatomic) uint64_t isolationTransitionGeneration;

@end

@implementation JTClipboardFormatAnnouncement
@end

@interface JTClipboardFileOffer : NSObject

@property (nonatomic, readonly) int fileDescriptor;
@property (nonatomic, copy, readonly) NSString *remoteFileName;
@property (nonatomic, copy, readonly) NSString *expectedSHA256;
@property (nonatomic, readonly) uint64_t fileSize;
@property (nonatomic) uint64_t maximumServedOffset;
@property (nonatomic) BOOL servedFirstRange;
@property (nonatomic) BOOL reachedEndOfFile;

- (instancetype)initWithFileDescriptor:(int)fileDescriptor
                        remoteFileName:(NSString *)remoteFileName
                        expectedSHA256:(NSString *)expectedSHA256
                              fileSize:(uint64_t)fileSize;

@end

@implementation JTClipboardFileOffer

- (instancetype)initWithFileDescriptor:(int)fileDescriptor
                        remoteFileName:(NSString *)remoteFileName
                        expectedSHA256:(NSString *)expectedSHA256
                              fileSize:(uint64_t)fileSize
{
    self = [super init];
    if (self) {
        _fileDescriptor = fileDescriptor;
        _remoteFileName = [remoteFileName copy];
        _expectedSHA256 = [expectedSHA256 copy];
        _fileSize = fileSize;
    }
    return self;
}

- (void)dealloc
{
    if (_fileDescriptor >= 0) {
        close(_fileDescriptor);
    }
}

@end

@interface JTFreeRDPTextClipboardBridge ()

@property (nonatomic, readwrite, getter=isEnabled) BOOL enabled;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) CliprdrClientContext *context;
@property (nonatomic) BOOL monitorReady;
@property (nonatomic, copy, nullable) NSData *localUnicodePayload;
@property (nonatomic, copy, nullable) NSData *localLegacyPayload;
@property (nonatomic) UINT32 requestedRemoteFormat;
@property (nonatomic) BOOL discardRequestedRemoteResponse;
@property (nonatomic) UINT32 pendingRemoteFormat;
@property (nonatomic) BOOL remoteReceiveSuppressed;
@property (nonatomic) uint64_t isolationTransitionGeneration;
@property (nonatomic, strong, nullable) JTClipboardFileOffer *fileOffer;
@property (nonatomic) UINT32 serverGeneralCapabilityFlags;
@property (nonatomic) BOOL serverCapabilitiesReady;
@property (nonatomic, strong)
    NSMutableArray<JTClipboardFormatAnnouncement *> *pendingFormatListAnnouncements;

- (UINT)sendCapabilities:(CliprdrClientContext *)context;
- (UINT)sendCurrentFormatList:(CliprdrClientContext *)context
    acknowledgementIdentifier:(nullable NSString *)acknowledgementIdentifier
  resumeRemoteReceiveOnSuccess:(BOOL)resumeRemoteReceiveOnSuccess
 isolationTransitionGeneration:(uint64_t)isolationTransitionGeneration;
- (BOOL)applyLocalUTF8Text:(nullable NSData *)text
 acknowledgementIdentifier:(nullable NSString *)acknowledgementIdentifier
resumeRemoteReceiveOnSuccess:(BOOL)resumeRemoteReceiveOnSuccess
isolationTransitionGeneration:(uint64_t)isolationTransitionGeneration
      allowWhileSuppressed:(BOOL)allowWhileSuppressed
                     error:(NSError **)error;
- (UINT)requestRemoteFormat:(UINT32)format
                    context:(CliprdrClientContext *)context;
- (UINT)handleMonitorReady:(CliprdrClientContext *)context;
- (UINT)handleServerCapabilities:(CliprdrClientContext *)context
                    capabilities:(const CLIPRDR_CAPABILITIES *)capabilities;
- (UINT)handleServerFormatList:(CliprdrClientContext *)context
                    formatList:(const CLIPRDR_FORMAT_LIST *)formatList;
- (UINT)handleServerFormatListResponse:(CliprdrClientContext *)context
                              response:(const CLIPRDR_FORMAT_LIST_RESPONSE *)response;
- (UINT)handleServerFormatDataRequest:(CliprdrClientContext *)context
                              request:(const CLIPRDR_FORMAT_DATA_REQUEST *)request;
- (UINT)handleServerFormatDataResponse:(CliprdrClientContext *)context
                               response:(const CLIPRDR_FORMAT_DATA_RESPONSE *)response;
- (UINT)handleServerFileContentsRequest:(CliprdrClientContext *)context
                                request:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request;
- (UINT)sendFileContentsFailure:(CliprdrClientContext *)context
                        request:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request;
- (UINT)sendFileContentsResponse:(CliprdrClientContext *)context
                         request:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request
                            data:(nullable const void *)data
                          length:(UINT32)length;
- (void)notifyFileOffer:(JTClipboardFileOffer *)offer
              errorCode:(nullable NSString *)errorCode;
- (BOOL)isCurrentContext:(CliprdrClientContext *)context;
- (NSArray<NSString *> *)acknowledgedIdentifiersAndClearPendingLocked;
- (void)rejectAcknowledgements:(NSArray<NSString *> *)acknowledgementIdentifiers;

@end

static JTFreeRDPTextClipboardBridge * _Nullable JTBridge(
    CliprdrClientContext *context)
{
    if (!context || !context->custom) {
        return nil;
    }
    return (__bridge JTFreeRDPTextClipboardBridge *)context->custom;
}

static UINT JTClipboardMonitorReady(
    CliprdrClientContext *context,
    const CLIPRDR_MONITOR_READY *monitorReady)
{
    if (!monitorReady) {
        return ERROR_INVALID_PARAMETER;
    }
    JTFreeRDPTextClipboardBridge *bridge = JTBridge(context);
    return bridge ? [bridge handleMonitorReady:context] : ERROR_INVALID_PARAMETER;
}

static UINT JTClipboardServerCapabilities(
    CliprdrClientContext *context,
    const CLIPRDR_CAPABILITIES *capabilities)
{
    if (!capabilities) {
        return ERROR_INVALID_PARAMETER;
    }
    JTFreeRDPTextClipboardBridge *bridge = JTBridge(context);
    return bridge
        ? [bridge handleServerCapabilities:context capabilities:capabilities]
        : ERROR_INVALID_PARAMETER;
}

static UINT JTClipboardServerFormatList(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_LIST *formatList)
{
    if (!formatList) {
        return ERROR_INVALID_PARAMETER;
    }
    JTFreeRDPTextClipboardBridge *bridge = JTBridge(context);
    return bridge
        ? [bridge handleServerFormatList:context formatList:formatList]
        : ERROR_INVALID_PARAMETER;
}

static UINT JTClipboardServerFormatListResponse(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_LIST_RESPONSE *response)
{
    if (!response) {
        return ERROR_INVALID_PARAMETER;
    }
    JTFreeRDPTextClipboardBridge *bridge = JTBridge(context);
    return bridge
        ? [bridge handleServerFormatListResponse:context response:response]
        : ERROR_INVALID_PARAMETER;
}

static UINT JTClipboardServerFormatDataRequest(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
    if (!request) {
        return ERROR_INVALID_PARAMETER;
    }
    JTFreeRDPTextClipboardBridge *bridge = JTBridge(context);
    return bridge
        ? [bridge handleServerFormatDataRequest:context request:request]
        : ERROR_INVALID_PARAMETER;
}

static UINT JTClipboardServerFormatDataResponse(
    CliprdrClientContext *context,
    const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    if (!response) {
        return ERROR_INVALID_PARAMETER;
    }
    JTFreeRDPTextClipboardBridge *bridge = JTBridge(context);
    return bridge
        ? [bridge handleServerFormatDataResponse:context response:response]
        : ERROR_INVALID_PARAMETER;
}

static UINT JTClipboardUnsupportedLock(
    CliprdrClientContext *context,
    const CLIPRDR_LOCK_CLIPBOARD_DATA *request)
{
    return context && request ? CHANNEL_RC_OK : ERROR_INVALID_PARAMETER;
}

static UINT JTClipboardUnsupportedUnlock(
    CliprdrClientContext *context,
    const CLIPRDR_UNLOCK_CLIPBOARD_DATA *request)
{
    return context && request ? CHANNEL_RC_OK : ERROR_INVALID_PARAMETER;
}

static UINT JTClipboardServerFileContentsRequest(
    CliprdrClientContext *context,
    const CLIPRDR_FILE_CONTENTS_REQUEST *request)
{
    if (!context || !request) {
        return ERROR_INVALID_PARAMETER;
    }
    JTFreeRDPTextClipboardBridge *bridge = JTBridge(context);
    return bridge
        ? [bridge handleServerFileContentsRequest:context request:request]
        : ERROR_INVALID_PARAMETER;
}

static UINT JTClipboardUnsupportedFileResponse(
    CliprdrClientContext *context,
    const CLIPRDR_FILE_CONTENTS_RESPONSE *response)
{
    return context && response ? ERROR_NOT_SUPPORTED : ERROR_INVALID_PARAMETER;
}

@implementation JTFreeRDPTextClipboardBridge

- (instancetype)initWithEnabled:(BOOL)enabled
{
    self = [super init];
    if (self) {
        _enabled = enabled;
        _lock = [[NSLock alloc] init];
        _pendingFormatListAnnouncements = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isFileTransferReady
{
    [self.lock lock];
    BOOL ready = self.serverCapabilitiesReady &&
        (self.serverGeneralCapabilityFlags & CB_STREAM_FILECLIP_ENABLED) != 0 &&
        (self.serverGeneralCapabilityFlags & CB_FILECLIP_NO_FILE_PATHS) != 0;
    [self.lock unlock];
    return ready;
}

- (BOOL)attachContext:(CliprdrClientContext *)context
{
    if (!self.enabled || !context) {
        return NO;
    }

    [self.lock lock];
    if (self.context && self.context != context) {
        [self.lock unlock];
        return NO;
    }
    self.context = context;
    self.monitorReady = NO;
    self.requestedRemoteFormat = 0;
    self.discardRequestedRemoteResponse = NO;
    self.pendingRemoteFormat = 0;
    self.serverGeneralCapabilityFlags = 0;
    self.serverCapabilitiesReady = NO;
    context->custom = (__bridge void *)self;
    context->MonitorReady = JTClipboardMonitorReady;
    context->ServerCapabilities = JTClipboardServerCapabilities;
    context->ServerFormatList = JTClipboardServerFormatList;
    context->ServerFormatListResponse = JTClipboardServerFormatListResponse;
    context->ServerLockClipboardData = JTClipboardUnsupportedLock;
    context->ServerUnlockClipboardData = JTClipboardUnsupportedUnlock;
    context->ServerFormatDataRequest = JTClipboardServerFormatDataRequest;
    context->ServerFormatDataResponse = JTClipboardServerFormatDataResponse;
    context->ServerFileContentsRequest = JTClipboardServerFileContentsRequest;
    context->ServerFileContentsResponse = JTClipboardUnsupportedFileResponse;
    [self.lock unlock];
    return YES;
}

- (void)detachContext:(CliprdrClientContext *)context
{
    NSArray<NSString *> *abandonedAcknowledgements = @[];
    JTClipboardFileOffer *abandonedFileOffer = nil;
    [self.lock lock];
    if (context && self.context == context) {
        context->custom = NULL;
        self.context = NULL;
        self.monitorReady = NO;
        self.requestedRemoteFormat = 0;
        self.discardRequestedRemoteResponse = NO;
        self.pendingRemoteFormat = 0;
        self.serverGeneralCapabilityFlags = 0;
        self.serverCapabilitiesReady = NO;
        abandonedFileOffer = self.fileOffer;
        self.fileOffer = nil;
        abandonedAcknowledgements = [self acknowledgedIdentifiersAndClearPendingLocked];
    }
    [self.lock unlock];
    [self rejectAcknowledgements:abandonedAcknowledgements];
    if (abandonedFileOffer && !abandonedFileOffer.reachedEndOfFile) {
        [self notifyFileOffer:abandonedFileOffer
                   errorCode:@"RDP_FILE_TRANSFER_DISCONNECTED"];
    }
}

- (void)detachCurrentContext
{
    NSArray<NSString *> *abandonedAcknowledgements = @[];
    JTClipboardFileOffer *abandonedFileOffer = nil;
    [self.lock lock];
    CliprdrClientContext *context = self.context;
    if (context) {
        context->custom = NULL;
    }
    self.context = NULL;
    self.monitorReady = NO;
    self.requestedRemoteFormat = 0;
    self.discardRequestedRemoteResponse = NO;
    self.pendingRemoteFormat = 0;
    self.serverGeneralCapabilityFlags = 0;
    self.serverCapabilitiesReady = NO;
    abandonedFileOffer = self.fileOffer;
    self.fileOffer = nil;
    abandonedAcknowledgements = [self acknowledgedIdentifiersAndClearPendingLocked];
    [self.lock unlock];
    [self rejectAcknowledgements:abandonedAcknowledgements];
    if (abandonedFileOffer && !abandonedFileOffer.reachedEndOfFile) {
        [self notifyFileOffer:abandonedFileOffer
                   errorCode:@"RDP_FILE_TRANSFER_DISCONNECTED"];
    }
}

- (NSArray<NSString *> *)acknowledgedIdentifiersAndClearPendingLocked
{
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (JTClipboardFormatAnnouncement *announcement
         in self.pendingFormatListAnnouncements) {
        if (announcement.acknowledgementIdentifier.length > 0) {
            [identifiers addObject:announcement.acknowledgementIdentifier];
        }
    }
    [self.pendingFormatListAnnouncements removeAllObjects];
    return identifiers;
}

- (void)rejectAcknowledgements:(NSArray<NSString *> *)acknowledgementIdentifiers
{
    id<JTFreeRDPTextClipboardBridgeDelegate> delegate = self.delegate;
    for (NSString *identifier in acknowledgementIdentifiers) {
        [delegate textClipboardBridge:self
        didAcknowledgeLocalFormatList:identifier
                             accepted:NO];
    }
}

- (BOOL)updateLocalUTF8Text:(NSData * _Nullable)text error:(NSError **)error
{
    return [self updateLocalUTF8Text:text
           acknowledgementIdentifier:nil
                                error:error];
}

- (BOOL)updateLocalUTF8Text:(NSData * _Nullable)text
 acknowledgementIdentifier:(NSString * _Nullable)acknowledgementIdentifier
                      error:(NSError **)error
{
    return [self applyLocalUTF8Text:text
          acknowledgementIdentifier:acknowledgementIdentifier
       resumeRemoteReceiveOnSuccess:NO
      isolationTransitionGeneration:0
             allowWhileSuppressed:NO
                            error:error];
}

- (BOOL)setAIControlIsolation:(BOOL)isolated
                localUTF8Text:(NSData * _Nullable)text
    acknowledgementIdentifier:(NSString *)acknowledgementIdentifier
                         error:(NSError **)error
{
    if (acknowledgementIdentifier.length == 0 || (isolated && text != nil)) {
        if (error) {
            *error = JTClipboardError(
                @"RDP_CLIPBOARD_ISOLATION_INVALID",
                @"Clipboard isolation requires a request identifier and an empty pause payload.");
        }
        return NO;
    }
    [self.lock lock];
    if (self.fileOffer) {
        [self.lock unlock];
        if (error) {
            *error = JTClipboardError(
                @"RDP_CLIPBOARD_FILE_OFFER_ACTIVE",
                @"Revoke the Companion installer offer before changing clipboard isolation.");
        }
        return NO;
    }
    self.isolationTransitionGeneration =
        self.isolationTransitionGeneration == UINT64_MAX
            ? 1
            : self.isolationTransitionGeneration + 1;
    uint64_t transitionGeneration = self.isolationTransitionGeneration;
    self.remoteReceiveSuppressed = YES;
    if (self.requestedRemoteFormat != 0) {
        self.discardRequestedRemoteResponse = YES;
    }
    self.pendingRemoteFormat = 0;
    [self.lock unlock];
    return [self applyLocalUTF8Text:isolated ? nil : text
          acknowledgementIdentifier:acknowledgementIdentifier
       resumeRemoteReceiveOnSuccess:!isolated
      isolationTransitionGeneration:transitionGeneration
             allowWhileSuppressed:YES
                            error:error];
}

- (BOOL)offerFileAtURL:(NSURL *)fileURL
        remoteFileName:(NSString *)remoteFileName
        expectedSHA256:(NSString *)expectedSHA256
acknowledgementIdentifier:(NSString * _Nullable)acknowledgementIdentifier
                 error:(NSError **)error
{
    if (!self.enabled) {
        if (error) {
            *error = JTClipboardError(
                @"RDP_CLIPBOARD_DISABLED",
                @"Clipboard redirection is disabled for this RDP profile.");
        }
        return NO;
    }
    if (!self.fileTransferReady) {
        if (error) {
            *error = JTClipboardError(
                @"RDP_FILE_CLIPBOARD_UNAVAILABLE",
                @"Windows did not negotiate streamed, path-free clipboard file transfer for this RDP session.");
        }
        return NO;
    }
    if (!fileURL.isFileURL || !JTIsValidRemoteFileName(remoteFileName) ||
        !JTIsValidSHA256(expectedSHA256)) {
        if (error) {
            *error = JTClipboardError(
                @"RDP_FILE_OFFER_INVALID",
                @"The Companion installer offer is missing a valid file, Windows basename, or SHA-256.");
        }
        return NO;
    }

    const char *path = fileURL.fileSystemRepresentation;
    if (!path) {
        if (error) {
            *error = JTClipboardError(
                @"RDP_FILE_OFFER_INVALID",
                @"The Companion installer location is not a valid file-system path.");
        }
        return NO;
    }
    int fileDescriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fileDescriptor < 0) {
        if (error) {
            *error = JTClipboardError(
                @"RDP_FILE_OFFER_OPEN_FAILED",
                @"The Companion installer could not be opened securely.");
        }
        return NO;
    }

    struct stat status = { 0 };
    if (fstat(fileDescriptor, &status) != 0 ||
        !S_ISREG(status.st_mode) ||
        status.st_size < 0 ||
        (uint64_t)status.st_size > JTFreeRDPFileClipboardMaximumFileBytes) {
        close(fileDescriptor);
        if (error) {
            *error = JTClipboardError(
                @"RDP_FILE_OFFER_UNSUPPORTED",
                @"The Companion installer must be a regular file smaller than 2 GiB.");
        }
        return NO;
    }

    NSError *hashError = nil;
    NSString *actualSHA256 = JTSHA256ForFileDescriptor(
        fileDescriptor,
        &hashError);
    if (!actualSHA256 ||
        [actualSHA256 caseInsensitiveCompare:expectedSHA256] !=
            NSOrderedSame) {
        close(fileDescriptor);
        if (error) {
            *error = hashError ?: JTClipboardError(
                @"RDP_FILE_OFFER_HASH_MISMATCH",
                @"The Companion installer did not match its expected SHA-256.");
        }
        return NO;
    }

    JTClipboardFileOffer *offer = [[JTClipboardFileOffer alloc]
        initWithFileDescriptor:fileDescriptor
               remoteFileName:remoteFileName
               expectedSHA256:actualSHA256
                     fileSize:(uint64_t)status.st_size];

    [self.lock lock];
    JTClipboardFileOffer *previousOffer = self.fileOffer;
    self.fileOffer = offer;
    CliprdrClientContext *context = self.monitorReady ? self.context : NULL;
    [self.lock unlock];

    if (!context) {
        if (acknowledgementIdentifier.length > 0) {
            [self.lock lock];
            if (self.fileOffer == offer) {
                self.fileOffer = previousOffer;
            }
            [self.lock unlock];
            if (error) {
                *error = JTClipboardError(
                    @"RDP_CLIPBOARD_NOT_READY",
                    @"Windows clipboard redirection is not ready to acknowledge the installer offer.");
            }
            return NO;
        }
        [self notifyFileOffer:offer errorCode:nil];
        return YES;
    }

    UINT result = [self
        sendCurrentFormatList:context
    acknowledgementIdentifier:acknowledgementIdentifier
  resumeRemoteReceiveOnSuccess:NO
 isolationTransitionGeneration:0];
    if (result != CHANNEL_RC_OK) {
        [self.lock lock];
        if (self.fileOffer == offer) {
            self.fileOffer = previousOffer;
        }
        [self.lock unlock];
        if (error) {
            *error = JTClipboardError(
                @"RDP_FILE_OFFER_ANNOUNCE_FAILED",
                @"FreeRDP rejected the Companion installer clipboard offer.");
        }
        return NO;
    }
    [self notifyFileOffer:offer errorCode:nil];
    return YES;
}

- (BOOL)clearFileOfferWithAcknowledgementIdentifier:
            (NSString * _Nullable)acknowledgementIdentifier
                                              error:(NSError **)error
{
    if (!self.enabled) {
        if (error) {
            *error = JTClipboardError(
                @"RDP_CLIPBOARD_DISABLED",
                @"Clipboard redirection is disabled for this RDP profile.");
        }
        return NO;
    }

    [self.lock lock];
    self.fileOffer = nil;
    CliprdrClientContext *context = self.monitorReady ? self.context : NULL;
    [self.lock unlock];
    if (!context) {
        if (acknowledgementIdentifier.length > 0 && error) {
            *error = JTClipboardError(
                @"RDP_CLIPBOARD_NOT_READY",
                @"Windows clipboard redirection is not ready to acknowledge the installer revocation.");
        }
        return acknowledgementIdentifier.length == 0;
    }

    UINT result = [self
        sendCurrentFormatList:context
    acknowledgementIdentifier:acknowledgementIdentifier
  resumeRemoteReceiveOnSuccess:NO
 isolationTransitionGeneration:0];
    if (result != CHANNEL_RC_OK && error) {
        *error = JTClipboardError(
            @"RDP_FILE_OFFER_CLEAR_FAILED",
            @"FreeRDP rejected the Companion installer clipboard revocation.");
    }
    return result == CHANNEL_RC_OK;
}

- (BOOL)applyLocalUTF8Text:(NSData * _Nullable)text
 acknowledgementIdentifier:(NSString * _Nullable)acknowledgementIdentifier
resumeRemoteReceiveOnSuccess:(BOOL)resumeRemoteReceiveOnSuccess
isolationTransitionGeneration:(uint64_t)isolationTransitionGeneration
      allowWhileSuppressed:(BOOL)allowWhileSuppressed
                     error:(NSError **)error
{
    if (!self.enabled) {
        if (error) {
            *error = JTClipboardError(
                @"RDP_CLIPBOARD_DISABLED",
                @"Text clipboard redirection is disabled for this RDP profile.");
        }
        return NO;
    }
    if (text.length > JTFreeRDPTextClipboardMaximumUTF8Bytes) {
        if (error) {
            *error = JTClipboardError(
                @"RDP_CLIPBOARD_TEXT_TOO_LARGE",
                @"Clipboard text exceeds the 4 MiB transfer limit.");
        }
        return NO;
    }

    NSData *unicodePayload = nil;
    NSData *legacyPayload = nil;
    if (text) {
        NSString *string = [[NSString alloc] initWithData:text
                                                  encoding:NSUTF8StringEncoding];
        if (!string ||
            [string rangeOfString:@"\0"].location != NSNotFound) {
            if (error) {
                *error = JTClipboardError(
                    @"RDP_CLIPBOARD_TEXT_INVALID",
                    @"Clipboard text must be valid UTF-8 without embedded null characters.");
            }
            return NO;
        }
        unicodePayload = JTUnicodePayload(string);
        legacyPayload = JTLegacyPayload(string);
        if (!unicodePayload || !legacyPayload) {
            if (error) {
                *error = JTClipboardError(
                    @"RDP_CLIPBOARD_TEXT_TOO_LARGE",
                    @"Clipboard text exceeds the bounded RDP wire representation.");
            }
            return NO;
        }
    }

    [self.lock lock];
    if (self.fileOffer) {
        [self.lock unlock];
        if (error) {
            *error = JTClipboardError(
                @"RDP_CLIPBOARD_FILE_OFFER_ACTIVE",
                @"Revoke the Companion installer offer before synchronizing clipboard text.");
        }
        return NO;
    }
    if (self.remoteReceiveSuppressed && !allowWhileSuppressed) {
        [self.lock unlock];
        if (error) {
            *error = JTClipboardError(
                @"RDP_CLIPBOARD_AI_ISOLATED",
                @"Human clipboard synchronization is paused while AI control is active.");
        }
        return NO;
    }
    self.localUnicodePayload = unicodePayload;
    self.localLegacyPayload = legacyPayload;
    CliprdrClientContext *context = self.monitorReady ? self.context : NULL;
    [self.lock unlock];

    if (!context) {
        if (acknowledgementIdentifier.length > 0) {
            if (error) {
                *error = JTClipboardError(
                    @"RDP_CLIPBOARD_NOT_READY",
                    @"Windows clipboard redirection is not ready to acknowledge the update.");
            }
            return NO;
        }
        return YES;
    }
    UINT result = [self
        sendCurrentFormatList:context
    acknowledgementIdentifier:acknowledgementIdentifier
  resumeRemoteReceiveOnSuccess:resumeRemoteReceiveOnSuccess
 isolationTransitionGeneration:isolationTransitionGeneration];
    if (result != CHANNEL_RC_OK && error) {
        *error = JTClipboardError(
            @"RDP_CLIPBOARD_ANNOUNCE_FAILED",
            @"FreeRDP rejected the local clipboard format update.");
    }
    return result == CHANNEL_RC_OK;
}

- (UINT)sendCapabilities:(CliprdrClientContext *)context
{
    if (![self isCurrentContext:context] || !context->ClientCapabilities) {
        return ERROR_INVALID_PARAMETER;
    }
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    // The bridge exposes one path-free, sub-2-GiB local file. Clipboard
    // locking and huge-file support deliberately remain absent.
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES |
        CB_STREAM_FILECLIP_ENABLED |
        CB_FILECLIP_NO_FILE_PATHS;

    CLIPRDR_CAPABILITIES capabilities = { 0 };
    capabilities.common.msgType = CB_CLIP_CAPS;
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    return context->ClientCapabilities(context, &capabilities);
}

- (UINT)sendCurrentFormatList:(CliprdrClientContext *)context
    acknowledgementIdentifier:(NSString * _Nullable)acknowledgementIdentifier
  resumeRemoteReceiveOnSuccess:(BOOL)resumeRemoteReceiveOnSuccess
 isolationTransitionGeneration:(uint64_t)isolationTransitionGeneration
{
    if (![self isCurrentContext:context] || !context->ClientFormatList) {
        return ERROR_INVALID_PARAMETER;
    }

    [self.lock lock];
    BOOL hasText = self.localUnicodePayload != nil;
    BOOL hasFileOffer = self.fileOffer != nil;
    [self.lock unlock];

    CLIPRDR_FORMAT formats[2] = {
        { .formatId = CF_UNICODETEXT, .formatName = NULL },
        { .formatId = CF_TEXT, .formatName = NULL }
    };
    CLIPRDR_FORMAT fileFormat = {
        .formatId = JTFreeRDPFileGroupDescriptorFormatID,
        .formatName = JTFreeRDPFileGroupDescriptorFormatName
    };
    CLIPRDR_FORMAT_LIST formatList = { 0 };
    formatList.common.msgType = CB_FORMAT_LIST;
    formatList.numFormats = hasFileOffer ? 1 : (hasText ? 2 : 0);
    formatList.formats = hasFileOffer
        ? &fileFormat
        : (hasText ? formats : NULL);

    JTClipboardFormatAnnouncement *announcement =
        [[JTClipboardFormatAnnouncement alloc] init];
    announcement.acknowledgementIdentifier =
        acknowledgementIdentifier.length > 0
            ? [acknowledgementIdentifier copy]
            : nil;
    announcement.resumeRemoteReceiveOnSuccess =
        resumeRemoteReceiveOnSuccess;
    announcement.isolationTransitionGeneration =
        isolationTransitionGeneration;
    [self.lock lock];
    if (self.pendingFormatListAnnouncements.count >=
        JTFreeRDPMaximumPendingFormatLists) {
        [self.lock unlock];
        return ERROR_NOT_ENOUGH_MEMORY;
    }
    [self.pendingFormatListAnnouncements addObject:announcement];
    [self.lock unlock];

    UINT result = context->ClientFormatList(context, &formatList);
    if (result != CHANNEL_RC_OK) {
        [self.lock lock];
        NSUInteger index = [self.pendingFormatListAnnouncements
            indexOfObjectIdenticalTo:announcement];
        if (index != NSNotFound) {
            [self.pendingFormatListAnnouncements removeObjectAtIndex:index];
        }
        [self.lock unlock];
    }
    return result;
}

- (UINT)handleMonitorReady:(CliprdrClientContext *)context
{
    if (![self isCurrentContext:context]) {
        return ERROR_INVALID_PARAMETER;
    }
    UINT result = [self sendCapabilities:context];
    if (result != CHANNEL_RC_OK) {
        return result;
    }
    [self.lock lock];
    self.monitorReady = YES;
    [self.lock unlock];
    return [self sendCurrentFormatList:context
             acknowledgementIdentifier:nil
           resumeRemoteReceiveOnSuccess:NO
          isolationTransitionGeneration:0];
}

- (UINT)handleServerCapabilities:(CliprdrClientContext *)context
                    capabilities:(const CLIPRDR_CAPABILITIES *)capabilities
{
    if (![self isCurrentContext:context] || !capabilities ||
        capabilities->cCapabilitiesSets > 32 ||
        (capabilities->cCapabilitiesSets > 0 && !capabilities->capabilitySets)) {
        return ERROR_INVALID_PARAMETER;
    }

    BOOL foundGeneral = NO;
    UINT32 generalFlags = 0;
    for (UINT32 index = 0; index < capabilities->cCapabilitiesSets; index++) {
        const CLIPRDR_CAPABILITY_SET *capability =
            &capabilities->capabilitySets[index];
        if (capability->capabilitySetType == CB_CAPSTYPE_GENERAL &&
            capability->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN) {
            const CLIPRDR_GENERAL_CAPABILITY_SET *general =
                (const CLIPRDR_GENERAL_CAPABILITY_SET *)capability;
            foundGeneral = YES;
            generalFlags = general->generalFlags;
            break;
        }
    }

    [self.lock lock];
    BOOL oldReady = self.serverCapabilitiesReady &&
        (self.serverGeneralCapabilityFlags & CB_STREAM_FILECLIP_ENABLED) != 0 &&
        (self.serverGeneralCapabilityFlags & CB_FILECLIP_NO_FILE_PATHS) != 0;
    self.serverCapabilitiesReady = foundGeneral;
    self.serverGeneralCapabilityFlags = generalFlags;
    BOOL newReady = foundGeneral &&
        (generalFlags & CB_STREAM_FILECLIP_ENABLED) != 0 &&
        (generalFlags & CB_FILECLIP_NO_FILE_PATHS) != 0;
    [self.lock unlock];

    if (oldReady != newReady) {
        id<JTFreeRDPTextClipboardBridgeDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:
                @selector(textClipboardBridge:didUpdateFileTransferReadiness:)]) {
            [delegate textClipboardBridge:self
                didUpdateFileTransferReadiness:newReady];
        }
    }
    return CHANNEL_RC_OK;
}

- (UINT)handleServerFormatList:(CliprdrClientContext *)context
                    formatList:(const CLIPRDR_FORMAT_LIST *)formatList
{
    if (![self isCurrentContext:context] || !formatList ||
        !context->ClientFormatListResponse ||
        formatList->numFormats > JTFreeRDPMaximumRemoteClipboardFormats ||
        (formatList->numFormats > 0 && !formatList->formats)) {
        return ERROR_INVALID_PARAMETER;
    }

    CLIPRDR_FORMAT_LIST_RESPONSE listResponse = { 0 };
    listResponse.common.msgType = CB_FORMAT_LIST_RESPONSE;
    listResponse.common.msgFlags = CB_RESPONSE_OK;
    UINT result = context->ClientFormatListResponse(context, &listResponse);
    if (result != CHANNEL_RC_OK) {
        return result;
    }

    UINT32 selectedFormat = 0;
    for (UINT32 index = 0; index < formatList->numFormats; index++) {
        UINT32 candidate = formatList->formats[index].formatId;
        if (candidate == CF_UNICODETEXT) {
            selectedFormat = CF_UNICODETEXT;
            break;
        }
        if (candidate == CF_TEXT) {
            selectedFormat = CF_TEXT;
        }
    }
    [self.lock lock];
    if (self.remoteReceiveSuppressed) {
        self.pendingRemoteFormat = 0;
        [self.lock unlock];
        return CHANNEL_RC_OK;
    }
    if (self.requestedRemoteFormat != 0) {
        self.pendingRemoteFormat = selectedFormat;
        [self.lock unlock];
        return CHANNEL_RC_OK;
    }
    self.requestedRemoteFormat = selectedFormat;
    self.pendingRemoteFormat = 0;
    [self.lock unlock];
    if (selectedFormat == 0) {
        return CHANNEL_RC_OK;
    }
    UINT requestResult = [self requestRemoteFormat:selectedFormat context:context];
    if (requestResult != CHANNEL_RC_OK) {
        [self.lock lock];
        if (self.requestedRemoteFormat == selectedFormat) {
            self.requestedRemoteFormat = 0;
            self.discardRequestedRemoteResponse = NO;
        }
        [self.lock unlock];
    }
    return requestResult;
}

- (UINT)requestRemoteFormat:(UINT32)format
                    context:(CliprdrClientContext *)context
{
    if ((format != CF_UNICODETEXT && format != CF_TEXT) ||
        !context || !context->ClientFormatDataRequest) {
        return ERROR_INVALID_PARAMETER;
    }
    CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = format;
    return context->ClientFormatDataRequest(context, &request);
}

- (UINT)handleServerFormatListResponse:(CliprdrClientContext *)context
                              response:(const CLIPRDR_FORMAT_LIST_RESPONSE *)response
{
    if (![self isCurrentContext:context] || !response) {
        return ERROR_INVALID_PARAMETER;
    }
    [self.lock lock];
    if (self.pendingFormatListAnnouncements.count == 0) {
        [self.lock unlock];
        return ERROR_INVALID_DATA;
    }
    JTClipboardFormatAnnouncement *announcement =
        self.pendingFormatListAnnouncements.firstObject;
    [self.pendingFormatListAnnouncements removeObjectAtIndex:0];
    BOOL accepted = (response->common.msgFlags & CB_RESPONSE_OK) != 0 &&
        (response->common.msgFlags & CB_RESPONSE_FAIL) == 0;
    if (accepted && announcement.resumeRemoteReceiveOnSuccess &&
        announcement.isolationTransitionGeneration != 0 &&
        announcement.isolationTransitionGeneration ==
            self.isolationTransitionGeneration) {
        self.remoteReceiveSuppressed = NO;
    }
    [self.lock unlock];

    if (announcement.acknowledgementIdentifier.length > 0) {
        id<JTFreeRDPTextClipboardBridgeDelegate> delegate = self.delegate;
        [delegate
                    textClipboardBridge:self
            didAcknowledgeLocalFormatList:announcement.acknowledgementIdentifier
                               accepted:accepted];
    }
    return CHANNEL_RC_OK;
}

- (UINT)handleServerFormatDataRequest:(CliprdrClientContext *)context
                              request:(const CLIPRDR_FORMAT_DATA_REQUEST *)request
{
    if (![self isCurrentContext:context] || !request ||
        !context->ClientFormatDataResponse) {
        return ERROR_INVALID_PARAMETER;
    }

    [self.lock lock];
    JTClipboardFileOffer *fileOffer = self.fileOffer;
    NSData *payload = !fileOffer &&
        request->requestedFormatId == CF_UNICODETEXT
            ? self.localUnicodePayload
            : !fileOffer && request->requestedFormatId == CF_TEXT
                ? self.localLegacyPayload
                : nil;
    [self.lock unlock];

    NSData *serializedFileList = nil;
    if (fileOffer &&
        request->requestedFormatId ==
            JTFreeRDPFileGroupDescriptorFormatID) {
        serializedFileList = JTPackedSingleFileList(
            fileOffer.remoteFileName,
            fileOffer.fileSize);
    }

    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    if (serializedFileList) {
        response.common.msgFlags = CB_RESPONSE_OK;
        response.common.dataLen = (UINT32)serializedFileList.length;
        response.requestedFormatData = serializedFileList.bytes;
    } else {
        response.common.msgFlags = payload ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
        response.common.dataLen = (UINT32)payload.length;
        response.requestedFormatData = payload.bytes;
    }
    return context->ClientFormatDataResponse(context, &response);
}

- (UINT)handleServerFormatDataResponse:(CliprdrClientContext *)context
                               response:(const CLIPRDR_FORMAT_DATA_RESPONSE *)response
{
    if (![self isCurrentContext:context] || !response) {
        return ERROR_INVALID_PARAMETER;
    }
    [self.lock lock];
    UINT32 requestedFormat = self.requestedRemoteFormat;
    BOOL discardRequestedResponse = self.discardRequestedRemoteResponse;
    self.requestedRemoteFormat = 0;
    self.discardRequestedRemoteResponse = NO;
    BOOL suppressed = self.remoteReceiveSuppressed;
    UINT32 pendingFormat = suppressed ? 0 : self.pendingRemoteFormat;
    self.pendingRemoteFormat = 0;
    if (pendingFormat == CF_UNICODETEXT || pendingFormat == CF_TEXT) {
        self.requestedRemoteFormat = pendingFormat;
    } else {
        pendingFormat = 0;
    }
    [self.lock unlock];

    UINT outcome = CHANNEL_RC_OK;
    BOOL responseAccepted = (response->common.msgFlags & CB_RESPONSE_OK) != 0 &&
        (response->common.msgFlags & CB_RESPONSE_FAIL) == 0;
    if (!suppressed && !discardRequestedResponse && responseAccepted &&
        (requestedFormat == CF_UNICODETEXT || requestedFormat == CF_TEXT)) {
        NSString *string = JTStringFromRemotePayload(
            requestedFormat,
            response->requestedFormatData,
            response->common.dataLen);
        if (!string) {
            outcome = ERROR_INVALID_DATA;
        } else {
            NSData *utf8 = [string dataUsingEncoding:NSUTF8StringEncoding
                                allowLossyConversion:NO];
            if (!utf8 ||
                utf8.length > JTFreeRDPTextClipboardMaximumUTF8Bytes) {
                outcome = ERROR_INSUFFICIENT_BUFFER;
            } else {
                id<JTFreeRDPTextClipboardBridgeDelegate> delegate = self.delegate;
                [delegate textClipboardBridge:self didReceiveUTF8Text:utf8];
            }
        }
    }
    if (pendingFormat != 0) {
        UINT requestResult = [self requestRemoteFormat:pendingFormat
                                               context:context];
        if (requestResult != CHANNEL_RC_OK) {
            [self.lock lock];
            if (self.requestedRemoteFormat == pendingFormat) {
                self.requestedRemoteFormat = 0;
                self.discardRequestedRemoteResponse = NO;
            }
            [self.lock unlock];
            return requestResult;
        }
    }
    return outcome;
}

- (UINT)handleServerFileContentsRequest:(CliprdrClientContext *)context
                                request:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request
{
    if (![self isCurrentContext:context] || !request) {
        return ERROR_INVALID_PARAMETER;
    }
    if (!context->ClientFileContentsResponse) {
        return ERROR_NOT_SUPPORTED;
    }

    [self.lock lock];
    JTClipboardFileOffer *offer = self.fileOffer;
    [self.lock unlock];
    if (!offer) {
        return [self sendFileContentsFailure:context request:request];
    }

    BOOL requestsSize = request->dwFlags == FILECONTENTS_SIZE;
    BOOL requestsRange = request->dwFlags == FILECONTENTS_RANGE;
    if (request->listIndex != 0 ||
        request->haveClipDataId ||
        (!requestsSize && !requestsRange) ||
        (requestsSize &&
         (request->cbRequested != sizeof(uint64_t) ||
          request->nPositionLow != 0 ||
          request->nPositionHigh != 0)) ||
        (requestsRange &&
         (request->cbRequested == 0 ||
          request->cbRequested >
              JTFreeRDPFileClipboardMaximumRangeBytes))) {
        [self notifyFileOffer:offer
                   errorCode:@"RDP_FILE_TRANSFER_REQUEST_INVALID"];
        return [self sendFileContentsFailure:context request:request];
    }

    if (requestsSize) {
        uint8_t sizeData[sizeof(uint64_t)] = { 0 };
        for (NSUInteger index = 0; index < sizeof(sizeData); index++) {
            sizeData[index] =
                (uint8_t)((offer.fileSize >> (index * 8)) & 0xFF);
        }
        UINT result = [self sendFileContentsResponse:context
                                            request:request
                                               data:sizeData
                                             length:(UINT32)sizeof(sizeData)];
        if (result == CHANNEL_RC_OK && offer.fileSize == 0) {
            [self.lock lock];
            if (self.fileOffer == offer) {
                offer.reachedEndOfFile = YES;
            }
            [self.lock unlock];
            [self notifyFileOffer:offer errorCode:nil];
        }
        return result;
    }

    uint64_t offset = ((uint64_t)request->nPositionHigh << 32) |
        request->nPositionLow;
    if (offset > UINT64_MAX - request->cbRequested ||
        offset > offer.fileSize) {
        [self notifyFileOffer:offer
                   errorCode:@"RDP_FILE_TRANSFER_RANGE_INVALID"];
        return [self sendFileContentsFailure:context request:request];
    }
    uint64_t available = offer.fileSize - offset;
    UINT32 targetLength = (UINT32)MIN(
        available,
        (uint64_t)request->cbRequested);
    NSMutableData *data = [NSMutableData dataWithLength:targetLength];
    uint8_t *bytes = data.mutableBytes;
    UINT32 totalRead = 0;
    while (totalRead < targetLength) {
        ssize_t count = pread(
            offer.fileDescriptor,
            bytes + totalRead,
            targetLength - totalRead,
            (off_t)(offset + totalRead));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            [self notifyFileOffer:offer
                       errorCode:@"RDP_FILE_TRANSFER_READ_FAILED"];
            return [self sendFileContentsFailure:context request:request];
        }
        totalRead += (UINT32)count;
    }

    [self.lock lock];
    if (self.fileOffer != offer) {
        [self.lock unlock];
        return [self sendFileContentsFailure:context request:request];
    }
    UINT result = [self sendFileContentsResponse:context
                                         request:request
                                            data:data.bytes
                                          length:totalRead];
    if (result == CHANNEL_RC_OK) {
        uint64_t servedEnd = offset + totalRead;
        offer.servedFirstRange = YES;
        offer.maximumServedOffset =
            MAX(offer.maximumServedOffset, servedEnd);
        if (servedEnd >= offer.fileSize) {
            offer.reachedEndOfFile = YES;
        }
    }
    [self.lock unlock];

    if (result == CHANNEL_RC_OK) {
        [self notifyFileOffer:offer errorCode:nil];
    } else {
        [self notifyFileOffer:offer
                   errorCode:@"RDP_FILE_TRANSFER_RESPONSE_FAILED"];
    }
    return result;
}

- (UINT)sendFileContentsFailure:(CliprdrClientContext *)context
                        request:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request
{
    if (!context || !request || !context->ClientFileContentsResponse) {
        return ERROR_NOT_SUPPORTED;
    }
    CLIPRDR_FILE_CONTENTS_RESPONSE response = { 0 };
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_FAIL;
    response.streamId = request->streamId;
    return context->ClientFileContentsResponse(context, &response);
}

- (UINT)sendFileContentsResponse:(CliprdrClientContext *)context
                         request:(const CLIPRDR_FILE_CONTENTS_REQUEST *)request
                            data:(const void * _Nullable)data
                          length:(UINT32)length
{
    if (!context || !request || !context->ClientFileContentsResponse ||
        (length > 0 && !data)) {
        return ERROR_INVALID_PARAMETER;
    }
    CLIPRDR_FILE_CONTENTS_RESPONSE response = { 0 };
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    response.streamId = request->streamId;
    response.cbRequested = length;
    response.requestedData = data;
    return context->ClientFileContentsResponse(context, &response);
}

- (void)notifyFileOffer:(JTClipboardFileOffer *)offer
              errorCode:(NSString * _Nullable)errorCode
{
    id<JTFreeRDPTextClipboardBridgeDelegate> delegate = self.delegate;
    if (!offer ||
        ![delegate respondsToSelector:
            @selector(textClipboardBridge:didUpdateFileTransfer:)]) {
        return;
    }
    NSMutableDictionary<NSString *, id> *metadata = [@{
        @"fileName": offer.remoteFileName,
        @"fileSize": @(offer.fileSize),
        @"bytesServed": @(offer.maximumServedOffset),
        @"completed": @(offer.reachedEndOfFile)
    } mutableCopy];
    if (errorCode.length > 0) {
        metadata[@"errorCode"] = errorCode;
    }
    [delegate textClipboardBridge:self
           didUpdateFileTransfer:[metadata copy]];
}

- (BOOL)isCurrentContext:(CliprdrClientContext *)context
{
    [self.lock lock];
    BOOL current = self.enabled && context && self.context == context &&
        context->custom == (__bridge void *)self;
    [self.lock unlock];
    return current;
}

@end
