#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef uint64_t (^JTFreeRDPUptimeClock)(void);
typedef void (^JTFreeRDPCommandCompletion)(NSError * _Nullable error);
typedef NSError * _Nullable (^JTFreeRDPCommandExecutor)(
    NSDictionary<NSString *, id> *command);

FOUNDATION_EXPORT NSString * const JTFreeRDPCommandQueueErrorDomain;
FOUNDATION_EXPORT NSString * const JTFreeRDPCommandQueueErrorCodeKey;

/// A bounded, deadline-aware command queue shared by input and Companion DVC
/// mutations. Cancellation and execution are serialized under one lock: when
/// cancel returns, that request can no longer begin executing.
@interface JTFreeRDPCommandQueue : NSObject

- (instancetype)initWithCapacity:(NSUInteger)capacity;
- (instancetype)initWithCapacity:(NSUInteger)capacity
                            clock:(JTFreeRDPUptimeClock)clock NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSUInteger pendingCount;

- (BOOL)enqueueCommand:(NSDictionary<NSString *, id> *)command
       requestIdentifier:(NSString *)requestIdentifier
deadlineUptimeMilliseconds:(uint64_t)deadlineUptimeMilliseconds
           queueFullCode:(NSString *)queueFullCode
              completion:(JTFreeRDPCommandCompletion)completion
                   error:(NSError **)error;

/// Cancels a queued request or waits for an executing request to leave the
/// critical section. Returns YES only when execution was prevented.
- (BOOL)cancelRequestIdentifier:(NSString *)requestIdentifier;

- (void)drainWithExecutor:(JTFreeRDPCommandExecutor)executor;
- (void)cancelAllWithCode:(NSString *)code message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
