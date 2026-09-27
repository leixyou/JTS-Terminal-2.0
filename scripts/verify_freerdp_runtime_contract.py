#!/usr/bin/env python3
"""Verify source invariants required by JTS Terminal's slim FreeRDP runtime."""

from __future__ import annotations

import argparse
import plistlib
import re
import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


@dataclass(frozen=True)
class Token:
    value: str
    offset: int


@dataclass(frozen=True)
class CheckResult:
    description: str
    passed: bool
    detail: str = ""


SLIM_BUILD_DISABLED_DEFINITIONS = (
    "WITH_MACAUDIO",
    "CHANNEL_AINPUT",
    "CHANNEL_AUDIN",
    "CHANNEL_DRIVE",
    "CHANNEL_ECHO",
    "CHANNEL_ENCOMSP",
    "CHANNEL_GEOMETRY",
    "CHANNEL_LOCATION",
    "CHANNEL_PARALLEL",
    "CHANNEL_PRINTER",
    "CHANNEL_RAIL",
    "CHANNEL_RDPDR",
    "CHANNEL_RDPEAR",
    "CHANNEL_RDPECAM",
    "CHANNEL_RDPEI",
    "CHANNEL_RDPEMSC",
    "CHANNEL_RDPEWA",
    "CHANNEL_RDPSND",
    "CHANNEL_REMDESK",
    "CHANNEL_SERIAL",
    "CHANNEL_SMARTCARD",
    "CHANNEL_SSHAGENT",
    "CHANNEL_TELEMETRY",
    "CHANNEL_TSMF",
    "CHANNEL_URBDRC",
    "CHANNEL_VIDEO",
)

SLIM_BUILD_ENABLED_DEFINITIONS = (
    "CHANNEL_CLIPRDR",
)

RDPDR_RUNTIME_DISABLED_SETTINGS = (
    "FreeRDP_NetworkAutoDetect",
    "FreeRDP_SupportHeartbeatPdu",
    "FreeRDP_SupportMultitransport",
)

RELEASE_RUNTIME_DISABLED_SETTINGS = (
    "FreeRDP_DeviceRedirection",
    "FreeRDP_AudioPlayback",
    "FreeRDP_AudioCapture",
    "FreeRDP_RedirectDrives",
    "FreeRDP_RedirectPrinters",
    "FreeRDP_RedirectSmartCards",
    "FreeRDP_RedirectSerialPorts",
    "FreeRDP_RedirectParallelPorts",
    "FreeRDP_SupportSSHAgentChannel",
    "FreeRDP_UseMultimon",
    "FreeRDP_SpanMonitors",
    "FreeRDP_ForceMultimon",
)

EXPLICIT_EMPTY_CLIPBOARD_PATCH = (
    "scripts/patches/freerdp-explicit-empty-clipboard-list.patch"
)

UNIFIED_DIFF_HUNK_HEADER = re.compile(
    r"^@@ -(?:\d+)(?:,(\d+))? \+(?:\d+)(?:,(\d+))? @@"
)


def unified_diff_hunks_are_well_formed(source: str) -> bool:
    """Validate the old/new line counts of every unified-diff hunk."""

    expected_old: int | None = None
    expected_new: int | None = None
    actual_old = 0
    actual_new = 0
    saw_hunk = False

    def prior_hunk_matches() -> bool:
        return (
            expected_old is None
            or (actual_old == expected_old and actual_new == expected_new)
        )

    for line in source.splitlines():
        match = UNIFIED_DIFF_HUNK_HEADER.match(line)
        if match:
            if not prior_hunk_matches():
                return False
            expected_old = int(match.group(1) or "1")
            expected_new = int(match.group(2) or "1")
            actual_old = 0
            actual_new = 0
            saw_hunk = True
            continue
        if expected_old is None:
            continue
        if line.startswith("\\ No newline at end of file"):
            continue
        if not line or line[0] not in {" ", "+", "-"}:
            return False
        if line[0] in {" ", "-"}:
            actual_old += 1
        if line[0] in {" ", "+"}:
            actual_new += 1

    return saw_hunk and prior_hunk_matches()


