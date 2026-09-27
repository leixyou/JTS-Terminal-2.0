# Local one-shot Worker IPC — wire version 1 (development)

This is a Windows endpoint-internal pipe protocol, not a network listener or a
relay capability. OS pipe ACLs and independently verified peer process identities
are prerequisites. Metadata in a frame never authenticates its sender. There is
no plaintext-network transport fallback. The service-launch integration remains
incomplete; this document is an implementation contract, not a release claim.

Every frame has a fixed 48-byte header followed by a bounded body:

| Offset | Bytes | Field |
| --- | --- | --- |
| 0 | 4 | ASCII `JTW1` (version included) |
| 4 | 1 | Message type |
| 5 | 3 | Reserved, all zero |
| 8 | 4 | Body length, unsigned big-endian |
| 12 | 16 | Exact nonzero launch session UUID, network byte order |
| 28 | 16 | Exact nonzero task UUID, network byte order |
| 44 | 4 | Per-direction sequence, starts at 1, strictly increases without wrap |

Reject unknown types, wrong session, zero task ID, reserved bits, sequence replay
and invalid length **before body allocation**. Only one reader and one writer
own each direction; output writers are serialized. Buffers containing payloads
and output are zeroed when released. No payload or exception detail is logged.

Types: `1 Execute` (authority→Worker, once), `2 Pulse` (authority→Worker),
`16 Output` (Worker→authority), `17 Result` (Worker→authority, once). Each side
rejects a type that is invalid for its state/direction. Every post-Execute frame
must match the executing task UUID. No additional request loop exists.

Execute body is 93–65,629 bytes of fixed metadata plus nonempty payload:

| Offset | Bytes | Field |
| --- | --- | --- |
| 0 | 8 | Deadline Unix milliseconds, signed big-endian |
| 8 | 1 | Explicit detached permission, 0 or 1 |
| 9 | 16 | Nonzero grant UUID, network byte order |
| 25 | 32 | Owner device fingerprint bytes |
| 57 | 32 | Payload SHA-256 |
| 89 | 4 | Payload length, unsigned big-endian |
| 93 | 1–65,536 | Exact `powershell.v1` payload bytes |

Minimum total body is therefore **94** bytes. Kind is fixed to `powershell.v1`,
not caller-selected. Deadline must be future and no more than 24 hours; the exact
payload digest/count must match. This copies an already authorized runtime binding,
not a new grant. The Worker also enforces its local deadline.

Pulse body is empty. Authority emits one every two seconds, with a two-second
write budget; Worker allows seven seconds to receive the next complete valid
frame. This lease is independent of RDP and controller network presence.

Output body is 1–4096 bytes. IPC hard ceiling is 1 MiB per task on both sides;
the ledger normally applies its lower 128 KiB bound. Sink rejection closes the
session and triggers independently supervised process shutdown. There is no
unbounded intermediate queue or output retry.

Result body is exactly one enum byte: 0 succeeded, 1 failed, 2 cancelled,
3 unknown, 4 PowerShell nonzero. It carries no free-text diagnostic. Nonzero
PowerShell preserves `POWERSHELL_EXIT_NONZERO`; ordinary failure becomes
`JOB_EXECUTION_FAILED`. A result is provisional until the authority's own Job
Object reports no active processes. Unconfirmed stop or ambiguous result delivery
becomes interrupted/unknown; only independently confirmed stop permits completion.
No automatic retry, replay or privileged execution is defined.
