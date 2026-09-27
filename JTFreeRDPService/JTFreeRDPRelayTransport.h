#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>

// Only an already-connected private stream may enter the helper. No listener,
// relay identity, grant, certificate or destination is passed to FreeRDP.
static inline int JTDuplicateRelaySocket(NSFileHandle *handle)
{
    if (![handle isKindOfClass:NSFileHandle.class]) return -1;
    int source = handle.fileDescriptor;
    int type = 0;
    socklen_t typeSize = sizeof(type);
    struct sockaddr_storage peer = { 0 };
    socklen_t peerSize = sizeof(peer);
    if (source < 0 || getsockopt(source, SOL_SOCKET, SO_TYPE, &type, &typeSize) != 0 ||
        type != SOCK_STREAM || getpeername(source, (struct sockaddr *)&peer, &peerSize) != 0 ||
        peer.ss_family != AF_UNIX) return -1;
    return fcntl(source, F_DUPFD_CLOEXEC, 0);
}
