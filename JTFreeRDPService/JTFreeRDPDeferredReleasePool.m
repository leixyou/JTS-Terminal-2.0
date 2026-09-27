#import "JTFreeRDPDeferredReleasePool.h"

#import <stdlib.h>

@interface JTFreeRDPDeferredReleasePool ()

@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSMutableSet<NSValue *> *trackedPointers;

@end


@implementation JTFreeRDPDeferredReleasePool

- (instancetype)init
{
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _trackedPointers = [[NSMutableSet alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self drainTrackedPointers];
}

- (NSUInteger)trackedPointerCount
{
    [self.lock lock];
    NSUInteger count = self.trackedPointers.count;
    [self.lock unlock];
    return count;
}

- (BOOL)trackPointer:(void *)pointer
{
    if (!pointer) {
        return NO;
    }
    NSValue *value = [NSValue valueWithPointer:pointer];
    [self.lock lock];
    BOOL inserted = ![self.trackedPointers containsObject:value];
    if (inserted) {
        [self.trackedPointers addObject:value];
    }
    [self.lock unlock];
    return inserted;
}

- (NSUInteger)drainTrackedPointers
{
    [self.lock lock];
    NSArray<NSValue *> *pointers = self.trackedPointers.allObjects;
    [self.trackedPointers removeAllObjects];
    [self.lock unlock];

    for (NSValue *value in pointers) {
        free(value.pointerValue);
    }
    return pointers.count;
}

@end
