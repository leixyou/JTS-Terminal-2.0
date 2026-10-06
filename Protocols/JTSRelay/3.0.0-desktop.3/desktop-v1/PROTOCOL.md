# Desktop extension v1

Frozen 2026-10-02. This additive extension leaves v1 rendezvous, security-v2
authentication, enrollment, the three legacy grants, and their signed transcripts
unchanged. `/v1/info` retains its original exact fields. `/v1/capabilities`
advertises `desktop-v1` and the additional `desktop` lane.

## Rendezvous and encrypted transport

Create `desktop` sessions using the existing signed `sessions` request. Tickets
remain one-use, short-lived and peer scoped. The relay forwards opaque bytes;
endpoints perform pinned device-key mutual TLS and verify the exact session and
lane binding. Outer certificate compatibility does not disable encryption or
the inner identity verification.

Desktop has independent aggregate/session bandwidth pacing, concurrency and
persisted monthly limits. The relay pumps at most 16 KiB per direction without
an application queue. It never discards arbitrary ciphertext because that would
corrupt TLS. Windows bounds its encoded-frame queue and discards complete old
frames before encryption. Control and file traffic use their existing pacers.

## Desktop authorization sidecar

The authenticated control request is `{version:1,id,operation:"desktop.authorize",
grantId:<parent control grant>,parameters:<proof>}`. A valid parent pairing and
its Status permission are required. No RDP grant implies desktop permission.
Pairing ID is the immutable parent epoch. The sidecar persists separately;
legacy pairing storage and signed enrollment/revocation fields stay byte exact.

The proof has exactly these fields: `version`, `relayOrigin`, `targetBinding`,
`companionDeviceId`, `controllerDeviceId`, `pairingId`, `controlGrantId`,
`desktopGrantId`, `issuedAtUnixSeconds`, `expiresAtUnixSeconds`,
`controllerSpkiBase64`, `signatureBase64`.

Version is 1. UUIDs are lowercase canonical nonzero D-format. IDs and target
binding are lowercase 64-digit SHA-256 hex. Relay origin is canonical HTTPS
scheme/host/port with no path, query, credentials or trailing slash. HTTP is
allowed only for explicit loopback tests. Public keys are canonical DER P-256
SPKI encoded as standard Base64; controller ID equals SHA-256 of that SPKI.
Signatures are P-256/SHA-256, IEEE P1363 fixed-width 64 bytes, standard Base64.

Proof bytes are UTF-8, LF-separated, with no trailing LF, in this exact order:

```
jts-desktop-grant-v1
1
relayOrigin
targetBinding
companionDeviceId
controllerDeviceId
pairingId
controlGrantId
desktopGrantId
issuedAtUnixSeconds
expiresAtUnixSeconds
controllerSpkiBase64
```

Issued time must be within 120 seconds of Windows time. Expiry must follow both
issued/current time, be no later than the parent pairing/control expiry, and no
more than 366 days after issue. Reusing a desktop ID for another binding, proof,
target or revoked permission is rejected. Durable exact repeats are idempotent.
After a lost acknowledgement, an exact signed proof for an already committed,
active sidecar may recover its original commit time outside the 120-second issue
window. Signature, all bindings, active parent and expiry are still required;
this exception cannot create or change a grant. Mac persists pending proof
identity, issue/expiry and grant ID before sending it.

Success returns exactly `version`, `desktopGrantId`, `pairingId`, `targetBinding`,
`companionDeviceId`, `controllerDeviceId`, `proofSha256`,
`committedAtUnixSeconds`, `signatureBase64`. Windows signs only after durable
commit and a fresh parent-policy check. Acknowledgement bytes are UTF-8,
LF-separated, with no trailing LF:

```
jts-desktop-grant-ack-v1
1
desktopGrantId
pairingId
targetBinding
companionDeviceId
controllerDeviceId
proofSha256
committedAtUnixSeconds
```

Mac checks all bindings, exact proof hash and pinned Windows signature before
storing the permission. Windows rechecks the parent epoch and control grant for
lane admission and desktop operations. Parent revocation durably tombstones
sidecars, closes desktop lanes and drains agents before the existing signed
parent revocation completion can be issued.

## Desktop lane initialization and frames

After inner TLS/session binding, send existing lane framing: 4-byte big-endian
JSON length and `{version:1,id,operation:"desktop.open",grantId,parameters:{}}`.
The handler verifies the exact independent desktop grant, returns
`{version:1,id,ok:true,result:{ready:true},errorCode:null}`, then switches to the
desktop envelope framing.

Desktop envelopes are 4-byte big-endian length plus strict camelCase JSON,
maximum 8 MiB: `{version:1,kind,id?,operation?,generation,sessionId,body,
payloadBase64?}`. Kind is request/response/state/frame. Generation is a UUID;
sessionId is the actual Windows session. Frame payload is an encoded image or
video access unit, never a relay-readable structure. Credentials travel only
inside pinned TLS and validated local IPC and are never persisted or echoed.
UTF-8 must be valid without a BOM. Duplicate fields at every nesting level,
unknown envelope fields, missing required fields and control characters in
request IDs/operation names are rejected before dispatch.

Input requires current observation and generation. Lock/login/UAC, session,
monitor and agent changes invalidate observations and queued input. Disconnect
releases held keys/buttons; reconnect takes a fresh observation, never replay.

### Optional pushed viewport streaming

`startStream` requests a viewport stream with optional `body.frameRate` in 5..30
(default 30). Its correlated response precedes unsolicited envelopes.
`stopStream` stops capture and drains pending source frames before acknowledging.
Pushed frames use `kind:"frame"`, `id:null`, `operation:null`; `body` includes
frameID, observationID, codec, width/height, originX/Y, dpiX/Y, capturedAt and the
actual state. Unavailable output or session change sends `kind:"state"` with no
pixels and an explicit status/error. These viewport observation IDs never enter
the actionable observation ledger. AI/manual `observe` returns an independent
JPEG snapshot; it does not advance the H264 encoder or disrupt reference frames.

`streamFeedback` accepts `body.deliveryLatencyMs` (1..30000) and
`body.deliveredBytes` (1..8388608), without image/credential diagnostic content.
Congestion reduces target bitrate/frame rate within 500kbps..4Mbps and 5..30fps.
Status/feedback traffic retains the 30-second input lease. The Mac keeps a live
stream leased with status at least every 10 seconds; disconnect or grant loss
cancels streaming and releases managed held input.

There is one independent bounded video slot and a bounded priority RPC-reply
queue at each desktop endpoint. Capture credit is acquired before encoding;
when congested the next capture takes the newest desktop pixels. H264 reference
access units remain in order: discarding an encoded P frame is forbidden without
an explicit codec reset/keyframe recovery. No opaque TLS chunk is discarded by
the relay. RPC replies take the next writer turn before video; commands and
files remain on their independent service lanes.

The fixture publishes disposable test keys (scalars 1 and 2) as test data only.
It is not an installation capability or a production identity.
