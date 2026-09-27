#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const JTFreeRDPXPCValidationErrorDomain;
FOUNDATION_EXPORT NSString * const JTFreeRDPXPCValidationErrorCodeKey;

/// A validated, process-independent request envelope. Uptime is measured from
/// the current boot, so the app and its bundled XPC service can compare the
/// same absolute deadline without trusting wall-clock time.
@interface JTFreeRDPXPCRequestEnvelope : NSObject

@property (nonatomic, copy, readonly) NSString *requestIdentifier;
@property (nonatomic, readonly) uint64_t connectionGeneration;
@property (nonatomic, copy, readonly) NSString *connectionAttemptIdentifier;
@property (nonatomic, readonly) uint64_t deadlineUptimeMilliseconds;

+ (nullable instancetype)envelopeFromDictionary:(NSDictionary<NSString *, id> *)dictionary
                           expectedGeneration:(uint64_t)expectedGeneration
                   expectedAttemptIdentifier:(NSString *)expectedAttemptIdentifier
                          currentUptimeMillis:(uint64_t)currentUptimeMilliseconds
                                        error:(NSError **)error;

@end

FOUNDATION_EXPORT uint64_t JTFreeRDPCurrentUptimeMilliseconds(void);

/// Accepts only the helper-generated, collision-resistant Windows basename
/// used for one Companion clipboard offer. No path separators, mixed case,
/// caller text, or stable filename is permitted.
FOUNDATION_EXPORT BOOL
JTFreeRDPIsValidCompanionInstallerRemoteFileName(NSString *value);

FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
JTFreeRDPSanitizedConfiguration(NSDictionary<NSString *, id> *configuration,
                                NSError **error);

FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
JTFreeRDPSanitizedInput(NSDictionary<NSString *, id> *input,
                        NSError **error);

/// Accepts either `nil` (no local text format) or a bounded, valid UTF-8
/// payload without embedded null characters.
FOUNDATION_EXPORT BOOL
JTFreeRDPValidateClipboardText(NSData * _Nullable text,
                               NSError **error);

/// Revalidates a sanitized mouse command against the exact framebuffer that
/// exists at the final execution boundary. A non-nil error means no mouse
/// event may be emitted.
FOUNDATION_EXPORT NSError * _Nullable
JTFreeRDPMouseInputValidationError(
    NSDictionary<NSString *, id> *input,
    NSDictionary<NSString *, id> *frame);

/// Revalidates a sanitized input command against the latest desktop state at
/// the execution boundary. Local manual pointer input is rebound only when
/// the framebuffer dimensions are unchanged, and other trusted local-manual
/// input is rebound to the latest revision. AI/MCP input keeps exact frame or
/// state-revision binding.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
JTFreeRDPInputCommandForExecution(
    NSDictionary<NSString *, id> *input,
    NSDictionary<NSString *, id> *frame,
    NSString *currentConnectionAttemptIdentifier,
    NSError **error);

/// Verifies that a queued helper mutation still belongs to the exact RDP
/// connection attempt for which it was accepted. `frame` is required for
/// state-bound input and omitted for attempt-bound mutations such as resize
/// and Companion DVC writes.
FOUNDATION_EXPORT NSError * _Nullable
JTFreeRDPConnectionAttemptValidationError(
    NSDictionary<NSString *, id> *command,
    NSString *currentConnectionAttemptIdentifier,
    NSDictionary<NSString *, id> * _Nullable frame);

/// Verifies that a queued Companion write still belongs to the exact dynamic
/// virtual-channel lifecycle on which the app observed it. Generations are
/// helper-owned and never accepted from untrusted message payloads.
FOUNDATION_EXPORT NSError * _Nullable
JTFreeRDPDVCGenerationValidationError(
    NSDictionary<NSString *, id> *command,
    uint64_t currentDVCGeneration);

FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
JTFreeRDPSanitizedCancellation(NSDictionary<NSString *, id> *cancellation,
                               uint64_t expectedGeneration,
                               NSString *expectedAttemptIdentifier,
                               NSError **error);

NS_ASSUME_NONNULL_END
