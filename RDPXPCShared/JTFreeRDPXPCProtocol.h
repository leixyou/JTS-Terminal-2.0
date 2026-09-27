#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const JTFreeRDPXPCServiceName;

@protocol JTFreeRDPClientProtocol

- (void)desktopDidChangeState:(NSDictionary<NSString *, id> *)state;
- (void)desktopDidUpdateSurface:(IOSurface *)surface
                       metadata:(NSDictionary<NSString *, id> *)metadata;
- (void)desktopDidReceiveDVCMessage:(NSData *)message
                           metadata:(NSDictionary<NSString *, id> *)metadata;
- (void)desktopDidReceiveClipboardText:(NSData *)text
                              metadata:(NSDictionary<NSString *, id> *)metadata;
- (void)desktopDidRequireCertificateDecision:(NSDictionary<NSString *, id> *)certificate;

@end

@protocol JTFreeRDPServiceProtocol

- (void)connectWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                           reply:(void (^)(NSDictionary<NSString *, id> *result))reply;
- (void)connectWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                    relaySocket:(NSFileHandle *)relaySocket
                          reply:(void (^)(NSDictionary<NSString *, id> *result))reply;
- (void)disconnectWithReply:(void (^)(void))reply;
- (void)sendInput:(NSDictionary<NSString *, id> *)input
           request:(NSDictionary<NSString *, id> *)request
             reply:(void (^)(NSDictionary<NSString *, id> *result))reply;
- (void)sendDVCMessage:(NSData *)message
                 request:(NSDictionary<NSString *, id> *)request
 expectedChannelGeneration:(uint64_t)expectedChannelGeneration
                  reply:(void (^)(NSDictionary<NSString *, id> *result))reply;
- (void)updateClipboardText:(NSData * _Nullable)text
                    request:(NSDictionary<NSString *, id> *)request
                      reply:(void (^)(NSDictionary<NSString *, id> *result))reply;
- (void)setClipboardIsolation:(BOOL)isolated
                         text:(NSData * _Nullable)text
                      request:(NSDictionary<NSString *, id> *)request
                        reply:(void (^)(NSDictionary<NSString *, id> *result))reply;
- (void)offerCompanionInstallerWithRequest:(NSDictionary<NSString *, id> *)request
                                      reply:(void (^)(NSDictionary<NSString *, id> *result))reply;
- (void)clearCompanionInstallerWithRequest:(NSDictionary<NSString *, id> *)request
                                      reply:(void (^)(NSDictionary<NSString *, id> *result))reply;
- (void)cancelRequest:(NSDictionary<NSString *, id> *)cancellation
                 reply:(void (^)(NSDictionary<NSString *, id> *result))reply;
- (void)copyFrameWithReply:(void (^)(NSData * _Nullable pixels,
                                     NSDictionary<NSString *, id> *metadata))reply;
- (void)pingWithReply:(void (^)(NSDictionary<NSString *, id> *result))reply;
#if DEBUG
- (void)crashForTestingWithReply:(void (^)(void))reply;
#endif

@end

NS_ASSUME_NONNULL_END
