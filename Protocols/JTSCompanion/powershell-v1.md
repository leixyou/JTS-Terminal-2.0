# `powershell.v1` task payload — development version 1

This is endpoint-owned business data inside `job.submit.payloadBase64`; it does
not change the immutable relay protocol. Pairing, a current exact-device grant
allowing `powershell.v1`, and separate MCP client authorization are prerequisites.

The decoded payload is UTF-8 JSON, at most 65,536 bytes, with exactly:

```json
{"version":1,"script":"Write-Output 'hello'","workingDirectory":"C:\\Work"}
```

Unknown or duplicate fields, wrong versions/types and malformed JSON are rejected.
`script` is nonblank, contains no NUL and is at most 49,152 UTF-8 bytes. It is code
executed with the provisioned standard account's real permissions, not a recipe,
an administrator request or a sandboxed file operation.

`workingDirectory` is an existing local absolute drive path, 3–240 characters.
UNC/device paths, relative/dot segments, repeated separators, alternate streams,
invalid Windows path characters and trailing dot/space segments are rejected.
Windows performs the actual directory/access check at launch. Reparse targets
and other accessible paths are not confined by this check; **working directory is
not a script sandbox**. File-channel capabilities will have separate root/handle
authorization and do not inherit permission from this field.

The runtime binding includes a SHA-256 digest of these exact payload bytes. An
idempotent retry must reuse the same complete binding/payload, not serialize an
equivalent JSON object differently. The executor checks the kind and digest again.
The request cannot specify a SID, executable path, command-line flags, environment
or elevation. All such launch policy comes from trusted local Worker setup.

Output is the runtime's bounded merged stdout/stderr byte stream (default 128 KiB
per task), fetched in authorized pages. It may include sensitive task output and
must never be copied to relay/service diagnostic logs. PowerShell exit zero yields
`OK`; nonzero yields `POWERSHELL_EXIT_NONZERO`. Cancellation is final only after
ordinary job-contained processes are confirmed stopped. Unconfirmed stop yields
`interrupted` / `EXECUTOR_STATE_UNKNOWN`, closes admission and requires explicit
recovery; no automatic rerun. External script effects cannot be rolled back.

See the [execution module boundary](https://github.com/leixyou/JTS-Windows-Companion/blob/main/src/JTS.WindowsCompanion.Execution/README.md).
