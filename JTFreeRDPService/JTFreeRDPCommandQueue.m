#import "JTFreeRDPCommandQueue.h"

#import "JTFreeRDPXPCValidation.h"

NSString * const JTFreeRDPCommandQueueErrorDomain =
    @"com.lljts.JTSTerminal.FreeRDPCommandQueue";
NSString * const JTFreeRDPCommandQueueErrorCodeKey = @"JTFreeRDPErrorCode";

static const NSUInteger JTFreeRDPMaximumRememberedRequestIdentifiers = 8192;

static NSError *JTQueueError(NSString *code, NSString *message)
{
    return [NSError errorWithDomain:JTFreeRDPCommandQueueErrorDomain
                               code:1
                           userInfo:@{
                               NSLocalizedDescriptionKey: message,
                               JTFreeRDPCommandQueueErrorCodeKey: code
                           }];
}

@interface JTFreeRDPQueuedCommand : NSObject

@property (nonatomic, copy) NSDictionary<NSString *, id> *command;
@property (nonatomic, copy) NSString *requestIdentifier;
@property (nonatomic) uint64_t deadlineUptimeMilliseconds;
@property (nonatomic, copy) JTFreeRDPCommandCompletion completion;

@end

@implementation JTFreeRDPQueuedCommand
@end

@interface JTFreeRDPCommandQueue ()

@property (nonatomic) NSUInteger capacity;
@property (nonatomic, copy) JTFreeRDPUptimeClock clock;
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSMutableArray<JTFreeRDPQueuedCommand *> *commands;
@property (nonatomic, strong) NSMutableSet<NSString *> *inFlightRequestIdentifiers;
@property (nonatomic, strong) NSMutableOrderedSet<NSString *> *rememberedRequestIdentifiers;

@end

@implementation JTFreeRDPCommandQueue

- (instancetype)initWithCapacity:(NSUInteger)capacity
{
    return [self initWithCapacity:capacity clock:^uint64_t{
        return JTFreeRDPCurrentUptimeMilliseconds();
    }];
}

- (instancetype)initWithCapacity:(NSUInteger)capacity
                            clock:(JTFreeRDPUptimeClock)clock
{
    NSParameterAssert(capacity > 0);
    NSParameterAssert(clock != nil);
    self = [super init];
    if (self) {
        _capacity = capacity;
        _clock = [clock copy];
        _lock = [[NSLock alloc] init];
        _commands = [NSMutableArray array];
        _inFlightRequestIdentifiers = [NSMutableSet set];
        _rememberedRequestIdentifiers = [NSMutableOrderedSet orderedSet];
    }
    return self;
}

- (NSUInteger)pendingCount
{
    [self.lock lock];
    NSUInteger count = self.commands.count + self.inFlightRequestIdentifiers.count;
    [self.lock unlock];
    return count;
}

- (BOOL)enqueueCommand:(NSDictionary<NSString *, id> *)command
       requestIdentifier:(NSString *)requestIdentifier
deadlineUptimeMilliseconds:(uint64_t)deadlineUptimeMilliseconds
           queueFullCode:(NSString *)queueFullCode
              completion:(JTFreeRDPCommandCompletion)completion
                   error:(NSError **)error
{
    if (command.count == 0 || requestIdentifier.length == 0 || !completion) {
        if (error) {
            *error = JTQueueError(@"XPC_REQUEST_ENVELOPE_INVALID",
                                  @"The queued XPC request is invalid.");
        }
        return NO;
    }

    [self.lock lock];
    uint64_t now = self.clock();
    if (deadlineUptimeMilliseconds <= now) {
        [self.lock unlock];
        if (error) {
            *error = JTQueueError(@"RDP_XPC_REQUEST_EXPIRED",
                                  @"The XPC request expired before it could be queued.");
        }
        return NO;
    }
    if ([self.rememberedRequestIdentifiers containsObject:requestIdentifier]) {
        [self.lock unlock];
        if (error) {
            *error = JTQueueError(@"RDP_XPC_REQUEST_DUPLICATE",
                                  @"The XPC request identifier was already used.");
        }
        return NO;
    }
    if (self.commands.count + self.inFlightRequestIdentifiers.count >= self.capacity) {
        [self.lock unlock];
        if (error) {
            *error = JTQueueError(queueFullCode,
                                  @"The FreeRDP command queue is full.");
        }
        return NO;
    }

    JTFreeRDPQueuedCommand *queued = [[JTFreeRDPQueuedCommand alloc] init];
    queued.command = [command copy];
    queued.requestIdentifier = [requestIdentifier copy];
    queued.deadlineUptimeMilliseconds = deadlineUptimeMilliseconds;
    queued.completion = [completion copy];
    [self.commands addObject:queued];
    [self rememberRequestIdentifier:requestIdentifier];
    [self.lock unlock];
    return YES;
}

