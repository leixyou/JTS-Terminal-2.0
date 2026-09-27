# Third-party components

The generated native runtime uses FreeRDP 3.31.1 and OpenSSL 3.6.4, pinned by
source archive SHA-256 in `scripts/build_freerdp.sh`. Keep all accompanying
`Vendor/FreeRDP/Licenses` files and `Vendor/FreeRDP/sbom.cdx.json` when distributing
a build. The cpufeatures notice is a separate retained third-party notice.
The generated XCFramework is excluded from Git and rebuilt locally.

Swift dependencies are pinned by `Package.resolved`; resolve and retain their
upstream notices in any redistributed binary. Current dependency families are:

| Dependency | Upstream license family |
| --- | --- |
| SwiftTerm, Citadel, BigInt | MIT |
| SwiftNIO, the pinned swift-nio-ssh fork, Swift Crypto, Swift Log, Swift ASN.1 | Apache-2.0; retain upstream NOTICE where provided |
| Swift Atomics, Collections, System, Argument Parser | Apache-2.0 with upstream Swift exception where provided |
| FreeRDP, OpenSSL | Apache-2.0 plus bundled third-party notices |

Consult each exact pinned revision's license and notice, rather than treating
this table as a replacement for upstream terms. In particular, the SSH package
is a pinned fork and Citadel is pinned by revision. `scripts/audit_rdp_dependencies.sh`
checks the native source inputs and can refresh dependency review data; generated
audit reports remain local build outputs.

The relay protocol directory is a checksummed data-only source snapshot. Its
provenance records the original publisher and snapshot process; it is not a
runtime download or source link to a sibling service repository.
