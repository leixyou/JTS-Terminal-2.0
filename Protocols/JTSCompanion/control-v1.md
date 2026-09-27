# Companion encrypted control RPC — version 1 (development)

This is the **endpoint business protocol**, owned by the client/Companion project.
It is not a revision to the immutable JTS Relay 1.0.0-alpha.1 data package. The
relay forwards opaque bytes and does not implement, parse or authorize these RPCs.
The protocol is not yet a production Windows service or an installed app feature.

## Preconditions and framing

1. Explicit pairing supplies the exact peer SPKI fingerprint and allowed lanes.
2. Pinned mutual TLS, ALPN and the existing encrypted device/session/lane binding
   finish successfully. Only the `control` lane may carry these requests.
3. The endpoint loads a current local capability grant. Relay admission and pairing
   alone are not command authorization; MCP client authorization remains separate.

Each message is a four-byte unsigned **big-endian** byte count followed by that
many UTF-8 JSON bytes. Length must be 1–98,304 (96 KiB); reject before allocating
the body. A connection has one outstanding request and one reader/writer owner.
No compression, batching or command replay is implicit. Writes may be fragmented
into 16 KiB pieces; TLS record/transport message boundaries do not delimit RPCs.

All objects have exactly their declared fields. Duplicate keys (including escaped
aliases), invalid types and unknown fields are rejected. Requests have maximum
JSON nesting depth 8. UUIDs are nonzero canonical lowercase D format. Integers are
JSON integer tokens; deadlines/timestamps use Unix milliseconds. Binary fields
use canonical padded standard base64, not URL-safe base64 or whitespace variants.

Request: `{version: 1, id, operation, grantId, parameters}`.
Response: `{version: 1, id, ok, result, errorCode}`.
These are field descriptions, not literal JSON examples. `id` is a new correlation
UUID for each exchange; `jobId` is a separate durable idempotency UUID supplied by
the caller. A reply must match `version` and `id`. Success has an object `result`
and null `errorCode`; failure has null `result` and a bounded stable code. Raw
exception messages, paths, payloads and outputs never become error diagnostics.

The owner device is derived only from authenticated TLS binding, never a JSON
owner field. Every request rechecks the grant's owner, ID, expiry and operation;
successful responses recheck authorization before writing. Submission additionally
checks job kind, detached permission and a deadline no later than grant expiry.

## Operations

| Operation | Exact parameters | Result |
| --- | --- | --- |
| `device.status` | Empty object | `capabilities`, `maximumPayloadBytes`, `maximumOutputChunkBytes` |
| `job.submit` | `jobId`, `kind`, `deadlineUnixMilliseconds`, `allowDisconnected`, `payloadBase64` | Receipt |
| `job.get` | `jobId` | Receipt |
| `job.cancel` | `jobId` | Receipt; cancellation may still be draining |
| `job.output` | `jobId`, `offset`, `maximumBytes` | `jobId`, `offset`, `nextOffset`, `outputBytes`, `dataBase64` |

Capabilities are the current grant's allowed operation names, not an implicit grant
of every advertised ability. There is no default PowerShell executor or permissive
grant provider. The dedicated-account executor owns the separate
[`powershell.v1` payload schema](powershell-v1.md); it is not yet installed or
wired through a production Worker service. The relay never interprets it. Test-only kinds
`fixture.echo` and `fixture.block` must not be registered in production.

Receipt fields are `jobId`, `grantId`, `kind`, `deadlineUnixMilliseconds`,
`allowDisconnected`, `state`, `submittedAtUnixMilliseconds`,
`startedAtUnixMilliseconds`, `completedAtUnixMilliseconds`, `resultCode`,
`outputBytes`, `dataExpired`. Start/completion timestamps and result code may be
null. State is one of `queued`, `running`, `cancelling`, `succeeded`, `failed`,
`cancelled`, `expired`, `interrupted`. Receipt lookup/output/cancel binds both owner
and grant; a different grant sees `JOB_NOT_FOUND`, not another grant's metadata.

Submission payload is 1–65,536 bytes. Kind is 1–64 ASCII letters, digits, `.`, `_`
or `-`. New task deadline must be future and at most 24 hours. Exact duplicate
submission returns the existing receipt, while changed immutable contents return
`JOB_IDEMPOTENCY_CONFLICT`. A transport failure is an unknown delivery outcome,
not permission to silently submit a new job ID. Query the existing ID, or retry
the same complete immutable request after reconnect under current authorization.

Output pages are 1–32,768 requested bytes; offset must be within the current
retained output. `nextOffset = offset + decoded bytes`, and cannot exceed reported
`outputBytes`. An empty page at the current end does not prove task completion;
query its state. The runtime defaults to 128 KiB retained output per job (configured
hard ceiling 1 MiB); this is task output, not the separate 10 GiB file-transfer API.
Expired output returns `JOB_DATA_EXPIRED`; receipt idempotency remains intact.

## Presence, cancellation and bounds

The host aggregates authenticated control connections for an owner. Closing one
of several connections must not cancel that owner's interactive tasks; closing
the last does. File/RDP presence does not keep a control task alive. Explicitly
detached tasks survive disconnect within their authorized deadline. On service
restart running work becomes interrupted/unknown, never automatically rerun;
previously queued detached jobs reauthorize before execution.

Local policy must durably record revocation before calling the host's immediate
revoke hook. The hook cancels affected tasks, rejects stale in-flight authorization
and conservatively closes the owner's control streams. Offline UI must retain
pending confirmation rather than claiming remote execution has already stopped.
The executor must stop actual child processes; `cancelling` is not `cancelled`.

The endpoint now provides `DurableControlGrantStore` and local
`RevokeGrantDurablyAsync` for this ordering. No new wire operation is added: grant
approval/editing is not remote RPC. On persistence failure the host stops and
reports that durable revocation is unconfirmed. See
[policy storage](https://github.com/leixyou/JTS-Windows-Companion/blob/main/src/JTS.WindowsCompanion.Control/POLICY_STORAGE.md)
for DPAPI/ACL ownership, tombstone retention and whole-database recovery limits.

Host limits: 16 concurrent connection attempts/sessions, 4 per owner, 120 requests
per connection per minute, 90-second idle/incomplete-frame timeout, 15-second
request/response I/O budget. The Swift caller has a 20-second exchange deadline and
actively closes blocked I/O on cancellation. Malformed envelopes/frames, limits
and transport errors close the stream; ordinary permission/operation errors return
a sanitized response and do not automatically retry.

**Application integration must maintain control presence**, for example a scoped
`device.status` poll every 30 seconds while a session is intended to stay open,
serialized with other requests. The current library has no automatic reconnect,
heartbeat or unattended enablement. Letting the 90-second idle lease expire closes
the session and cancels default connected tasks. Future UI/XPC integration must
test this lifecycle rather than assuming an unused socket remains online.

## Local verification boundary

C# tests use actual loopback mutual TLS, SQLite WAL and disposable protected data;
Swift interoperability calls the production dispatcher/runtime over pinned TLS.
Only fixtures supply fake grants, encryption keys and inert echo/block executors.
These tests are not Windows DPAPI, standard-account PowerShell, service boot,
real UAC, deployed relay or sandbox/XPC acceptance.
