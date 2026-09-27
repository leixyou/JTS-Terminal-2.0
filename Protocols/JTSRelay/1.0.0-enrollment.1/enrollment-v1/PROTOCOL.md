# JTS one-use enrollment, version 1

This additive protocol leaves the existing relay v1 transport unchanged. Enrollment
does not require an RDP session or a successful Windows login. It establishes a
durable, revocable device relationship; RDP authentication is a separate operation.

## Invitation and cryptography

The controller generates a random UUID and a cryptographically random 32-byte secret.
The user transfers a single URI:
`jts-pair://enroll?relay=<percent-encoded HTTPS origin>&id=<lowercase UUID>&key=<unpadded base64url secret>`.
Reject duplicate/unknown parameters, user info, fragment, invalid UUID, noncanonical
base64url, or an origin with path/query/fragment. Normalize origin host to lowercase,
omit port 443 and trailing slash. No secret is sent to the relay or written to logs.
This is a high-entropy access code, not a short numeric password.

HKDF-SHA256 (RFC 5869) derives separate 32-byte keys from that secret. Salt is UTF-8
`JTS-PAIR-1\n<invitationId>`; info is UTF-8 `offer`, `response`, or `relay-claim`.
The derived relay-claim bytes form the claim token; the relay stores only its SHA256.
AEAD is AES-256-GCM, encoded as nonce(12) || ciphertext || tag(16), canonical Base64.
Every encryption uses a fresh random nonce, and retries reuse the persisted ciphertext.
Offer AAD is UTF-8 `JTS-PAIR-1\n<invitationId>\noffer`.
Response AAD is UTF-8 `JTS-PAIR-1\n<invitationId>\nresponse\n<offer SHA256>`.
All digests below are lowercase hex SHA256 over decoded bytes.

Offer plaintext is strict JSON:
`{version:1,relayOrigin,requestBase64,requestSha256}`.
The request is the existing ownerDelegated request, including controller SPKI/device
ID, pairing and distinct lane grant UUIDs, issued/expiry times and explicit TLS policy.
Its exact bytes and digest are preserved. No second owner approval is introduced.

Response plaintext is strict JSON:
`{version:1,invitationId,relayOrigin,requestSha256,enrollmentBase64}`.
Enrollment is the existing public Windows enrollment bundle. Both endpoints verify
all request bindings, public identities, lane grants and TLS policy before trusting it.

Claim transcript is the following UTF-8 string, without a final newline:
`JTS-PAIR-1\n<invitationId>\n<controllerDeviceId>\n<offer SHA256>\n<response SHA256>\n<peer SPKI SHA256>`.
`claimHash` is its SHA256. Windows signs the transcript using ECDSA P-256 with SHA256;
signature is the 64-byte IEEE P1363 representation. Do not hash twice. The relay and
Mac verify the signature against the canonical SPKI. Ciphertext authentication also
binds the response to the independent secret, so the relay cannot substitute a key.

## Relay API

All requests are HTTPS. Existing outer-certificate policy remains unchanged; inner
endpoint TLS still verifies the enrolled pins and client certificates.

The existing challenge authentication adds operation `enrollment`, POST
`/v1/enrollment`. Only an admitted controller may use it. Signed payloads:

- create: `{action:"create",invitationId,claimTokenHash,offerBase64,expiresAtUnixSeconds}`
- status / cancel: `{action:"status"|"cancel",invitationId}`
- confirm: `{action:"confirm",invitationId,claimHash}`
- revoke: `{action:"revoke",peerDeviceId}`

Expiry at creation must be 300–1800 seconds ahead. Repeating identical create is
idempotent. Controller ownership is checked on every operation. Existing registered
controllers remain valid; anonymous controller enrollment is never enabled.

Public token-authenticated endpoints:

- POST `/v1/enrollment/offer`: `{invitationId,claimTokenBase64}`
- POST `/v1/enrollment/claim`: same plus `peerSPKIBase64,responseBase64,signatureBase64`
- POST `/v1/enrollment/receipt`: same as offer

Response is `{invitationId,controllerDeviceId,state,expiresAtUnixSeconds,offerBase64,claim?}`.
State is pending / claimed / bound / cancelled / expired. Claim, when present, is
`{peerSPKIBase64,responseBase64,signatureBase64,claimHash}`. Revoke instead returns
`{peerDeviceId,state:"revoked"}`. All JSON parsers reject duplicate and unknown keys.
Offer and response ciphertexts each have a decoded limit of 8192 bytes; token is
exactly 32 bytes and signature exactly 64 bytes. Bound storage, request rates and
outstanding invitations. Never log bodies, codes, tokens, signatures or plaintexts.

## Commit, retry and revocation

1. Mac durably saves its invitation before creating it on the node.
2. Windows fetches and verifies the encrypted offer, stages its proposed pairing/grants
   and immutable response in protected local storage, then submits the claim. It does
   not activate those permissions while the invitation is only claimed.
3. Claim does not grant relay access. Mac decrypts and verifies the response, saves
   the verified material durably, then confirms that exact claim hash.
4. The node atomically marks the invitation bound and adds reciprocal admission.
   Only this commit consumes the code. Windows journals the bound receipt and commits
   grants before pairing; a crash resumes that same commit. Mac completes local import
   and retries its grant check until the Windows service is ready.

Identical claim/confirm requests are idempotent. A different claimant or changed
ciphertext cannot take over a claimed/bound invitation. A committed receipt remains
recoverable with the same token after original expiry; it cannot enroll another device.
Expired unbound requests require a new invitation. A disconnected endpoint resumes
the same saved attempt, including its ciphertext, instead of making a new identity.

An RDP login failure does not consume or invalidate an invitation and does not revoke
a bound device. Repair credentials/NLA/RDP configuration and reconnect with the same
device authorization. A still-unbound code remains subject to its original expiry.

Revocation removes only the requesting controller's reciprocal peer edge, invalidates
associated invitations/tickets, and terminates active sessions for that relationship.
Do not revoke another controller's relationship. Local trust/pairing revocation remains
authoritative as well. Restart must not resurrect either revoked edges or stale tickets.
Static device configuration is seeded into durable dynamic admission only once.

## Acceptance

Verify concurrent claims, exact retry after lost responses, restart recovery, expiry,
substituted keys/ciphertexts, controller isolation, bounded resource use, revocation of
active lanes, and independence from failed RDP login. Cross-language fixtures and unit
tests do not replace real Windows installation and complete encrypted network checks.
