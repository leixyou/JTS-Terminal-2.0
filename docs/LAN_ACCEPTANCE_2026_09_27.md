# Direct LAN acceptance — 2026-09-27

One terminal lets AI operate remote machines like local ones. This acceptance exercises the direct Mac MCP → RDP/Companion DVC route on a real Windows 11 x64 desktop with Windows PowerShell 5.1. It does not use remote keyboard typing for commands, files, or UI Automation.

## Verified on the real desktop

- A real RDP framebuffer rendered correctly.
- PowerShell returned the actual machine, current user, OS and process session.
- The file API wrote and read 104 bytes containing Chinese text and an emoji. The original bytes, remote readback, size and SHA-256 matched.
- UI Automation found a dedicated test process and its unique controls. `semanticSetValue` wrote Chinese text and an emoji; a separate native UIA read observed the exact text. `semanticInvoke` saved it; the file API independently returned identical UTF-8 bytes. A semantic button action closed the test window.
- After disconnect/reconnect, the authorized Companion channel recovered and both a new command and exact file readback succeeded.

## Defects fixed in the Mac client

Opening an existing credential vault used to write its unchanged schema version, unnecessarily competing for the SQLite writer lock. Existing valid schemas now use a read-only validation path. First-time WAL conversion and schema creation are bounded and concurrency-safe; unsupported or partial schemas are rejected. The focused vault suites passed 22 tests, including real independent SQLite connections.

Semantic UIA actions used to require an exact framebuffer revision even after validating a fresh UIA observation. A blinking caret could invalidate an action before it executed. An authorized, unexpired observation now binds a semantic action to its caller, target, session and control/connection generation while permitting ordinary repaints. Raw coordinate/keyboard actions and semantic requests without an observation retain exact frame validation. The UIA regression suite and the real desktop scenario passed.

The ordinary daily Debug application and both helper signatures were verified before the live rerun. The public Mac fix commit is `49b1fc2`.

## Installed Windows repair

Both PowerShell launch paths were repaired at Windows source commit `895f06fea0e3721c79c3e4c0ea5f7f259bf97853`. They use UTF-8 text, avoid encoded-command CLIXML error serialization, and explicitly load the Windows-supplied Utility and Management modules before executing user scripts. Script contents remain on stdin, and existing permissions, process containment and cancellation remain enforced.

[Windows CI 36321013859](https://github.com/leixyou/JTS-Windows-Companion/actions/runs/36321013859) passed completely. The CU/elevation scope passed 14 tests, including four native Windows Unicode/cmdlet/error/quota methods. Two independent-executor cases and four identity/TLS cases passed in a real temporary standard account, with zero skips.

The rebuilt current-user installer was transferred over pinned TLS and installed on the LAN host. Setup returned exit 0; the installed Setup and Agent hashes matched the rebuilt payloads. The installed binary then passed Unicode input/stdout/stderr, explicit exit 7, nonterminating text errors, basic management cmdlets, exact file write/read, and the complete semantic UIA scenario. After closing and opening a new RDP session, Unicode command execution and exact file readback passed again. The seven test-owned files and their unique directory were removed; the desktop was left connected with Companion ready.

Installed Setup SHA-256: `11eafa9b86361e6fea84821733165d5e69861bbd475c6cf318b0797b70da5e5c`.

Installed Agent SHA-256: `cb6057777198578fa0479621c561e3e099e879ad9768d08ee13f08f48ff2fdf3`.

## Observed limits

The first close request after the update returned `XPC_NOT_CONNECTED`. Source review then found an unnecessary clipboard-isolation precondition before local teardown. Mac commit `9955b8b` removes that precondition for authorized close only, preserving grant checks and the barrier before remote input. All 16 clipboard regression tests passed, including injected isolation failure and denied unauthorized close. The rebuilt daily application then closed successfully on its first attempt, opened a new session, and passed Unicode commands before and after the close. The original failure and successful follow-up are both retained in the acceptance history.

This direct-LAN run does not close independent relay end-to-end transport, Windows 10/Server 2019 real-host acceptance, unattended SCM lifecycle, production signing, or full-app release gates. Private host names, account names, screenshots and per-call evidence remain outside the public repository.
