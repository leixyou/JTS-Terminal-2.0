#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns heap pointers until their producer reaches a proven quiescent
/// boundary. Tracking the same pointer more than once is harmless; callers
/// must drain only after no callback can still access any tracked pointer.
@interface JTFreeRDPDeferredReleasePool : NSObject

@property (nonatomic, readonly) NSUInteger trackedPointerCount;

- (BOOL)trackPointer:(void * _Nullable)pointer;
- (NSUInteger)drainTrackedPointers;

@end

NS_ASSUME_NONNULL_END
