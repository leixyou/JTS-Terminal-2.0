import Foundation

// An application-scoped, on-demand XPC service. No listener port, UI, pairing or
// persistent identity is created merely by loading this executable.
let delegate = CompanionListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
withExtendedLifetime(delegate) {
    listener.resume()
    dispatchMain()
}
