# Architecture and trust boundaries

`JTSTerminal` owns the native workspace, profile vault, permission model, MCP
bridge and direct Windows task routing. `JTSSHAskpass` is a sandbox-inheriting
credential prompt helper. `JTFreeRDPService` isolates the native parser and RDP
transport in an XPC service; shared XPC declarations live in `RDPXPCShared`.

`JTCompanionTransportService` is a separate outgoing-network XPC helper. The
local `JTSCompanionTransport` package contains typed IPC, control and file
clients, device registry types, lane transports and the pinned TLS implementation.
Normal command/file/structured UI operations use these direct channels, with
capability checks and structured responses. RDP display and input remain a
separate visual route. Commands do not fall back to simulated keystrokes.

A device's existing AI desktop-control authorization includes pairing delegation.
The enrollment request and returned public bundle bind device identities and
separate control/file/RDP grants. Delegation and grants are revocable; knowing a
relay address alone does not admit or authorize a Windows device. Operating
system UAC and signing boundaries still apply to installation.

The independent relay is a separate service and repository. This repository
carries a versioned data-only protocol snapshot under `Protocols/JTSRelay` with
checksums. It has no relay service source or sibling project reference. The
outer relay HTTPS/WSS connection currently defaults to skipping server PKI
validation while retaining TLS encryption. The inner end-to-end connection still
requires paired device SPKI pinning and mutual authentication. The relay cannot
replace an enrolled endpoint's identity merely by presenting its outer
certificate.

The standalone Windows source is not embedded here. Installer resources enter
the Mac build as explicitly supplied, hash-checked artifacts. Bootstrap/setup
and normal authenticated operations are distinct stages; a setup bundle is not
proof that a newly installed Windows endpoint has completed live acceptance.

This source export preserves app/helper identity checks and sandbox entitlements.
Local development team selection rewrites fixed compile-time pins before a build;
there is no runtime environment option for bypassing peer authentication.
