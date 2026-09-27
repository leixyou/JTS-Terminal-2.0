# JTS Relay security v2

This additive, data-only snapshot supersedes authentication V1 and unsigned
enrollment confirmation. Existing `v1` and `enrollment-v1` snapshots remain
immutable historical specifications. Paths remain `/v1/...`; authenticated
requests now require the V2 signature. There is no V1 fallback.

## Audience and challenge proofs

The operator must configure `Relay.PublicOrigin` as the exact public origin.
Canonical origins have a lower-case host/scheme, no user info, path other than
`/`, query, fragment or trailing slash. Default ports are omitted; nondefault
ports are included. Production origins require HTTPS. Explicit development
mode can use HTTP with a numeric loopback address only. Endpoints sign the
configured destination origin, never an origin supplied in a challenge reply.

The existing challenge envelope is unchanged. A device signs UTF-8, no trailing
newline, with ECDSA P-256/SHA-256 and 64-byte IEEE P1363 signature encoding:

```
JTS-RELAY-AUTH-V2
canonicalOrigin
deviceId
operation
challengeId
nonceBase64
payloadHash
```

`payloadHash` is lowercase SHA-256 of decoded `payloadBase64`. Operations are
`presence`, `devices`, `sessions`, `poll`, `enrollment`, and `revocations`.
Challenge IDs and nonces are opaque. Challenge lifetime remains 60 seconds.
Issued challenges allocate no per-device pending state. Source address issuance
and proof-attempt quotas are separate from quotas charged after valid signatures.
Invalid proofs cannot consume a challenge or a device quota. Successful proofs
atomically consume bounded replay state until expiry. Server restart invalidates
outstanding stateless challenges by changing the in-memory HMAC key.

## Signed confirmation

`POST /v1/enrollment` still uses signed operation `enrollment`. Confirm payload:
`{action:"confirm",invitationId,claimHash,confirmation}`.

The exact confirmation object is:
`{version:2,relayOrigin,invitationId,controllerDeviceId,peerDeviceId,claimHash,confirmedAtUnixSeconds,expiresAtUnixSeconds,signatureBase64}`.

The Mac signs this UTF-8 transcript (no trailing newline):

```
JTS-PAIR-CONFIRM-2
relayOrigin
invitationId
controllerDeviceId
peerDeviceId
claimHash
confirmedAtUnixSeconds
expiresAtUnixSeconds
```

Identifiers, claim hash, audience and expiry must match the immutable invitation
and independently verified Windows claim. Confirmation time is positive and
strictly before invitation expiry; a node allows at most 30 seconds future skew.
The first confirmation must arrive before expiry. The exact signed confirmation
is persisted atomically with admission. Exact retries remain recoverable after
expiry; another signature or payload for the same invitation is rejected.

Enrollment receipts add optional `confirmation`; new bound receipts require it.
Cancelled receipts preserve a previously stored confirmation and claim. A
Windows endpoint must verify the Mac signature with its pinned/request-carried
controller key before creating grants, including recovery after expiry. A bare
relay `state:"bound"` is never endpoint authorization. Old persisted bound rows
cannot acquire a fabricated signature: clients must explicitly re-enroll them.
Existing admitted devices/edges remain available with updated V2 authentication.

## Signed revocation mailbox

Use authenticated operation `revocations`, `POST /v1/revocations`. Strict payloads:

- `submit`: `{action:"submit",revocation:request}` (controller only).
- `status`: `{action:"status",revocationId}` (named controller or peer only).
- `poll`: `{action:"poll"}` (companion only, its pending requests).
- `complete`: `{action:"complete",receipt}` (named companion only).

Request object:
`{version:2,revocationId,relayOrigin,controllerDeviceId,peerDeviceId,pairingId,grantId,fileGrantId,rdpGrantId,requestedAtUnixSeconds,signatureBase64}`.
All UUIDs use lowercase canonical nonzero UUID form; device IDs/hash values use
lowercase SHA-256. Base64 is canonical standard encoding. Timestamps are positive
integer Unix seconds. The Mac signs:

```
JTS-PAIR-REVOKE-2
revocationId
relayOrigin
controllerDeviceId
peerDeviceId
pairingId
grantId
fileGrantId
rdpGrantId
requestedAtUnixSeconds
```

`requestHash = SHA256(UTF8(transcript) || decodedRaw64MacSignature)` in lowercase
hex. Requests do not expire: an offline endpoint must still revoke the exact
named pairing/grant epoch when it reconnects. An old epoch must not revoke a
newly paired epoch. Revocation timestamps are positive integer metadata; they
are not compared across controller, endpoint or node clocks for authorization.

Windows completion object:
`{version:2,revocationId,requestHash,controllerDeviceId,peerDeviceId,revokedAtUnixSeconds,signatureBase64}`.
Windows signs:

```
JTS-PAIR-REVOKED-2
revocationId
requestHash
controllerDeviceId
peerDeviceId
revokedAtUnixSeconds
```

Windows must durably tombstone exact grants/pairing and stop/drain their active
and detached jobs before signing completion. Completion time need not follow
request time on a different device's wall clock. Mac verifies with its
locally pinned peer key. A relay-only state transition is not completion.

Submit/status/complete return exactly:
`{revocationId,requestHash,state:"pending"|"complete",revocation:request,controllerSPKIBase64,receipt?}`.
Pending omits `receipt`; complete includes it. Poll returns
`{revocations:[view,...]}` with at most 32 pending entries and 64 KiB response.
The controller SPKI permits old installations storing only its hash to validate
the key hash before checking the signature; it is not a new trust anchor.

Submit atomically persists the request and removes that controller/peer edge,
then closes all affected tickets and active lanes before acknowledgment. The
companion identity remains admitted so it can poll and acknowledge. Another
controller's edge is unaffected. Only the matching Windows signature completes
the mailbox. Repeated identical requests/receipts are idempotent, including
after restart; changed content under the same ID is rejected. Replaying an old
completed submit does not cut a newer edge. A new binding for an edge with pending
revocations is rejected until completion. Mailbox storage is bounded globally
by `MaxStoredEnrollments` and by 128 pending entries per companion; exhaustion
fails closed and never discards pending revocations.

The old enrollment `revoke` action remains explicitly node-only for legacy
operators; new endpoints use this signed mailbox for endpoint revocation.

## Threat boundary and migration

The node is an opaque rendezvous/forwarder and never receives link secrets or
terminates endpoint TLS. A compromised node can deny, delay, reorder, or suppress
delivery. Endpoint signature, pinned-key and epoch checks prevent it from inventing
confirmation or completion. Suppression leaves revocation visibly pending; a
network protocol cannot prove an offline endpoint stopped work without its
signed receipt. The user's selected outer certificate policy is unchanged:
HTTPS/WSS encryption remains, endpoint PKI validation may be skipped; inner
device-pinned TLS/mTLS remains mandatory.

Upgrade both endpoint implementations and configure PublicOrigin before starting
this server version. Old Auth V1 clients fail closed. Existing durable registry
data migrates in place with new confirmation and revocation tables, without
re-seeding previously revoked static edges. Back up the database before operator
upgrade. Never publish private node configuration or production identities.

## Fixtures

`fixtures/auth-v2.json`, `confirmation-v2.json` and `revocation-v2.json` are
independently generated Python cryptography vectors using public test private
scalars 1 and 2. They are not production credentials. They specify exact UTF-8
transcripts and raw64 signatures. The confirmation reuses the immutable
`enrollment-v1/fixtures/enrollment.json` encrypted claim hash.
