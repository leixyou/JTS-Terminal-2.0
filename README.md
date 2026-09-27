# JTS Terminal

JTS Terminal is a native remote administration workspace for macOS, with SSH,
SFTP, tunnels, native RDP and direct Windows Companion operations. This repository
also includes the iOS client and its tests.

This is a development preview of the public source. It is not a released App
Store build or a claim that every environment has passed unattended Windows,
relay and desktop acceptance. The independent relay route is implemented; a new
Windows installation still requires device enrollment and an actual end-to-end
acceptance run.

## Repositories

- [JTS Terminal](https://github.com/leixyou/JTS-Terminal-2.0): Apple clients and sandboxed helpers.
- [Windows Companion](https://github.com/leixyou/JTS-Windows-Companion): Windows installation, services, execution and UI Automation.
- [JTS Relay](https://github.com/leixyou/JTS-Relay): the independent relay service.

The client consumes a checksummed, data-only relay protocol snapshot in
`Protocols/JTSRelay`. It does not compile or load sibling relay source.

## Build

Use Xcode with SDK support for the project's macOS 26.4 target; the iOS target
requires iOS 17 or later. Install Python 3, CMake, Ninja and the command-line tools
used by the pinned FreeRDP build. See [the build guide](docs/BUILDING.md) for
signing, test requirements and the optional Windows installer resource.

```sh
# Select your own Apple Development team before compiling. No identity check is disabled.
python3 scripts/configure_signing.py --team-id YOUR_ACTUAL_TEAM_ID

# Generated XCFramework is intentionally excluded from Git.
scripts/build_freerdp.sh

# Builds, verifies signatures and launches a normal Debug app.
script/build_and_run.sh
```

The team argument must be your 10-character uppercase Apple team ID. The example
argument above is descriptive and is intentionally rejected until replaced.
App/helper bundle identities and the exact Apple anchor plus team requirements
remain enforced. Do not use an unsigned build as evidence that signed IPC works.

## Windows and relay operation

For a Windows 10 or Windows Server 2019 relay target, create its public enrollment
request with `jts_device_status action=identity` and `allowWindows10TLS12=true`.
The explicit setting is covered by the request checksum and retained when
importing the Windows enrollment. Omitting it keeps TLS 1.3; there is no automatic
fallback after a handshake failure. The matching Windows installer must support
this request field.

Companion commands, structured UI actions and files use direct protocols and
return structured results. Normal operations do not emulate keyboard input to
execute commands. Enabling AI desktop control for a device also delegates its
pairing workflow; no second pairing permission switch is added. Delegation is
bound to the device and can be revoked.

Relay traffic uses HTTPS/WSS. The current default skips the relay server's outer
PKI validation, allowing self-signed or expired outer certificates, while still
using TLS encryption. The inner end-to-end TLS connection retains mutual device
authentication and the paired device's SPKI pin. These are separate layers;
turning off outer PKI validation does not turn off inner identity verification.
No public relay endpoint or admitted device identity is bundled here.

See [architecture and trust boundaries](docs/ARCHITECTURE.md) and
[third-party components](docs/THIRD_PARTY.md).

## License

The project uses Apache-2.0. See `LICENSE` and `NOTICE` for the distribution terms;
third-party dependencies retain their own licenses and notices. Generated
installers, signing credentials and private operational evidence are not source
inputs in this repository.