def tokenize_c_family(source: str) -> list[Token]:
    """Tokenize enough C/Objective-C syntax to inspect calls and function bodies.

    Comments and string/character literals are deliberately skipped so a stale
    comment or diagnostic message cannot satisfy a runtime contract.
    """

    tokens: list[Token] = []
    index = 0
    length = len(source)
    while index < length:
        character = source[index]
        if character.isspace():
            index += 1
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index + 2)
            index = length if newline == -1 else newline + 1
            continue
        if source.startswith("/*", index):
            closing = source.find("*/", index + 2)
            if closing == -1:
                raise ValueError("unterminated block comment")
            index = closing + 2
            continue
        if character in {'"', "'"}:
            quote = character
            index += 1
            while index < length:
                if source[index] == "\\":
                    index += 2
                    continue
                if source[index] == quote:
                    index += 1
                    break
                index += 1
            else:
                raise ValueError("unterminated string or character literal")
            continue
        if character.isalpha() or character == "_":
            end = index + 1
            while end < length and (source[end].isalnum() or source[end] == "_"):
                end += 1
            tokens.append(Token(source[index:end], index))
            index = end
            continue
        if source.startswith("->", index):
            tokens.append(Token("->", index))
            index += 2
            continue
        tokens.append(Token(character, index))
        index += 1
    return tokens


def matching_delimiter(tokens: Sequence[Token], opening_index: int) -> int:
    pairs = {"(": ")", "{": "}", "[": "]"}
    opening = tokens[opening_index].value
    closing = pairs.get(opening)
    if closing is None:
        raise ValueError(f"token at {opening_index} is not an opening delimiter")

    depth = 0
    for index in range(opening_index, len(tokens)):
        value = tokens[index].value
        if value == opening:
            depth += 1
        elif value == closing:
            depth -= 1
            if depth == 0:
                return index
    raise ValueError(f"unmatched {opening!r} delimiter")


def c_function_body(tokens: Sequence[Token], function_name: str) -> list[Token]:
    for index, token in enumerate(tokens):
        if token.value != function_name or index + 1 >= len(tokens):
            continue
        if tokens[index + 1].value != "(":
            continue
        parameters_end = matching_delimiter(tokens, index + 1)
        body_start = parameters_end + 1
        if body_start >= len(tokens) or tokens[body_start].value != "{":
            continue
        body_end = matching_delimiter(tokens, body_start)
        return list(tokens[body_start : body_end + 1])
    raise ValueError(f"C function definition not found: {function_name}")


def objective_c_method_body(
    tokens: Sequence[Token],
    *,
    return_type: str,
    first_selector: str,
) -> list[Token]:
    signature = ["-", "(", return_type, ")", first_selector, ":"]
    values = [token.value for token in tokens]
    for index in range(0, len(values) - len(signature) + 1):
        if values[index : index + len(signature)] != signature:
            continue
        body_start = index + len(signature)
        while (
            body_start < len(tokens)
            and tokens[body_start].value not in {"{", ";"}
        ):
            body_start += 1
        if body_start == len(tokens):
            break
        if tokens[body_start].value == ";":
            continue
        body_end = matching_delimiter(tokens, body_start)
        return list(tokens[body_start : body_end + 1])
    raise ValueError(f"Objective-C method definition not found: {first_selector}:")


def call_arguments(tokens: Sequence[Token], function_name: str) -> list[list[list[Token]]]:
    calls: list[list[list[Token]]] = []
    for index, token in enumerate(tokens):
        if token.value != function_name or index + 1 >= len(tokens):
            continue
        if tokens[index + 1].value != "(":
            continue
        closing = matching_delimiter(tokens, index + 1)
        arguments: list[list[Token]] = []
        current: list[Token] = []
        depth = 0
        for argument_token in tokens[index + 2 : closing]:
            if argument_token.value in {"(", "[", "{"}:
                depth += 1
            elif argument_token.value in {")", "]", "}"}:
                depth -= 1
            if argument_token.value == "," and depth == 0:
                arguments.append(current)
                current = []
            else:
                current.append(argument_token)
        if current or arguments:
            arguments.append(current)
        calls.append(arguments)
    return calls


def token_values(tokens: Iterable[Token]) -> list[str]:
    return [token.value for token in tokens]


def contains_sequence(tokens: Sequence[Token], expected: Sequence[str]) -> bool:
    values = token_values(tokens)
    width = len(expected)
    return any(
        values[index : index + width] == list(expected)
        for index in range(len(values) - width + 1)
    )


def shell_cmake_definitions(source: str) -> dict[str, list[str]]:
    lexer = shlex.shlex(source, posix=True)
    lexer.whitespace_split = True
    lexer.commenters = "#"
    definitions: dict[str, list[str]] = {}
    for token in lexer:
        if not token.startswith("-D") or "=" not in token:
            continue
        name, value = token[2:].split("=", 1)
        definitions.setdefault(name, []).append(value)
    return definitions


def shell_words(source: str) -> list[str]:
    return shlex.split(
        source.replace("\\\n", " "),
        comments=True,
        posix=True,
    )


