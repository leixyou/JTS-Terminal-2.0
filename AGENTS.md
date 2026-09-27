# Contributor instructions

Keep the Apple client, Windows Companion and relay as separate components.
Consume the immutable data-only relay protocol snapshot; do not add sibling
source/project references. Keep existing DVC behavior intact while working on
independent routes.

Use the `JTSTerminalRDP2` macOS scheme. Keep test products in `DerivedData/Tests`
and normal development products in `DerivedData/Run`. Use
`script/build_and_run.sh` for the daily Debug application and
`scripts/retain_latest_debug_and_release.py` after a completed build/test cycle.
Do not weaken helper entitlements or signed IPC authentication to make an
instrumented test host behave like the normal app.

Configure your development team with `scripts/configure_signing.py`; keep the
exact Apple anchor, bundle identity and team checks. Do not commit credentials,
provisioning profiles, local grants, enrollment identities, logs or build outputs.

Prefer small, coherent modules. Add meaningful tests for behavior changes and run
the affected suite first. Build and test results do not establish live Windows,
relay, unattended service or release acceptance. Report these separately.

Use stable lists, tables and aligned grids; avoid masonry layouts. Document user
visible errors and preserve user data. Do not publish or deploy from an automated
code change without the repository owner's authorization.
