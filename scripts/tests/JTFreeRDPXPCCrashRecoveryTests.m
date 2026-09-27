#import <Foundation/Foundation.h>

#import "JTFreeRDPXPCProtocol.h"

static const NSTimeInterval JTTestTimeoutSeconds = 10.0;

static void JTFail(NSString *message)
{
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    exit(1);
}

static BOOL JTWait(dispatch_semaphore_t semaphore)
{
    return dispatch_semaphore_wait(
        semaphore,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(JTTestTimeoutSeconds * NSEC_PER_SEC))) == 0;
}

static NSXPCConnection *JTCreateConnection(void)
{
    NSXPCConnection *connection = [[NSXPCConnection alloc]
        initWithServiceName:@"com.lljts.JTSTerminal.FreeRDPService"];
    connection.remoteObjectInterface =
        [NSXPCInterface interfaceWithProtocol:@protocol(JTFreeRDPServiceProtocol)];
    [connection resume];
    return connection;
}

static pid_t JTPing(NSXPCConnection *connection)
{
    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    __block NSDictionary<NSString *, id> *result = nil;
    __block NSError *proxyError = nil;

    id<JTFreeRDPServiceProtocol> proxy =
        [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            proxyError = error;
            dispatch_semaphore_signal(completion);
        }];
    [proxy pingWithReply:^(NSDictionary<NSString *, id> *reply) {
        result = reply;
        dispatch_semaphore_signal(completion);
    }];

    if (!JTWait(completion)) {
        JTFail(@"The XPC helper did not answer ping before the deadline.");
    }
    if (proxyError) {
        JTFail([NSString stringWithFormat:@"The XPC ping failed: %@", proxyError.localizedDescription]);
    }
    if (![result[@"ok"] boolValue]) {
        JTFail(@"The XPC helper returned an unsuccessful ping.");
    }
    pid_t processIdentifier = [result[@"helperPID"] intValue];
    if (processIdentifier <= 0) {
        JTFail(@"The Debug XPC helper did not expose its process identifier.");
    }
    return processIdentifier;
}

static void JTCrashAndAwaitInterruption(NSXPCConnection *connection)
{
    dispatch_semaphore_t terminalEvent = dispatch_semaphore_create(0);
    NSObject *terminalLock = [[NSObject alloc] init];
    __block BOOL didSignal = NO;
    void (^signalOnce)(void) = ^{
        @synchronized (terminalLock) {
            if (didSignal) {
                return;
            }
            didSignal = YES;
        }
        dispatch_semaphore_signal(terminalEvent);
    };

    connection.interruptionHandler = signalOnce;
    connection.invalidationHandler = signalOnce;
    id<JTFreeRDPServiceProtocol> proxy =
        [connection remoteObjectProxyWithErrorHandler:^(__unused NSError *error) {
            signalOnce();
        }];
    [proxy crashForTestingWithReply:^{
        JTFail(@"The Debug XPC crash method unexpectedly returned without terminating the helper.");
    }];

    if (!JTWait(terminalEvent)) {
        JTFail(@"The test host did not observe helper interruption after the forced crash.");
    }
}

int main(void)
{
    @autoreleasepool {
        NSXPCConnection *firstConnection = JTCreateConnection();
        pid_t firstPID = JTPing(firstConnection);
        JTCrashAndAwaitInterruption(firstConnection);
        [firstConnection invalidate];

        NSXPCConnection *secondConnection = JTCreateConnection();
        pid_t secondPID = JTPing(secondConnection);
        [secondConnection invalidate];

        if (firstPID == secondPID) {
            JTFail(@"The XPC service did not relaunch in a new process after the forced crash.");
        }

        printf("PASS: XPC helper crash stayed isolated and relaunched (pid %d -> %d)\n",
               firstPID,
               secondPID);
    }
    return 0;
}
