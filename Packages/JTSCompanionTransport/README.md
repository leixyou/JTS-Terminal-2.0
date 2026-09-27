# JTS Companion transport (2.5 foundation)

This macOS Swift package is an **endpoint client**, not the independently
distributed JTS Relay server. It has no source/build dependency on that server.
Its data-only IPC/client products are linked into the RDP2 application target;
the TLS implementation belongs to the separate `JTCompanionTransportService`
sandbox XPC target, not the app or FreeRDP process. This does not yet deliver the
device-management/pairing UI, vault integration, durable file transfer, RDP proxy,
Windows service acceptance or full 2.5 product acceptance.

The immutable data contract is vendored at
[protocol 1.0.0-alpha.1](../../Protocols/JTSRelay/1.0.0-alpha.1/v1/PROTOCOL.md),
with [provenance](../../Protocols/JTSRelay/1.0.0-alpha.1/PROVENANCE.md).
Its source archive SHA-256 is
`bf9766123f22024c0cc492928af9b3c8b4eff78e2bac12270b1b728a951bc445`.
The test fixture is a checked-in snapshot of that version, not a sibling-source
lookup, symlink or build dependency. Updating protocol versions requires explicit
fixture and compatibility changes in each endpoint repository.

The active [security-v2 contract](../../Protocols/JTSRelay/2.0.0-security.1/security-v2/PROTOCOL.md)
has a separate [frozen data-only provenance](../../Protocols/JTSRelay/2.0.0-security.1/PROVENANCE.md).
It requires audience-bound `JTS-RELAY-AUTH-V2` proofs for
all relay management calls. The expected canonical origin is selected by the
caller; it is never adopted from a challenge. There is no V1 authentication
fallback. Numeric-loopback HTTP remains an explicit development-only option;
production outer HTTPS/WSS and pinned inner mutual TLS remain encrypted.

## Enrollment authorization and revocation

`JTSRelayEnrollment` encrypts the offer/claim with a high-entropy invitation
secret, then requires a separate controller-signed confirmation for the exact
origin, invitation, Windows identity and claim. `prepareConfirmation` creates
that proof only within the request's original validity window. The app must
save `attempt.confirmation` before calling `confirm`; a saved proof can be
retried after expiry without signing a new authorization. An unsigned relay
`bound` status is rejected. Historical bound/complete vault records missing
the proof are preserved as `confirmationRequired`; they are not automatically
promoted to authenticated V2 authorization. Pending attempts retain their code.

Revocation uses a durable signed request naming the exact pairing and all three
grant IDs. Save `prepareRevocation`'s result before submission. A `pending`
mailbox response means Windows has not yet acknowledged it. The package reports
`complete` only after verifying a Windows signature with the locally pinned
SPKI and the hash of the exact signed request. The owning app must stop local
routes immediately and preserve its local denial while Windows is offline;
relay edge removal alone is not proof that remote permissions or tasks stopped.
Revocation requests do not expire, and cannot target a later pairing epoch.

## Implemented boundary

- CryptoKit P-256 signing over the versioned relay proof input, DER-SPKI identity,
  public cross-language proof fixture, raw 64-byte IEEE-P1363 signatures.
- HTTPS admission discovery/presence/session/poll client. Operators admit public
  keys separately; these APIs cannot grant node admission or endpoint permissions.
  Responses are bounded, redirects are rejected and proof errors are not retried.
- WebSocket bearer tickets are issuer-bound and single-use locally. Ready frames
  must match the exact session/lane; subsequent messages are bounded binary bytes.
  The carrier is not an authenticated business stream.
- A small C/OpenSSL memory-BIO implementation, linked from **this checkout's**
  audited vendor archive. It enforces pinned P-256 mutual TLS, certificate validity,
  ALPN `jts-relay-v1`, TLS 1.3 (AES-GCM), and explicit Windows 10 TLS 1.2
  ECDHE-ECDSA/AES-GCM compatibility. Tickets, resumption, 0-RTT, compression and
  renegotiation are disabled. No caller-provided system trust bypass is installed.
- Exact length-prefixed encrypted lane binding before returning application I/O.
  Failed authentication, wrong lane, malformed JSON and cancellation close the
  carrier. One reader and one writer may operate concurrently, with bounded buffers.
