# Building the public source

## Inputs and prerequisites

The macOS project currently targets macOS 26.4. Helpers and the local transport
package declare macOS 13, which does not lower the app's minimum OS. The iOS
source target declares iOS 17. Use a suitable current Xcode and select its full
command-line developer directory.

The native FreeRDP build requires `cmake`, `ninja`, `xcodebuild`, `curl`, `shasum`,
`tar`, `make`, `perl`, `libtool`, `ranlib`, `nm`, `rg` and `patch`. Python 3 runs
repository checks and signing preparation. `script/build_and_run.sh --verify`
also requires Python's Quartz module for its optional window inspection.

Swift dependencies are pinned in
`JTSTerminal.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The local `Packages/JTSCompanionTransport` package depends on this repository's
pinned OpenSSL/FreeRDP archive and must stay at its current relative path.

## Configure signing, then build

```sh
python3 scripts/configure_signing.py --team-id YOUR_ACTUAL_TEAM_ID
scripts/build_freerdp.sh
scripts/verify_relay_protocol_snapshot.sh
script/build_and_run.sh
```

Replace the example team argument with your 10-character uppercase Apple team
ID. The configurator updates the project, the app/helper compile-time pins,
entitlements and signing validators together. It records the previous team in
an ignored local `.jts-signing.json`, making explicit reconfiguration possible.
This is a source configuration step, not a runtime trust override. Keep your
Apple Development identity in your own Keychain. The project does not include a
certificate, private key or provisioning profile.

The exported project retains its bundle identifiers because they are also part
of the IPC contract. A fork changing bundle identifiers must update and test the
corresponding app/helper requirements and scripts as a separate change. Never
replace those requirements with a permissive expression. Debug builds are the
initial local developer path; Release distribution signing and provisioning
must be configured for the distributor's own account.

`Vendor/FreeRDP/JTFreeRDP.xcframework` is generated and ignored. The build script
fetches SHA-256-pinned FreeRDP 3.31.1 and OpenSSL 3.6.4 archives, builds arm64 and
x86_64 static slices, applies the checked-in clipboard patch and emits the
XCFramework, licenses and SBOM. It does not use Homebrew's `xfreerdp` at runtime.

The shared `JTSTerminaliOS` scheme builds the iOS client. Choose your own signing
team and provisioning configuration for a physical device; use an available
simulator destination for simulator work. macOS RDP helpers are not an iOS
runtime dependency.

## Windows installer resource

Debug app builds can omit the Windows installer. Release app builds require an
explicit installer input; they do not build Windows source. Build or obtain a
verified installer from the separate Windows Companion project, then supply:

```sh
export JTS_WINDOWS_COMPANION_INSTALLER_PATH=/absolute/path/JTS-Windows-Companion-Setup.exe
export JTS_WINDOWS_COMPANION_INSTALLER_SHA256_PATH=/absolute/path/JTS-Windows-Companion-Setup.sha256
```

`scripts/embed_windows_companion_installer.sh` validates the exact SHA-256
manifest and rejects development/lab artifacts before embedding. No installer
binary or release-signing key is stored here. The project's Release setting
`JTS_REQUIRE_WINDOWS_COMPANION_INSTALLER=1` remains enabled.

## Verification scopes

```sh
python3 -m unittest discover -s scripts/tests -p 'test_configure_signing.py' -v
scripts/run_macos_tests.sh --only-testing JTSTerminalRDP2Tests/CompanionDeviceMCPTests
swift test --package-path Packages/JTSCompanionTransport
```

Run package tests after generating the vendor archive. The macOS test runner
uses its documented x86_64/Rosetta path by default on Apple Silicon; pass
`--destination 'platform=macOS,arch=arm64'` when intentionally testing native
arm64. Keep tests separate from the daily build and do not run retention while
tests are active. Unsigned compilation is diagnostic only and does not validate
sandboxed, signed app/helper communication.

Cross-language interop tests are opt-in. Their .NET fixture source lives with
the Windows component, not in this Apple repository. Set absolute paths in
`JTS_INTEROP_DOTNET` and `JTS_INTEROP_HOST_DLL` to a compatible, independently
built fixture to run them. Without those inputs the tests explicitly skip;
a skipped interop test is not evidence of successful Windows interoperability.
Public-relay tests additionally require an explicitly configured test node and
admitted test identities; do not point them at an unrelated server.

There is no bundled GitHub Actions workflow or claim of a validated hosted CI
runner. A future workflow should pin its Xcode environment, build the generated
vendor input, run ordinary tests, and keep signed runtime/live deployment gates
separate from an unsigned compilation job. It must not use maintainer private
profiles, production node credentials or local operational records as inputs.