- (BOOL)cancelRequestIdentifier:(NSString *)requestIdentifier
{
    if (requestIdentifier.length == 0) {
        return NO;
    }
    NSMutableArray<JTFreeRDPQueuedCommand *> *cancelled = [NSMutableArray array];
    [self.lock lock];
    NSIndexSet *indexes = [self.commands indexesOfObjectsPassingTest:
        ^BOOL(JTFreeRDPQueuedCommand *command, NSUInteger index, BOOL *stop) {
            (void)index;
            (void)stop;
            return [command.requestIdentifier isEqualToString:requestIdentifier];
        }];
    if (indexes.count > 0) {
        [cancelled addObjectsFromArray:[self.commands objectsAtIndexes:indexes]];
        [self.commands removeObjectsAtIndexes:indexes];
    }
    BOOL prevented = cancelled.count > 0 ||
        [self.inFlightRequestIdentifiers containsObject:requestIdentifier];
    // If the identifier is in-flight and not executing yet, drain holds no
    // lock and cancellation reaches this point first. Remove it so drain skips
    // the command. If execution already began, this lock acquisition waited
    // until it finished and the identifier is no longer present.
    [self.inFlightRequestIdentifiers removeObject:requestIdentifier];
    [self rememberRequestIdentifier:requestIdentifier];
    [self.lock unlock];

    NSError *failure = JTQueueError(@"RDP_XPC_REQUEST_CANCELLED",
                                    @"The XPC request was cancelled before execution.");
    for (JTFreeRDPQueuedCommand *command in cancelled) {
        command.completion(failure);
    }
    return prevented;
}

- (void)drainWithExecutor:(JTFreeRDPCommandExecutor)executor
{
    if (!executor) {
        return;
    }
    [self.lock lock];
    NSArray<JTFreeRDPQueuedCommand *> *commands = [self.commands copy];
    [self.commands removeAllObjects];
    for (JTFreeRDPQueuedCommand *command in commands) {
        [self.inFlightRequestIdentifiers addObject:command.requestIdentifier];
    }
    [self.lock unlock];

    for (JTFreeRDPQueuedCommand *command in commands) {
        NSError *failure = nil;
        [self.lock lock];
        if (![self.inFlightRequestIdentifiers containsObject:command.requestIdentifier]) {
            failure = JTQueueError(@"RDP_XPC_REQUEST_CANCELLED",
                                   @"The XPC request was cancelled before execution.");
        } else if (command.deadlineUptimeMilliseconds <= self.clock()) {
            failure = JTQueueError(@"RDP_XPC_REQUEST_EXPIRED",
                                   @"The XPC request expired before execution.");
            [self.inFlightRequestIdentifiers removeObject:command.requestIdentifier];
        } else {
            // Keep the same lock across the final deadline/cancellation check
            // and the protocol mutation. A successful cancel acknowledgement
            // therefore proves that this command cannot execute afterward.
            failure = executor(command.command);
            [self.inFlightRequestIdentifiers removeObject:command.requestIdentifier];
        }
        [self.lock unlock];
        command.completion(failure);
    }
}

- (void)cancelAllWithCode:(NSString *)code message:(NSString *)message
{
    [self.lock lock];
    NSArray<JTFreeRDPQueuedCommand *> *commands = [self.commands copy];
    [self.commands removeAllObjects];
    [self.inFlightRequestIdentifiers removeAllObjects];
    [self.lock unlock];

    NSError *failure = JTQueueError(code, message);
    for (JTFreeRDPQueuedCommand *command in commands) {
        command.completion(failure);
    }
}

- (void)rememberRequestIdentifier:(NSString *)requestIdentifier
{
    [self.rememberedRequestIdentifiers addObject:requestIdentifier];
    while (self.rememberedRequestIdentifiers.count >
           JTFreeRDPMaximumRememberedRequestIdentifiers) {
        [self.rememberedRequestIdentifiers removeObjectAtIndex:0];
    }
}

@end
