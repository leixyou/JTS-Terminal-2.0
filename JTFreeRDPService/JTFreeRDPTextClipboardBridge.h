#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct s_cliprdr_client_context CliprdrClientContext;

#define JTFreeRDPTextClipboardMaximumUTF8Bytes (4u * 1024u * 1024u)
// UTF-16LE doubles ASCII bytes, and CRLF normalization can double an
// all-newline payload once more.
#define JTFreeRDPTextClipboardMaximumWireBytes (16u * 1024u * 1024u + 2u)
#define JTFreeRDPFileClipboardMaximumRangeBytes (4u * 1024u * 1024u)

@class JTFreeRDPTextClipboardBridge;

@protocol JTFreeRDPTextClipboardBridgeDelegate <NSObject>

- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
         didReceiveUTF8Text:(NSData *)text;
- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
didAcknowledgeLocalFormatList:(NSString *)acknowledgementIdentifier
                    accepted:(BOOL)accepted;

@optional

/// Reports bounded, path-free progress for the currently offered file.
/// The metadata keys are limited to `fileName`, `fileSize`, `bytesServed`,
/// `completed`, and optionally `errorCode`.
- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
      didUpdateFileTransfer:(NSDictionary<NSString *, id> *)metadata;

/// Reports whether Windows negotiated the streamed, path-free file clipboard
/// capabilities required by the fixed Companion installer offer.
- (void)textClipboardBridge:(JTFreeRDPTextClipboardBridge *)bridge
didUpdateFileTransferReadiness:(BOOL)ready;

@end

/// Implements bounded `cliprdr` client callbacks. The bridge never reads a
/// system pasteboard. In addition to text, it can expose one pre-opened,
/// hash-verified local file under a caller-supplied basename. It never
/// advertises the source path and never accepts remote-to-local file content.
@interface JTFreeRDPTextClipboardBridge : NSObject

@property (nonatomic, weak, nullable) id<JTFreeRDPTextClipboardBridgeDelegate> delegate;
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly, getter=isFileTransferReady) BOOL fileTransferReady;

- (instancetype)initWithEnabled:(BOOL)enabled NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)attachContext:(CliprdrClientContext *)context;
- (void)detachContext:(CliprdrClientContext *)context;
- (void)detachCurrentContext;

/// Updates the local text advertised to Windows. `nil` advertises an empty
/// supported-format list. Calls must be serialized with the FreeRDP event
/// loop so channel writes cannot race connection teardown.
- (BOOL)updateLocalUTF8Text:(nullable NSData *)text error:(NSError **)error;

/// Updates the local text and associates the resulting `CB_FORMAT_LIST` with
/// an acknowledgement identifier. The delegate is called only after Windows
/// returns the matching `CB_FORMAT_LIST_RESPONSE`. This is used as a
/// protocol-level barrier before AI desktop control can begin.
- (BOOL)updateLocalUTF8Text:(nullable NSData *)text
 acknowledgementIdentifier:(nullable NSString *)acknowledgementIdentifier
                      error:(NSError **)error;

/// Establishes or releases the AI-control clipboard boundary. Isolation first
/// suppresses remote-to-local intake and then advertises an empty local format
/// list. Resume keeps intake suppressed until Windows acknowledges the current
/// human text offer. The acknowledgement identifier is completed through the
/// delegate only after the matching `CB_FORMAT_LIST_RESPONSE`.
- (BOOL)setAIControlIsolation:(BOOL)isolated
                localUTF8Text:(nullable NSData *)text
    acknowledgementIdentifier:(NSString *)acknowledgementIdentifier
                         error:(NSError **)error;

/// Replaces the local clipboard offer with one regular file. The file is
/// opened without following a final symlink, verified against the expected
/// lowercase-or-uppercase hexadecimal SHA-256, and held by descriptor so later
/// requests cannot redirect the bridge to a different path. Only the supplied
/// basename is sent to Windows.
- (BOOL)offerFileAtURL:(NSURL *)fileURL
        remoteFileName:(NSString *)remoteFileName
        expectedSHA256:(NSString *)expectedSHA256
acknowledgementIdentifier:(nullable NSString *)acknowledgementIdentifier
                 error:(NSError **)error;

/// Revokes the current file offer immediately. File-content requests received
/// after this call are rejected. If clipboard monitoring is ready, the bridge
/// advertises the current text formats (or an empty list) and optionally waits
/// for the matching Windows acknowledgement.
- (BOOL)clearFileOfferWithAcknowledgementIdentifier:
            (nullable NSString *)acknowledgementIdentifier
                                              error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
