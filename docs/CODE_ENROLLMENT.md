# Code-based Windows enrollment

## One-use access code

The new enrollment path separates device binding from RDP login. In Companion
Devices, choose **Access code**, enter the HTTPS relay origin, select Windows
10 / Server 2019 compatibility when needed, and copy the code into the Windows
Companion manager. The Mac completes the verified exchange while that sheet is
open. Existing AI desktop control already includes this delegation.

MCP clients use `jts_device_status action=createCode` with `relayURL` and optional
`allowWindows10TLS12`, then repeat `action=codeStatus` with the returned
`invitationId` until `complete`. `bound` means device authorization is durable;
`complete` additionally means the independent control grant was checked and the
saved target route was bound. Neither state asserts that RDP login succeeded.
`cancelCode` cancels an unbound invitation; `revokeRelay` removes a bound target's
relay relationship and closes its active relay lanes.

The code is valid for 30 minutes while unbound. Wrong RDP credentials, NLA failure,
or a closed RDP port do not consume it. Once binding commits, the code is consumed
and device authorization remains until revoked. Network retries reuse the exact
stored request and response; a lost successful reply can be recovered after the
original code expiry. An expired request that never reached the node gets an
explicit expired state and can be replaced without reinstalling Windows.

Invitations use a 256-bit secret and authenticated encrypted key exchange. The
relay stores a derived token hash and opaque messages, not the code or endpoint
private keys. The new dynamic admission store migrates existing node devices once;
each later Windows binding is committed without editing JSON or restarting the
relay. A node operator admits the Mac controller once through the local node CLI.

The new Windows manager works with the enrollment-enabled Authority service.
Earlier packages without the management pipe must be upgraded; the manager reports
that state rather than overwriting a live installation. Native installation still
uses the normal Windows UAC boundary.

The immutable protocol snapshot is in `Protocols/JTSRelay/1.0.0-enrollment.1`.
Live Windows installation, a real remote command, and RDP login remain separate acceptance checks.