- Device/lane/session state independent of desktop-open/login state. Local pairing
  is explicit, revocation invalidates pending connection generations, and failed I/O
  allows a fresh connection without deleting pairing. No command is automatically
  replayed. The coordinator defaults to `UnavailableCompanionTLS`; application
  composition must deliberately select `PinnedTLSChannelFactory` in the isolated
  transport process after its integration gates are met.
- A typed `CompanionControlClient` submits/queries/cancels jobs and fetches bounded
  output on the authenticated control stream, with strict correlation, JSON,
  grant/job IDs, payload and page bounds. It never automatically retries a task.
  The coordinator provides one cached control client per connection; raw control
  send/receive is rejected to prevent a competing reader or corrupt framing.
  Failure invalidates that session without allowing an old callback to remove a
  new connection. See the [endpoint business contract](../../Protocols/JTSCompanion/control-v1.md),
  including the required application-owned control presence/heartbeat lifecycle.

Identity persistence and MCP capability authorization remain the owning app's
responsibility. Do not instantiate peer trust from relay metadata. Do not place
private identities in the FreeRDP parser process. Do not use `RelayByteCarrier`
directly for commands, files or RDP plaintext.

## Mac process boundary

- `JTSCompanionIPC`: bounded versioned DTOs, strict duplicate/unknown-key rejection,
  redacted descriptions and an NSData-only XPC interface; no crypto/archive link.
- `JTSCompanionClient`: lazy signed-helper connection, typed task calls, one RPC
  at a time, finite deadlines and generation-safe cancellation. No automatic
  reconnection, task replay, identity storage or pairing/capability approval.
- `JTSCompanionServiceRuntime`: one explicitly pinned control route per trusted
  XPC connection, genuine inner mutual TLS, presence/heartbeat and bounded task
  RPC. A failed heartbeat or lost owner closes the route. Pending socket readiness
  cancellation explicitly closes the socket rather than assuming Swift Task
  cancellation cancels a Foundation WebSocket continuation.
- `JTCompanionTransportService`: separately signed, application-scoped sandbox
  helper, only network-client entitlement. Both sides always enforce fixed team
  and build-specific application identities, including Debug. FreeRDP receives no
  local Companion identity. See the [local IPC contract](../../Protocols/JTSCompanion/mac-ipc-v1.md).

Control is independent of desktop lifetime, but closing a local route is **not**
an acknowledgement that every remote task stopped. Windows enforces grants,
disconnect cancellation and explicitly permitted unattended tasks. File/RDP raw
forwarding is deliberately not exposed by this control-only IPC increment.
The application must still supply an explicitly verified pairing and vault-held
identity; the new API is not user consent by itself.

## Focused verification

From the client repository root:

```sh
swift test --package-path Packages/JTSCompanionTransport
```

The ordinary scope skips the explicitly gated .NET interoperability tests. The
test-only `Tests/InteropHost` hosts `RelaySecureStream` on numeric loopback, uses
fresh in-memory identities and emits only public connection metadata. It references
the client-side `WindowsCompanion` project, never the separate relay repository.

```sh
dotnet build Packages/JTSCompanionTransport/Tests/InteropHost/InteropHost.csproj
JTS_INTEROP_DOTNET=/absolute/path/to/dotnet \
JTS_INTEROP_HOST_DLL=/absolute/path/to/InteropHost.dll \
swift test --package-path Packages/JTSCompanionTransport
```

On macOS the .NET test host deliberately selects constrained TLS 1.2 because its
native TLS backend does not provide the Windows 11/Linux TLS 1.3 path. Positive
cross-language tests exercise all three lane bindings and a fragmented bidirectional
payload; negative tests reject wrong client pins and cross-lane substitution.
Separate OpenSSL-to-OpenSSL tests exercise TLS 1.3. **Neither is a substitute for
real Windows Schannel, deployed HTTPS/WSS relay, sandbox/XPC or RDP acceptance.**

The control interoperability case additionally composes the actual protected
SQLite grant provider, C# grant checks and SQLite task receipts: a 64 KiB submission, exact duplicate/conflicting retry,
bounded output pages, query, cancellation and denied grant. The fixture executes
only inert echo/block operations and test-approved consent, not PowerShell or a
Windows approval dialog. For a control-only development
increment, select `--filter 'ControlClientTests|CoordinatorTests|InteropTests'`
instead of rerunning unrelated package or app suites. The InteropHost dependency
lock is verified with `dotnet restore ... --locked-mode` before builds.

The package creates only test/cache artifacts under `.build` and InteropHost
`bin`/`obj`; it does not build, launch, sign or retain another `JTS Terminal.app`.
