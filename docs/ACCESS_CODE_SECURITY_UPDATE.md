# Access-code security update

The relay, Mac client and independent Windows Companion must be upgraded together.
Relay authentication now uses V2 only, with the configured HTTPS origin included
in every signed transcript. There is no automatic V1 fallback. Outer HTTPS/WSS
certificate policy remains owner-selected; inner pinned mutual TLS is unchanged.

## Fixed behavior

- A saved Windows identity belongs to one saved target. Knowing public device or
  grant identifiers cannot borrow another target's AI permissions. Ownership is
  retained across unbind/restart; ambiguous legacy aliases fail closed.
- Windows activation requires a durable Mac-signed confirmation for the exact
  invitation, claim, device identities, relay and validity interval. A relay's
  unsigned `bound` field cannot activate permissions, including after expiry.
- Device revocation is persisted locally before network submission. Pending
  revocation denies new control/file/RDP operations. The signed request remains
  queued across reconnect/restart. Windows revokes the exact pairing and grant
  epoch, cancels and drains its tasks/sessions, then signs a completion receipt.
  Only that pinned Windows receipt produces `revoked`; offline remains
  `revocationPending`. Completed revocation still denies the old three grants.
- Revocation completion relies on signed request identity and peer proof, not
  synchronization between the two machines' wall clocks.
- The relay uses stateless authentication challenges and separates anonymous
  request limits from authenticated device budgets. Per-source rejection cannot
  consume another source's global enrollment allowance.

The existing pure-local trust removal action remains explicitly labeled local.
The device-permission revocation action and MCP `revokeRelay` use the signed
endpoint mailbox; neither requires an additional pairing approval. Legacy manual
imports without a locally verified pairing epoch cannot claim remote revocation
success and return `VERIFIED_PAIRING_EPOCH_REQUIRED`.

## Upgrade and recovery

Configure the node's `Relay.PublicOrigin` to the canonical HTTPS origin used by
both endpoints (include a non-default port and omit a trailing slash). Update all
three components before testing independent relay connections. Existing 2.0 DVC
control is unchanged. Historical access-code `bound` records without signed
confirmation are not accepted as V2 authorization; upgrade Windows and generate
a new code. Pending codes, confirmed receipts and revocation retries retain
exact persisted proof rather than silently replacing authorization.

New target installation, actual Windows 10/Server 2019 LAN/relay execution,
unattended restart and RDP acceptance remain separate from development tests.