def contains_word_sequence(
    words: Sequence[str],
    expected: Sequence[str],
) -> bool:
    width = len(expected)
    return any(
        list(words[index : index + width]) == list(expected)
        for index in range(len(words) - width + 1)
    )


def unified_diff_added_source(source: str) -> str:
    return "\n".join(
        line[1:]
        for line in source.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


def audit_runtime_contract(root: Path) -> list[CheckResult]:
    results: list[CheckResult] = []
    info_plist_path = root / "JTFreeRDPService" / "Info.plist"
    build_script_path = root / "scripts" / "build_freerdp.sh"
    engine_path = root / "JTFreeRDPService" / "JTFreeRDPEngine.m"
    clipboard_bridge_path = (
        root / "JTFreeRDPService" / "JTFreeRDPTextClipboardBridge.m"
    )
    explicit_empty_patch_path = root / EXPLICIT_EMPTY_CLIPBOARD_PATCH

    try:
        with info_plist_path.open("rb") as handle:
            info_plist = plistlib.load(handle)
        purpose = info_plist.get("NSLocalNetworkUsageDescription")
        has_purpose = isinstance(purpose, str) and bool(purpose.strip())
        results.append(
            CheckResult(
                "JTFreeRDPService Info.plist has a non-empty NSLocalNetworkUsageDescription",
                has_purpose,
                "key is missing or empty" if not has_purpose else "",
            )
        )
    except (OSError, plistlib.InvalidFileException) as error:
        results.append(
            CheckResult(
                "JTFreeRDPService Info.plist has a non-empty NSLocalNetworkUsageDescription",
                False,
                str(error),
            )
        )

    rdpdr_is_off = False
    try:
        definitions = shell_cmake_definitions(build_script_path.read_text(encoding="utf-8"))
        for definition in SLIM_BUILD_DISABLED_DEFINITIONS:
            values = definitions.get(definition, [])
            is_off = values == ["OFF"]
            if definition == "CHANNEL_RDPDR":
                rdpdr_is_off = is_off
            results.append(
                CheckResult(
                    f"FreeRDP slim-build recipe sets {definition} exactly once to OFF",
                    is_off,
                    f"resolved definitions: {values or ['missing']}",
                )
            )
        for definition in SLIM_BUILD_ENABLED_DEFINITIONS:
            values = definitions.get(definition, [])
            is_on = values == ["ON"]
            results.append(
                CheckResult(
                    f"FreeRDP slim-build recipe sets {definition} exactly once to ON",
                    is_on,
                    f"resolved definitions: {values or ['missing']}",
                )
            )
        internal_md4_values = definitions.get("WITH_INTERNAL_MD4", [])
        internal_md4_is_on = internal_md4_values == ["ON"]
        results.append(
            CheckResult(
                "FreeRDP slim-build recipe sets WITH_INTERNAL_MD4 exactly once to ON",
                internal_md4_is_on,
                f"resolved definitions: {internal_md4_values or ['missing']}",
            )
        )
        internal_rc4_values = definitions.get("WITH_INTERNAL_RC4", [])
        internal_rc4_is_on = internal_rc4_values == ["ON"]
        results.append(
            CheckResult(
                "FreeRDP slim-build recipe sets WITH_INTERNAL_RC4 exactly once to ON",
                internal_rc4_is_on,
                f"resolved definitions: {internal_rc4_values or ['missing']}",
            )
        )
    except (OSError, ValueError) as error:
        for definition in SLIM_BUILD_DISABLED_DEFINITIONS:
            results.append(
                CheckResult(
                    f"FreeRDP slim-build recipe sets {definition} exactly once to OFF",
                    False,
                    str(error),
                )
            )
        for definition in SLIM_BUILD_ENABLED_DEFINITIONS:
            results.append(
                CheckResult(
                    f"FreeRDP slim-build recipe sets {definition} exactly once to ON",
                    False,
                    str(error),
                )
            )
        results.append(
            CheckResult(
                "FreeRDP slim-build recipe sets WITH_INTERNAL_MD4 exactly once to ON",
                False,
                str(error),
            )
        )
        results.append(
            CheckResult(
                "FreeRDP slim-build recipe sets WITH_INTERNAL_RC4 exactly once to ON",
                False,
                str(error),
            )
        )

    try:
        build_words = shell_words(
            build_script_path.read_text(encoding="utf-8")
        )
        patch_application = (
            "patch",
            "-d",
            "$source_dir",
            "-p1",
            "--forward",
            "--batch",
            "<",
            f"$PROJECT_DIR/{EXPLICIT_EMPTY_CLIPBOARD_PATCH}",
        )
        applies_explicit_empty_patch = contains_word_sequence(
            build_words,
            patch_application,
        )
        results.append(
            CheckResult(
                "FreeRDP build recipe applies the explicit-empty CLIPRDR patch",
                applies_explicit_empty_patch,
                (
                    "expected the extracted source tree to receive "
                    f"{EXPLICIT_EMPTY_CLIPBOARD_PATCH}"
                ),
            )
        )
    except (OSError, ValueError) as error:
        results.append(
            CheckResult(
                "FreeRDP build recipe applies the explicit-empty CLIPRDR patch",
                False,
                str(error),
            )
        )

    try:
        patch_source = explicit_empty_patch_path.read_text(encoding="utf-8")
        added_tokens = tokenize_c_family(
            unified_diff_added_source(patch_source)
        )
        targets_cliprdr_client = (
            "diff --git a/channels/cliprdr/client/cliprdr_main.c "
            "b/channels/cliprdr/client/cliprdr_main.c"
        ) in patch_source
        defines_explicit_empty = contains_sequence(
            added_tokens,
            [
                "const",
                "BOOL",
                "explicitEmptyList",
                "=",
                "formatList",
                "->",
                "numFormats",
                "=",
                "=",
                "0",
                ";",
            ],
        )
        exempts_explicit_empty = contains_sequence(
            added_tokens,
            ["&", "&", "!", "explicitEmptyList"],
        )
        preserves_explicit_empty = (
            targets_cliprdr_client
            and defines_explicit_empty
            and exempts_explicit_empty
        )
        results.append(
            CheckResult(
                "Explicit-empty CLIPRDR patch has well-formed unified-diff hunks",
                unified_diff_hunks_are_well_formed(patch_source),
                str(explicit_empty_patch_path),
            )
        )
        results.append(
            CheckResult(
                "Explicit-empty CLIPRDR patch preserves caller-supplied empty format lists",
                preserves_explicit_empty,
                (
                    "patch must distinguish an explicit zero-format input "
                    "from a non-empty list filtered down to zero"
                ),
            )
        )
    except (OSError, ValueError) as error:
        results.append(
            CheckResult(
                "Explicit-empty CLIPRDR patch preserves caller-supplied empty format lists",
                False,
                str(error),
            )
        )

    try:
        engine_tokens = tokenize_c_family(engine_path.read_text(encoding="utf-8"))
        pre_connect = c_function_body(engine_tokens, "JTPreConnect")
        load_channels = c_function_body(engine_tokens, "JTLoadChannels")
        client_new = c_function_body(engine_tokens, "JTClientNew")
        configure_settings = objective_c_method_body(
            engine_tokens,
            return_type="BOOL",
            first_selector="configureSettings",
        )

        bool_calls = call_arguments(configure_settings, "freerdp_settings_set_bool")
        for setting in RDPDR_RUNTIME_DISABLED_SETTINGS:
            matching_calls = [
                arguments
                for arguments in bool_calls
                if len(arguments) >= 2 and token_values(arguments[1]) == [setting]
            ]
            explicitly_disabled = (
                rdpdr_is_off
                and len(matching_calls) == 1
                and len(matching_calls[0]) == 3
                and token_values(matching_calls[0][0]) == ["settings"]
                and token_values(matching_calls[0][2]) == ["FALSE"]
            )
            detail = ""
            if not rdpdr_is_off:
                detail = (
                    "cannot validate the rdpdr-off runtime contract because "
                    "CHANNEL_RDPDR is not OFF"
                )
            elif len(matching_calls) != 1:
                detail = f"expected one direct settings call, found {len(matching_calls)}"
            elif not explicitly_disabled:
                detail = "expected freerdp_settings_set_bool(settings, setting, FALSE)"
            results.append(
                CheckResult(
                    f"RDP engine explicitly disables {setting} for the rdpdr-off build",
                    explicitly_disabled,
                    detail,
                )
            )

        for setting in RELEASE_RUNTIME_DISABLED_SETTINGS:
            matching_calls = [
                arguments
                for arguments in bool_calls
                if len(arguments) >= 2 and token_values(arguments[1]) == [setting]
            ]
            explicitly_disabled = (
                len(matching_calls) == 1
                and len(matching_calls[0]) == 3
                and token_values(matching_calls[0][0]) == ["settings"]
                and token_values(matching_calls[0][2]) == ["FALSE"]
            )
            detail = ""
            if len(matching_calls) != 1:
                detail = f"expected one direct settings call, found {len(matching_calls)}"
            elif not explicitly_disabled:
                detail = "expected freerdp_settings_set_bool(settings, setting, FALSE)"
            results.append(
                CheckResult(
                    f"RDP engine explicitly disables {setting} for the 2.0 release",
                    explicitly_disabled,
                    detail,
                )
            )

        clipboard_calls = [
            arguments
            for arguments in bool_calls
            if len(arguments) >= 2
            and token_values(arguments[1]) == ["FreeRDP_RedirectClipboard"]
        ]
        clipboard_is_profile_bound = (
            len(clipboard_calls) == 1
            and len(clipboard_calls[0]) == 3
            and token_values(clipboard_calls[0][0]) == ["settings"]
            and token_values(clipboard_calls[0][2]) == ["clipboardEnabled"]
        )
        results.append(
            CheckResult(
                "RDP engine binds FreeRDP_RedirectClipboard to the per-profile text clipboard preference",
                clipboard_is_profile_bound,
                (
                    f"expected one direct clipboardEnabled settings call, "
                    f"found {len(clipboard_calls)}"
                ),
            )
        )

        pre_connect_loads = call_arguments(pre_connect, "freerdp_client_load_addins")
        all_loads = call_arguments(engine_tokens, "freerdp_client_load_addins")
        load_channels_loads = call_arguments(load_channels, "freerdp_client_load_addins")
        results.append(
            CheckResult(
                "JTPreConnect does not directly load FreeRDP channel add-ins",
                not pre_connect_loads,
                f"found {len(pre_connect_loads)} direct load call(s)",
            )
        )
        unique_loader = len(all_loads) == 1 and len(load_channels_loads) == 1
        results.append(
            CheckResult(
                "JTLoadChannels contains the engine's only freerdp_client_load_addins call",
                unique_loader,
                f"engine calls={len(all_loads)}, JTLoadChannels calls={len(load_channels_loads)}",
            )
        )
        callback_is_wired = contains_sequence(
            client_new,
            ["instance", "->", "LoadChannels", "=", "JTLoadChannels", ";"],
        )
        results.append(
            CheckResult(
                "JTClientNew wires FreeRDP LoadChannels to JTLoadChannels",
                callback_is_wired,
                "instance->LoadChannels = JTLoadChannels assignment is missing",
            )
        )
    except (OSError, ValueError) as error:
        results.append(
            CheckResult(
                "JTFreeRDPEngine source is structurally parseable for runtime contract checks",
                False,
                str(error),
            )
        )

    try:
        clipboard_bridge_tokens = tokenize_c_family(
            clipboard_bridge_path.read_text(encoding="utf-8")
        )
        send_capabilities = objective_c_method_body(
            clipboard_bridge_tokens,
            return_type="UINT",
            first_selector="sendCapabilities",
        )
        capability_values = token_values(send_capabilities)
        required_file_capabilities = (
            "CB_STREAM_FILECLIP_ENABLED",
            "CB_FILECLIP_NO_FILE_PATHS",
        )
        missing_file_capabilities = [
            capability
            for capability in required_file_capabilities
            if capability_values.count(capability) != 1
        ]
        results.append(
            CheckResult(
                "CLIPRDR negotiates one path-free streamed file offer for Companion bootstrap",
                not missing_file_capabilities,
                (
                    "required capability must appear exactly once: "
                    + ", ".join(missing_file_capabilities)
                    if missing_file_capabilities
                    else ""
                ),
            )
        )

        excluded_file_capabilities = (
            "CB_CAN_LOCK_CLIPDATA",
            "CB_HUGE_FILE_SUPPORT_ENABLED",
        )
        present_excluded_capabilities = [
            capability
            for capability in excluded_file_capabilities
            if capability in capability_values
        ]
        results.append(
            CheckResult(
                "CLIPRDR keeps clipboard locking and huge-file transfer disabled",
                not present_excluded_capabilities,
                (
                    "unexpected capability: "
                    + ", ".join(present_excluded_capabilities)
                    if present_excluded_capabilities
                    else ""
                ),
            )
        )
    except (OSError, ValueError) as error:
        results.append(
            CheckResult(
                "JTFreeRDPTextClipboardBridge source is structurally parseable for runtime contract checks",
                False,
                str(error),
            )
        )

    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="repository root (defaults to the parent of scripts/)",
    )
    arguments = parser.parse_args()

    results = audit_runtime_contract(arguments.root.resolve())
    for result in results:
        prefix = "PASS" if result.passed else "FAIL"
        suffix = f" ({result.detail})" if result.detail and not result.passed else ""
        print(f"{prefix}: {result.description}{suffix}")

    failures = sum(not result.passed for result in results)
    print(f"\nFreeRDP runtime contract completed: {len(results)} check(s), {failures} failure(s).")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
