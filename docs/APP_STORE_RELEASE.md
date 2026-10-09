# App Store release checklist

This list covers what the source tree cannot settle by itself. Work through it
for each Mac App Store and iOS submission. A passing build or test run does not
replace any of these steps, and none of them proves live Windows, relay or
unattended-service acceptance.

## Signing and packaging

- Release builds of `JTSTerminalRDP2` use manual signing with
  `3rd Party Mac Developer Application` and an empty provisioning profile
  specifier. Create a Mac App Store provisioning profile for
  `com.lljts.JTSTerminal` and select it in the archive/export options (or switch
  the app target to automatic signing for distribution). The helpers keep their
  own identities; do not loosen the app/helper requirement checks.
- Release builds require the Windows Companion installer and its SHA-256
  manifest (`JTS_REQUIRE_WINDOWS_COMPANION_INSTALLER=1`). Archive fails without
  them. Explain in the review notes that the bundled `.exe` is copied to the
  user's own Windows PC over RDP and is never executed on the Mac.
- Archive on a clean machine, upload to TestFlight, and install the TestFlight
  build. Debug builds do not exercise the distribution signature.

## Information you must decide

- Export compliance: the apps use TLS, SSH, OpenSSL (FreeRDP) and authenticated
  end-to-end encryption for the relay. Answer the App Store Connect encryption
  questions, then add `ITSAppUsesNonExemptEncryption` to both Info.plists with
  the matching value so uploads stop asking.
- App Transport Security: the app and `JTCompanionTransportService` set
  `NSAllowsArbitraryLoads` because relay hosts are user supplied and may use
  self-signed certificates. Give that reason in App Store Connect.
- Entitlements: the Mac app requests Downloads, Pictures, Music and Movies
  read/write so MCP transfers can use those folders without a prompt. State this
  in the review notes, or remove the entitlements and rely on folders the user
  authorizes in **MCP → Local Transfer Folders…**.
- Privacy: MCP sends command output, file content and desktop images to the AI
  client the user registers. The App Privacy answers, the privacy policy at
  `https://www.lljts.com/privacy` and the in-app MCP consent text must say so.
  If you operate a relay station for users, the policy must also cover it.
- China mainland storefront: an ICP filing number is required in App Store
  Connect.

## App Review access

Reviewers cannot reach a private LAN. Provide in the review notes:

- An SSH host reachable from the internet, with a test account.
- A Windows host for RDP (and, if possible, a relay station with a paired
  Windows Companion), or a screen recording of the RDP, Companion and relay
  flows.
- A download link for JTS Mac Companion, or a recording of the Mac Desktop
  flow.
- A recording of an MCP client (for example Claude Desktop) operating a server
  through JTS Terminal.

## Upgrade and runtime checks

- Install the previous App Store version, add servers, tunnels and passwords,
  then install the new build over it. Confirm every server is still listed. If
  the SwiftData store cannot be opened, the app moves it aside and starts empty,
  which users experience as data loss.
- iOS: the first connection to each saved server now asks the user to verify
  the SSH host key fingerprint. Saved passwords and keys move to per-server
  Keychain items on first launch; confirm an upgraded device still connects.
- macOS: choose a private key with **Browse** in Server Properties, quit and
  relaunch, then connect, open Files and run an MCP command with that profile.
  Keys typed as a path without Browse cannot be read inside the App Sandbox.
- Check both languages (toolbar language switch) on the Files, Tunnels, Mac
  Desktop and Import/Export screens.
