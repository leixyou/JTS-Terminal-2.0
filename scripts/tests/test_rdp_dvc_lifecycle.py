from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from typing import Union


ROOT = Path(__file__).resolve().parents[2]
CONTRACT_PATH = ROOT / "scripts" / "verify_freerdp_runtime_contract.py"
SPEC = importlib.util.spec_from_file_location("verify_freerdp_runtime_contract", CONTRACT_PATH)
assert SPEC is not None and SPEC.loader is not None
CONTRACT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CONTRACT
SPEC.loader.exec_module(CONTRACT)


def method_body(
    tokens: list[object],
    *,
    return_type: Union[str, list[str]],
    selector: str,
    has_parameter: bool,
) -> list[object]:
    return_tokens = [return_type] if isinstance(return_type, str) else return_type
    signature = ["-", "(", *return_tokens, ")", selector]
    if has_parameter:
        signature.append(":")
    values = CONTRACT.token_values(tokens)
    for index in range(len(values) - len(signature) + 1):
        if values[index : index + len(signature)] != signature:
            continue
        body_start = index + len(signature)
        while body_start < len(tokens):
            token = tokens[body_start].value
            if token == ";":
                break
            if token == "{":
                body_end = CONTRACT.matching_delimiter(tokens, body_start)
                return list(tokens[body_start : body_end + 1])
            body_start += 1
    raise AssertionError(f"Objective-C method definition not found: {selector}")


def sequence_index(tokens: list[object], expected: list[str]) -> int:
    values = CONTRACT.token_values(tokens)
    for index in range(len(values) - len(expected) + 1):
        if values[index : index + len(expected)] == expected:
            return index
    raise AssertionError(f"token sequence not found: {' '.join(expected)}")


class RDPDVCLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        source = (ROOT / "JTFreeRDPService" / "JTFreeRDPEngine.m").read_text(
            encoding="utf-8"
        )
        cls.source = source
        cls.tokens = CONTRACT.tokenize_c_family(source)

    def test_channel_lifecycle_has_a_dedicated_recursive_lock(self) -> None:
        sequence_index(
            self.tokens,
            ["NSRecursiveLock", "*", "dvcChannelLock", ";"],
        )
        init = method_body(
            self.tokens,
            return_type="instancetype",
            selector="init",
            has_parameter=False,
        )
        sequence_index(
            init,
            [
                "_dvcChannelLock",
                "=",
                "[",
                "[",
                "NSRecursiveLock",
                "alloc",
                "]",
                "init",
                "]",
                ";",
            ],
        )

    def test_write_holds_lifecycle_lock_and_checks_the_return_code(self) -> None:
        body = method_body(
            self.tokens,
            return_type=["NSError", "*", "_Nullable"],
            selector="writeDVCMessage",
            has_parameter=True,
        )
        lock = sequence_index(body, ["self", ".", "dvcChannelLock", "lock"])
        channel_read = sequence_index(body, ["engineState", "->", "dvcChannel"])
        generation_read = sequence_index(body, ["engineState", "->", "dvcGeneration"])
        generation_validation = sequence_index(
            body,
            ["JTFreeRDPDVCGenerationValidationError", "("],
        )
        write = sequence_index(body, ["channel", "->", "Write", "("])
        result_check = sequence_index(body, ["writeResult", "!", "=", "CHANNEL_RC_OK"])
        channel_identity_check = sequence_index(
            body,
            ["engineState", "->", "dvcChannel", "=", "=", "channel"],
        )
        generation_identity_check = sequence_index(
            body,
            ["engineState", "->", "dvcGeneration", "=", "=", "expectedGeneration"],
        )
        channel_clear = sequence_index(body, ["engineState", "->", "dvcChannel", "=", "NULL"])
        generation_advance = sequence_index(
            body,
            [
                "engineState",
                "->",
                "dvcGeneration",
                "=",
                "JTNextDVCGeneration",
                "(",
            ],
        )
        unlock = sequence_index(body, ["self", ".", "dvcChannelLock", "unlock"])
        notification = sequence_index(body, ["self", "notifyState", ":"])

        self.assertLess(lock, channel_read)
        self.assertLess(channel_read, generation_read)
        self.assertLess(generation_read, generation_validation)
        self.assertLess(generation_validation, write)
        self.assertLess(write, result_check)
        self.assertLess(result_check, channel_identity_check)
        self.assertLess(channel_identity_check, generation_identity_check)
        self.assertLess(generation_identity_check, channel_clear)
        self.assertLess(channel_clear, generation_advance)
        self.assertLess(generation_advance, unlock)
        self.assertLess(unlock, notification)
        self.assertIn('@"COMPANION_REQUIRED"', self.source)
        self.assertIn('@"COMPANION_WRITE_FAILED"', self.source)
        sequence_index(body, ["return", "failure", ";"])

        drain = method_body(
            self.tokens,
            return_type="void",
            selector="drainCommands",
            has_parameter=True,
        )
        attempt_validation = sequence_index(
            drain,
            ["JTFreeRDPConnectionAttemptValidationError", "("],
        )
        drain_lock = sequence_index(drain, ["self", ".", "dvcChannelLock", "lock"])
        drain_generation_read = sequence_index(
            drain,
            ["engineState", "->", "dvcGeneration"],
        )
        drain_unlock = sequence_index(
            drain,
            ["self", ".", "dvcChannelLock", "unlock"],
        )
        drain_generation_validation = sequence_index(
            drain,
            ["JTFreeRDPDVCGenerationValidationError", "("],
        )
        generation_bound_write = sequence_index(
            drain,
            [
                "return",
                "[",
                "self",
                "writeDVCMessage",
                ":",
                "message",
                "expectedGeneration",
                ":",
                "[",
                "command",
                "[",
                "@",
                "]",
                "unsignedLongLongValue",
                "]",
                "]",
                ";",
            ],
        )
        self.assertLess(attempt_validation, drain_lock)
        self.assertLess(drain_lock, drain_generation_read)
        self.assertLess(drain_generation_read, drain_unlock)
        self.assertLess(drain_unlock, drain_generation_validation)
        self.assertLess(drain_generation_validation, generation_bound_write)

    def test_on_close_clears_and_retires_callback_under_the_same_lock(self) -> None:
        callback_body = CONTRACT.c_function_body(self.tokens, "JTCompanionDVCOnClose")
        sequence_index(
            callback_body,
            ["engine", "handleDVCCloseAndRetireCallback", ":", "callback"],
        )

        close = method_body(
            self.tokens,
            return_type="void",
            selector="handleDVCCloseAndRetireCallback",
            has_parameter=True,
        )
        lock = sequence_index(close, ["self", ".", "dvcChannelLock", "lock"])
        callback_track = sequence_index(
            close,
            ["self", ".", "dvcCallbackReleasePool", "trackPointer", ":", "callback"],
        )
        channel_read = sequence_index(close, ["callback", "->", "base", ".", "channel"])
        generation_read = sequence_index(close, ["callback", "->", "generation"])
        channel_identity_check = sequence_index(
            close,
            ["engineState", "->", "dvcChannel", "=", "=", "channel"],
        )
        nonzero_generation_check = sequence_index(
            close,
            ["callbackGeneration", "!", "=", "0"],
        )
        generation_identity_check = sequence_index(
            close,
            ["engineState", "->", "dvcGeneration", "=", "=", "callbackGeneration"],
        )
        channel_clear = sequence_index(
            close,
            ["engineState", "->", "dvcChannel", "=", "NULL"],
        )
        generation_advance = sequence_index(
            close,
            [
                "engineState",
                "->",
                "dvcGeneration",
                "=",
                "JTNextDVCGeneration",
                "(",
            ],
        )
        unlock = sequence_index(close, ["self", ".", "dvcChannelLock", "unlock"])
        notification = sequence_index(close, ["self", "notifyState", ":"])

        self.assertNotIn("free", CONTRACT.token_values(close))
        self.assertLess(lock, callback_track)
        self.assertLess(callback_track, channel_read)
        self.assertLess(channel_read, generation_read)
        self.assertLess(generation_read, channel_identity_check)
        self.assertLess(channel_identity_check, nonzero_generation_check)
        self.assertLess(nonzero_generation_check, generation_identity_check)
        self.assertLess(generation_identity_check, channel_clear)
        self.assertLess(channel_clear, generation_advance)
        self.assertLess(generation_advance, unlock)
        self.assertLess(unlock, notification)

    def test_callbacks_are_drained_only_after_freerdp_context_teardown(self) -> None:
        run_connection = method_body(
            self.tokens,
            return_type="void",
            selector="runConnectionWithConfiguration",
            has_parameter=True,
        )
        values = CONTRACT.token_values(run_connection)
        context_free = ["freerdp_client_context_free", "(", "context", ")", ";"]
        deferred_drain = [
            "[",
            "self",
            ".",
            "dvcCallbackReleasePool",
            "drainTrackedPointers",
            "]",
            ";",
        ]
        paired = context_free + deferred_drain
        context_free_count = sum(
            values[index : index + len(context_free)] == context_free
            for index in range(len(values) - len(context_free) + 1)
        )
        paired_count = sum(
            values[index : index + len(paired)] == paired
            for index in range(len(values) - len(paired) + 1)
        )
        self.assertEqual(context_free_count, 4)
        self.assertEqual(paired_count, context_free_count)

    def test_open_and_teardown_pointer_updates_use_the_lifecycle_lock(self) -> None:
        sequence_index(
            self.tokens,
            [
                "typedef",
                "struct",
                "{",
                "GENERIC_CHANNEL_CALLBACK",
                "base",
                ";",
                "uint64_t",
                "generation",
                ";",
                "}",
                "JTCompanionDVCChannelCallback",
                ";",
            ],
        )
        open_body = method_body(
            self.tokens,
            return_type="BOOL",
            selector="handleDVCOpenCallback",
            has_parameter=True,
        )
        open_lock = sequence_index(open_body, ["self", ".", "dvcChannelLock", "lock"])
        callback_track = sequence_index(
            open_body,
            ["self", ".", "dvcCallbackReleasePool", "trackPointer", ":", "callback"],
        )
        channel_read = sequence_index(
            open_body,
            ["callback", "->", "base", ".", "channel"],
        )
        next_generation = sequence_index(
            open_body,
            [
                "JTNextDVCGeneration",
                "(",
                "self",
                ".",
                "engineState",
                "->",
                "dvcGeneration",
                ")",
            ],
        )
        open_assign = sequence_index(
            open_body,
            ["engineState", "->", "dvcChannel", "=", "channel"],
        )
        generation_assign = sequence_index(
            open_body,
            ["engineState", "->", "dvcGeneration", "=", "generation"],
        )
        callback_generation_assign = sequence_index(
            open_body,
            ["callback", "->", "generation", "=", "generation"],
        )
        open_unlock = sequence_index(open_body, ["self", ".", "dvcChannelLock", "unlock"])
        open_notification = sequence_index(open_body, ["self", "notifyState", ":"])
        self.assertLess(open_lock, callback_track)
        self.assertLess(callback_track, channel_read)
        self.assertLess(channel_read, next_generation)
        self.assertLess(next_generation, open_assign)
        self.assertLess(open_assign, generation_assign)
        self.assertLess(generation_assign, callback_generation_assign)
        self.assertLess(callback_generation_assign, open_unlock)
        self.assertLess(open_unlock, open_notification)

        clear_body = method_body(
            self.tokens,
            return_type="void",
            selector="clearDVCChannel",
            has_parameter=False,
        )
        clear_lock = sequence_index(clear_body, ["self", ".", "dvcChannelLock", "lock"])
        clear_assign = sequence_index(
            clear_body,
            ["engineState", "->", "dvcChannel", "=", "NULL"],
        )
        clear_generation_advance = sequence_index(
            clear_body,
            [
                "engineState",
                "->",
                "dvcGeneration",
                "=",
                "JTNextDVCGeneration",
                "(",
            ],
        )
        clear_unlock = sequence_index(clear_body, ["self", ".", "dvcChannelLock", "unlock"])
        self.assertLess(clear_lock, clear_assign)
        self.assertLess(clear_assign, clear_generation_advance)
        self.assertLess(clear_generation_advance, clear_unlock)


if __name__ == "__main__":
    unittest.main()
