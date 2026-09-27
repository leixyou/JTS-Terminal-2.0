# JTS Relay protocol snapshot

- Publisher: independent private JTS Relay project.
- Package version: `1.0.0-alpha.1`; wire protocol: `1`.
- Artifact: `jts-relay-protocol-1.0.0-alpha.1.tar.gz`.
- Artifact SHA-256: `bf9766123f22024c0cc492928af9b3c8b4eff78e2bac12270b1b728a951bc445`.
- Distribution: local private development artifact, not a public registry release.

This immutable data-only snapshot contains the specification, JSON schema and
public interoperability fixture. It does not import relay implementation or need
a sibling checkout. Updates require a new package version and review; do not edit
this version in place. The public fixture is test data, never an admitted identity
or deployment key. Publication/signing of an external release is a later gate.

SHA-256 of unpacked files:

```text
33092bd83ce3668522a51b4b96847e4815e017cb654b463603be1059931c0d28  v1/PROTOCOL.md
c7fbdc161c2b993899fe0c02770325293abed913891d74c637cc995388a886a5  v1/schema.json
9a93360810ea55f5c8ecbc08ac7500f2a7d38cc0cbfb34cda4fc20b10a71bc35  v1/fixtures/auth-presence.json
```
