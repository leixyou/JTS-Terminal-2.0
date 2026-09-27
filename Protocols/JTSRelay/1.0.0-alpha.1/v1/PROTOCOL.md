# JTS Relay protocol 1 (draft, alpha.1)

This versioned, data-only contract is independent of both client source trees.
Changing this file requires matching fixtures and endpoint compatibility tests.
The relay forwards opaque inner TLS streams; it is not a command or RDP server.

## Encoding and identity

JSON uses UTF-8 and camelCase. Protocol version is integer 1. Unknown required
versions fail closed. Device identity is lowercase hexadecimal SHA-256 of the
DER SubjectPublicKeyInfo of a P-256 signing key. Public keys use standard Base64.
Signatures are 64-byte IEEE-P1363 (r || s), P-256 with SHA-256, standard Base64.
Operators explicitly admit public keys and peer relationships on their node.
Node admission does not replace endpoint pairing or MCP consent.

## HTTP APIs

All deployment traffic uses HTTPS; development HTTP is explicit loopback-only.
GET /healthz returns non-sensitive liveness. GET /v1/info returns protocolVersion
and supported lanes (control, file, rdp), without listing devices.
The exact info response is {protocolVersion:1,lanes:["control","file","rdp"]}.
Clients verify it before using the authenticated APIs; a different major version
must not trigger a legacy or plaintext fallback.

POST /v1/challenges accepts {deviceId, operation}. operation is one of presence,
devices, sessions, poll. It returns {challengeId, nonceBase64, expiresAtUnixSeconds}.
Challenges expire after 60 seconds and are single-use even after failed proofs.

POST /v1/{operation} accepts an authenticated envelope:
{deviceId, challengeId, payloadBase64, signatureBase64}.
The signature input is UTF-8, joined by LF with NO trailing LF:

    JTS-RELAY-AUTH-V1
    deviceId
    operation
    challengeId
    nonceBase64
    lowercase-hex-SHA256(decoded-payloadBase64)

The payload is a JSON object, bounded to 16 KiB. Envelope/body limits, challenge
count, per-identity rates, waiting/active sessions and sockets are bounded.
The challenge is bound to operation, identity and this relay process.
Each device has at most 128 admitted peers and 32 waiting/active sessions; these
bounds keep devices/poll responses below 32 KiB without pagination in protocol 1.
JSON envelopes reject duplicate, missing and unknown fields.
Admission preserves `max(1, floor(MaxSessions/4))` globally free slots and one
free slot per device for new control channels: a new file/RDP offer is rejected
when current occupancy reaches the corresponding limit minus reservation.
Control offers may use the full hard limit. Counts include waiting and active
sessions of every lane; existing streams are not evicted. Both configurable
session limits must be at least two.

- presence payload {}: register/touch last-seen; response {deviceId}.
- devices payload {}: {devices:[{deviceId,lastSeenAtUnixSeconds:null|integer}]},
  listing only admitted peers with last-seen metadata.
- sessions payload {peerDeviceId, lane}: controller requests one fresh stream;
  response {sessionId, ticket, expiresAtUnixSeconds, channelPath:"/v1/channel"}.
- poll payload {}: Companion receives {offers:[...]}; each offer contains the
  same sessionId/lane, controllerDeviceId, its OWN ticket and expiry/channelPath.
  Poll may repeat an unclaimed offer until expiry; claiming is atomic.

Session IDs are server-generated UUIDs. Tickets are random 256-bit bearer values,
base64url without padding, role-specific, single-use and expire after 60 seconds.
They are bound to session, lane and device pair. No client can choose a target
host/port. Pair permissions must be reciprocal; controller initiates, Companion
polls. Revocation in operator configuration requires a service restart in alpha.1;
restart closes all sockets and invalidates challenges/tickets. Live reload is not
claimed. Endpoint grant revocation is independent and enforced by endpoints.

## Data channel

Connect WebSocket /v1/channel with Authorization: Bearer <ticket>, never a query
string token. After both endpoints attach, each receives one text message
{"ready":true,"sessionId":"...","lane":"control|file|rdp"}. Before readiness,
clients send no payload. Subsequent messages MUST be binary; message fragments
are an ordered byte stream, not application record boundaries. No compression.
The relay forwards bounded chunks without accumulating whole messages. Close,
timeout or quota failure closes both ends, and tickets cannot be reused.

Endpoints then establish mutually authenticated TLS over this byte stream using
previously paired SPKI pins (Mac TLS client, Windows TLS server). Win11 uses
TLS1.3; explicitly enrolled Win10 may use TLS1.2 ECDHE_ECDSA/AES_GCM. Disable
0-RTT/resumption initially. Require ALPN `jts-relay-v1`. The relay's HTTPS identity is separate from these
endpoint keys. No plaintext application fallback is allowed. Application lane
binding inside TLS must match the expected sessionId, lane and device pair before
any command, file or RDP data is accepted. This contract does not claim that
endpoint TLS or application adapters have been implemented merely by defining it.

After TLS succeeds both endpoints send, then read, a UInt32 big-endian byte length
followed by UTF-8 JSON, at most 1024 bytes:
{protocolVersion:1,sessionId,lane,controllerDeviceId,companionDeviceId}.
Both compare every field with their authenticated rendezvous expectation. Reject
duplicates, missing/unknown fields, invalid types, oversized records and mismatch.
Do not expose any application bytes until this binding exchange has succeeded.

Control/file/RDP use separate sockets and flow-control budgets. Persist only
minimal operational metadata and aggregate outbound usage. Never persist opaque
stream bytes, tickets, signatures, full envelopes, command output or file data.

Errors use bounded {code} responses without exception details or secrets. Clients
must not automatically retry sessions/commands on protocol/authentication errors.
