#import <Foundation/Foundation.h>

#import "JTFreeRDPService.h"

@interface JTFreeRDPServiceDelegate : NSObject <NSXPCListenerDelegate>

@property (nonatomic, strong) NSMutableSet<JTFreeRDPService *> *services;

@end


static NSSet<Class> *JTFreeRDPPropertyListClasses(void)
{
    return [NSSet setWithObjects:
        NSDictionary.class, NSArray.class, NSString.class, NSNumber.class, NSData.class, nil];
}

static NSSet<Class> *JTFreeRDPDataClasses(void)
{
    return [NSSet setWithObject:NSData.class];
}

static void JTConfigureServiceInterface(NSXPCInterface *interface)
{
    NSSet<Class> *propertyList = JTFreeRDPPropertyListClasses();
    NSSet<Class> *data = JTFreeRDPDataClasses();
    [interface setClasses:propertyList
              forSelector:@selector(connectWithConfiguration:relaySocket:reply:)
            argumentIndex:0 ofReply:NO];
    [interface setClasses:[NSSet setWithObject:NSFileHandle.class]
              forSelector:@selector(connectWithConfiguration:relaySocket:reply:)
            argumentIndex:1 ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(connectWithConfiguration:relaySocket:reply:)
            argumentIndex:0 ofReply:YES];
    [interface setClasses:propertyList
              forSelector:@selector(connectWithConfiguration:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(connectWithConfiguration:reply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:propertyList
              forSelector:@selector(sendInput:request:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(sendInput:request:reply:)
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(sendInput:request:reply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:data
              forSelector:@selector(sendDVCMessage:request:expectedChannelGeneration:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(sendDVCMessage:request:expectedChannelGeneration:reply:)
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(sendDVCMessage:request:expectedChannelGeneration:reply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:data
              forSelector:@selector(updateClipboardText:request:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(updateClipboardText:request:reply:)
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(updateClipboardText:request:reply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:data
              forSelector:@selector(setClipboardIsolation:text:request:reply:)
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(setClipboardIsolation:text:request:reply:)
            argumentIndex:2
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(setClipboardIsolation:text:request:reply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:propertyList
              forSelector:@selector(offerCompanionInstallerWithRequest:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(offerCompanionInstallerWithRequest:reply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:propertyList
              forSelector:@selector(clearCompanionInstallerWithRequest:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(clearCompanionInstallerWithRequest:reply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:propertyList
              forSelector:@selector(cancelRequest:reply:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(cancelRequest:reply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:data
              forSelector:@selector(copyFrameWithReply:)
            argumentIndex:0
                  ofReply:YES];
    [interface setClasses:propertyList
              forSelector:@selector(copyFrameWithReply:)
            argumentIndex:1
                  ofReply:YES];
    [interface setClasses:propertyList
              forSelector:@selector(pingWithReply:)
            argumentIndex:0
                  ofReply:YES];
}

static void JTConfigureClientInterface(NSXPCInterface *interface)
{
    NSSet<Class> *propertyList = JTFreeRDPPropertyListClasses();
    [interface setClasses:propertyList
              forSelector:@selector(desktopDidChangeState:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(desktopDidUpdateSurface:metadata:)
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:[NSSet setWithObject:NSData.class]
              forSelector:@selector(desktopDidReceiveDVCMessage:metadata:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(desktopDidReceiveDVCMessage:metadata:)
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:[NSSet setWithObject:NSData.class]
              forSelector:@selector(desktopDidReceiveClipboardText:metadata:)
            argumentIndex:0
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(desktopDidReceiveClipboardText:metadata:)
            argumentIndex:1
                  ofReply:NO];
    [interface setClasses:propertyList
              forSelector:@selector(desktopDidRequireCertificateDecision:)
            argumentIndex:0
                  ofReply:NO];
}

@implementation JTFreeRDPServiceDelegate

- (instancetype)init
{
    self = [super init];
    if (self) {
        _services = [NSMutableSet set];
    }
    return self;
}

- (BOOL)listener:(NSXPCListener *)listener
shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    (void)listener;

#if !DEBUG
    // A bundled XPC service is normally scoped to its containing application,
    // but the release service also verifies every peer at the code-signing
    // boundary before accepting credential, framebuffer, or input messages.
    [newConnection setCodeSigningRequirement:
        @"anchor apple generic and identifier \"com.lljts.JTSTerminal\" and certificate leaf[subject.OU] = \"YOURTEAMID\""];
#endif

    JTFreeRDPService *service = [[JTFreeRDPService alloc] initWithConnection:newConnection];
    NSXPCInterface *serviceInterface =
        [NSXPCInterface interfaceWithProtocol:@protocol(JTFreeRDPServiceProtocol)];
    JTConfigureServiceInterface(serviceInterface);
    newConnection.exportedInterface = serviceInterface;
    newConnection.exportedObject = service;
    NSXPCInterface *clientInterface = [NSXPCInterface interfaceWithProtocol:@protocol(JTFreeRDPClientProtocol)];
    [clientInterface setClasses:[NSSet setWithObject:IOSurface.class]
                    forSelector:@selector(desktopDidUpdateSurface:metadata:)
                  argumentIndex:0
                        ofReply:NO];
    JTConfigureClientInterface(clientInterface);
    newConnection.remoteObjectInterface = clientInterface;

    __weak typeof(self) weakSelf = self;
    __weak JTFreeRDPService *weakService = service;
    newConnection.invalidationHandler = ^{
        JTFreeRDPService *strongService = weakService;
        if (strongService) {
            [strongService disconnectWithReply:^{}];
            @synchronized (weakSelf.services) {
                [weakSelf.services removeObject:strongService];
            }
        }
    };

    @synchronized (self.services) {
        [self.services addObject:service];
    }
    [newConnection resume];
    return YES;
}

@end


int main(int argc, const char *argv[])
{
    (void)argc;
    (void)argv;

    @autoreleasepool {
        JTFreeRDPServiceDelegate *delegate = [[JTFreeRDPServiceDelegate alloc] init];
        NSXPCListener *listener = [NSXPCListener serviceListener];
        listener.delegate = delegate;
        [listener resume];
    }
    return 0;
}
