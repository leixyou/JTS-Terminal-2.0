# Companion transport XPC boundary

`JTCompanionTransportService.xpc` is an on-demand, application-scoped macOS
helper embedded only in the `JTSTerminalRDP2` target. It is separate from the
FreeRDP parser process. The main app links the typed `JTSCompanionClient`; only
this helper links `JTSCompanionServiceRuntime` and its endpoint TLS engine.

The helper accepts only the exact Apple-signed JTS application identity and team:
Debug uses `com.lljts.JTSTerminal.UITesting`, Release uses
`com.lljts.JTSTerminal`, and both require team `YOURTEAMID`. There is no Debug
authentication bypass. The shared IPC interface accepts only bounded `Data`
requests and replies, with at most sixteen connections and sixteen pending requests
per connection. Each connection owns its own runtime; invalidation cancels its
requests and invalidates its runtime.

Entitlements are limited to App Sandbox and outgoing network access. This helper
does not read the credential vault, request Keychain access, listen on a network
port, share the app container, pair a device, or grant capabilities at startup.
The app supplies explicitly approved identity material in memory only after
mutual XPC identity verification. The existing 2.0 DVC path is unchanged.

The shared `JTCompanionTransportService` scheme builds the helper independently;
the app scheme embeds and signs it. Source/project checks and signing-script
fixtures are not proof of signed native IPC, relay, or Windows acceptance. Those
remain separate gates, including wrong-peer rejection and connection teardown.
