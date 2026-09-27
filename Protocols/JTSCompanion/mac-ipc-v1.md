# Mac Companion transport IPC v1

This is an endpoint-owned local process contract, not a change to the immutable
JTS Relay protocol snapshot. The application links only data/client code; TLS and
the vendor crypto archive execute inside the separate sandbox transport helper.
It does not share the FreeRDP parser's address space or identity material.

## Caller and ownership

The fixed service ID is `com.lljts.JTSTerminal.CompanionTransportService`.
Both directions require an Apple-valid signature for team `YOURTEAMID`, with the
exact helper ID and the build-specific main application ID (Debug `.UITesting`,
Release `com.lljts.JTSTerminal`). There is no Debug/ad-hoc/environment bypass.
The service is on-demand/application-scoped, with only sandbox and outbound
network entitlements; it does not listen for inbound TCP, access app files or
share the app's Keychain privileges.

The main app is responsible for vault persistence, explicit peer confirmation,
capability selection and MCP-client grants. `open` receives an in-memory raw
P-256 private key, canonical pinned peer SPKI, explicit HTTPS relay root and an
explicit Windows 10 TLS 1.2 compatibility choice. Relay discovery/admission must
never synthesize endpoint trust. There is no trust-override or implicit official
endpoint. The current IPC only opens the control lane.

One accepted XPC connection owns one runtime/route and transient identity. There
are at most 16 caller connections and 16 pending envelopes per connection; actual
control RPC is serial. Invalidating its owner cancels pending work, closes its
channels and releases state. Independent connection IDs/generations prevent an
old reply or closure from affecting a replacement. Keys, command bodies and
results are not logged, reflected in errors or persisted by this process.

## Encoding

The sole Objective-C method is `perform:withReply:`, accepting/returning NSData.
Its JSON frame is at most 160 KiB; the inner payload is at most 96 KiB. Version 1,
nonzero request/connection UUIDs, exact known keys, duplicate-key rejection
(including escaped/nested duplicates), bounded depth and canonical base64 are
required. Invalid uncorrelatable frames terminate the XPC connection.

Request fields: `version`, `id`, `connectionID`, `operation`, `payload`.
Reply fields: `version`, `id`, `connectionID`, `ok`, `payload`, `errorCode`.
Reply optional fields are present as explicit nulls. Exactly one payload/error
shape is accepted and the reply must bind both IDs. Errors are bounded fixed
codes, not arbitrary exception descriptions.

Operations: `open`, `state`, `close`, `status`, `submit`, `job`, `cancel`, `output`.
Every business operation carries an explicit grant UUID; jobs additionally carry
a caller-owned stable job UUID. Submission is at most 64 KiB; output pages at
most 32 KiB, with exact offsets and at most 1 MiB retained job output in the
current control contract. The endpoint's durable task rules remain authoritative.
Unchanged job IDs are not automatically resubmitted following any timeout.

Request IDs are rejected on repeat within a runtime, with a 65,536-ID bounded
registry. At capacity the owner connection closes; a fresh explicit connection
is required. This is local IPC deduplication, not a substitute for Windows
durable job-ID idempotency.

## Lifecycle and results

Connection establishes relay presence, pinned inner mutual TLS and exact lane
binding before reporting connected. Presence refresh runs every 20 seconds;
failure closes the route. The service open deadline is 50 seconds and the client
deadline 60 seconds. Task RPC has its existing 20-second transport deadline and
a 25-second outer client deadline. Timeout/cancel closes affected I/O; readiness
waits close their exact socket even if the network API ignores Task cancellation.

State is connecting/connected/disconnected/failed. Only connected includes its
bound relay session UUID. Business denials prefixed `REMOTE_` do not automatically
disconnect a valid stream; malformed replies or local service/transport failure
invalidate it. There is no automatic fallback, reconnect or command replay.
Closing local transport does not claim remote task termination: default jobs
cancel at the endpoint on disconnect, whereas explicitly granted unattended jobs
may continue subject to the 24-hour endpoint bound. Offline revocation confirmation
remains a separate future application workflow, not a fabricated local success.

## Acceptance boundary

Portable codec/client/runtime tests use controlled fixtures. A real signed
application-to-helper exchange can prove local process signing/IPC, not Windows
PowerShell, user pairing, outer HTTPS/WSS admission, real file/RDP business
handlers, private-key persistence or complete 2.5 acceptance. Each requires its
own current-source evidence. No test flag relaxes production peer requirements.
Xcode-hosted tests add temporary file/mach entitlements to the signed helper;
their success is not acceptance of the ordinary two-entitlement sandbox runtime.
Check the non-test build separately and retain real daily/Release route testing
as an open gate. Both helper-local and application-local embedded framework
runpaths are required when Xcode selects dynamic linking for the shared IPC product.
The package keeps automatic linking: ordinary builds may be static while hosted
tests are dynamic. The packaging gate accepts either a proven static graph with
no missing IPC dynamic dependency, or both exact signed framework copies. Copying
the helper must not strip already-sealed nested framework Modules.
