#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>

NS_ASSUME_NONNULL_BEGIN

@class JTFreeRDPXPCRequestEnvelope;
typedef void (^JTFreeRDPEngineCommandCompletion)(NSError * _Nullable error);

@protocol JTFreeRDPEngineDelegate <NSObject>

- (void)rdpEngineDidChangeState:(NSDictionary<NSString *, id> *)state;
- (void)rdpEngineDidUpdateSurface:(IOSurface *)surface
                         metadata:(NSDictionary<NSString *, id> *)metadata;
- (void)rdpEngineDidReceiveDVCMessage:(NSData *)message
                             metadata:(NSDictionary<NSString *, id> *)metadata;
- (void)rdpEngineDidReceiveClipboardText:(NSData *)text
                                metadata:(NSDictionary<NSString *, id> *)metadata;
- (void)rdpEngineDidRequireCertificateDecision:(NSDictionary<NSString *, id> *)certificate;

@end

@interface JTFreeRDPEngine : NSObject

@property (nonatomic, weak, nullable) id<JTFreeRDPEngineDelegate> delegate;
@property (atomic, readonly, getter=isRunning) BOOL running;

- (BOOL)startWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                         error:(NSError **)error;
- (BOOL)startWithConfiguration:(NSDictionary<NSString *, id> *)configuration
                   relaySocket:(NSFileHandle * _Nullable)relaySocket
                         error:(NSError **)error;
- (void)disconnect;
- (BOOL)enqueueInput:(NSDictionary<NSString *, id> *)input
              request:(JTFreeRDPXPCRequestEnvelope *)request
           completion:(JTFreeRDPEngineCommandCompletion)completion
                error:(NSError **)error;
- (BOOL)enqueueDVCMessage:(NSData *)message
                   request:(JTFreeRDPXPCRequestEnvelope *)request
 expectedChannelGeneration:(uint64_t)expectedChannelGeneration
                completion:(JTFreeRDPEngineCommandCompletion)completion
                     error:(NSError **)error;
- (BOOL)enqueueClipboardText:(NSData * _Nullable)text
                     request:(JTFreeRDPXPCRequestEnvelope *)request
                  completion:(JTFreeRDPEngineCommandCompletion)completion
                       error:(NSError **)error;
- (BOOL)enqueueClipboardIsolation:(BOOL)isolated
                             text:(NSData * _Nullable)text
                          request:(JTFreeRDPXPCRequestEnvelope *)request
                       completion:(JTFreeRDPEngineCommandCompletion)completion
                            error:(NSError **)error;
- (BOOL)enqueueCompanionInstallerOfferAtURL:(NSURL *)installerURL
                             remoteFileName:(NSString *)remoteFileName
                             expectedSHA256:(NSString *)expectedSHA256
                                    request:(JTFreeRDPXPCRequestEnvelope *)request
                                 completion:(JTFreeRDPEngineCommandCompletion)completion
                                      error:(NSError **)error;
- (BOOL)enqueueCompanionInstallerClearWithRequest:
    (JTFreeRDPXPCRequestEnvelope *)request
                                      completion:
    (JTFreeRDPEngineCommandCompletion)completion
                                           error:(NSError **)error;
- (BOOL)cancelRequestIdentifier:(NSString *)requestIdentifier;
- (void)copyFrameWithReply:(void (^)(NSData * _Nullable pixels,
                                     NSDictionary<NSString *, id> *metadata))reply;

@end

NS_ASSUME_NONNULL_END
