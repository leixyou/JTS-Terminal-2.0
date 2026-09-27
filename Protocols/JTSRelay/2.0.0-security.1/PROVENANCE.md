# Independent security-v2 data snapshot

Snapshot: 2.0.0-security.1, frozen 2026-09-27.
Source repository: https://github.com/leixyou/JTS-Relay
Source commit: 0c45fa65aa7f8baad32c581c13996260cd88935c
Source directory: protocol/security-v2

The upstream PROTOCOL.md SHA-256 is
33df1d64b973c7363a2df29441225d0111bdfe4eb0ca67ea3ba3121ad5cb9a84.
The security-v2 subtree, including its SHA256SUMS, is copied byte-for-byte
from that source commit. The root SHA256SUMS also covers this provenance
file and the upstream inventory.

Only a specification and public fixed-key test vectors are included. The vectors
publish test scalars 1 and 2; they are not production credentials. There is no
relay source code, project dependency, private identity or runtime configuration.
Existing 1.0.0-alpha.1 and 1.0.0-enrollment.1 snapshots remain unchanged. New
endpoint builds consume the V2 signature contracts without V1 fallback.

Revocation timestamps are positive signed metadata. They are not compared
across device clocks; completion requires the exact request hash and the
paired Windows identity signature.
