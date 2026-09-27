#import <Foundation/Foundation.h>

#import "../RDPXPCShared/JTFreeRDPXPCProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface JTFreeRDPService : NSObject <JTFreeRDPServiceProtocol>

- (instancetype)initWithConnection:(NSXPCConnection *)connection;

@end

NS_ASSUME_NONNULL_END
