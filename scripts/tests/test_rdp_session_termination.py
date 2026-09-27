from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONTRACT_PATH = ROOT / "scripts" / "verify_freerdp_runtime_contract.py"
SPEC = importlib.util.spec_from_file_location("verify_freerdp_runtime_contract", CONTRACT_PATH)
assert SPEC is not None and SPEC.loader is not None
CONTRACT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CONTRACT
SPEC.loader.exec_module(CONTRACT)


def sequence_index(tokens: list[object], expected: list[str]) -> int:
    values = CONTRACT.token_values(tokens)
    for index in range(len(values) - len(expected) + 1):
        if values[index : index + len(expected)] == expected:
            return index
    raise AssertionError(f"token sequence not found: {' '.join(expected)}")


def sequence_indices(tokens: list[object], expected: list[str]) -> list[int]:
    values = CONTRACT.token_values(tokens)
    return [
        index
        for index in range(len(values) - len(expected) + 1)
        if values[index : index + len(expected)] == expected
    ]


def objective_c_definition_body(
    tokens: list[object],
    *,
    return_type: str,
    first_selector: str,
) -> list[object]:
    signature = ["-", "(", return_type, ")", first_selector, ":"]
    values = CONTRACT.token_values(tokens)
    for index in range(len(values) - len(signature) + 1):
        if values[index : index + len(signature)] != signature:
            continue
        body_start = index + len(signature)
        while body_start < len(tokens) and values[body_start] not in {";", "{"}:
            body_start += 1
        if body_start == len(tokens) or values[body_start] == ";":
            continue
        body_end = CONTRACT.matching_delimiter(tokens, body_start)
        return list(tokens[body_start : body_end + 1])
    raise AssertionError(f"Objective-C method definition not found: {first_selector}:")


class RDPSessionTerminationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = (ROOT / "JTFreeRDPService" / "JTFreeRDPEngine.m").read_text(
            encoding="utf-8"
        )
        tokens = CONTRACT.tokenize_c_family(cls.source)
        cls.run_connection = CONTRACT.objective_c_method_body(
            tokens,
            return_type="void",
            first_selector="runConnectionWithConfiguration",
        )
        cls.verify_pem_certificate = objective_c_definition_body(
            tokens,
            return_type="int",
            first_selector="verifyPinnedCertificatePEM",
        )
        cls.verify_rich_certificate = objective_c_definition_body(
            tokens,
            return_type="DWORD",
            first_selector="verifyCertificateForHost",
        )

    def test_protocol_end_reason_is_captured_before_context_teardown(self) -> None:
        error_info = sequence_index(
            self.run_connection,
            ["sessionErrorInfo", "=", "freerdp_error_info", "(", "instance", ")"],
        )
        last_error = sequence_index(
            self.run_connection,
            ["sessionLastError", "=", "freerdp_get_last_error", "(", "context", ")"],
        )
        disconnect = sequence_index(
            self.run_connection,
            ["freerdp_disconnect", "(", "instance", ")"],
        )
        context_frees = sequence_indices(
            self.run_connection,
            ["freerdp_client_context_free", "(", "context", ")"],
        )
        context_free = next(index for index in context_frees if index > last_error)

        self.assertLess(error_info, disconnect)
        self.assertLess(last_error, disconnect)
        self.assertLess(error_info, context_free)
        self.assertLess(last_error, context_free)

    def test_manual_disconnect_takes_precedence_over_server_error_mapping(self) -> None:
        manual_disconnect = sequence_index(
            self.run_connection,
            [
                "self",
                ".",
                "running",
                "=",
                "NO",
                ";",
                "if",
                "(",
                "self",
                ".",
                "disconnectRequested",
                ")",
            ],
        )
        logoff_mapping = sequence_index(
            self.run_connection,
            [
                "sessionErrorInfo",
                "=",
                "=",
                "ERRINFO_LOGOFF_BY_USER",
                "|",
                "|",
                "sessionLastError",
                "=",
                "=",
                "FREERDP_ERROR_LOGOFF_BY_USER",
            ],
        )

        self.assertLess(manual_disconnect, logoff_mapping)
        self.assertIn(
            '[self notifyState:@"closed" code:nil message:nil];',
            self.source,
        )

    def test_logoff_maps_to_stable_non_transport_failure_code(self) -> None:
        self.assertIn('code:@"RDP_LOGOFF_BY_USER"', self.source)
        self.assertEqual(self.source.count('code:@"RDP_LOGOFF_BY_USER"'), 1)
        self.assertIn('code:@"RDP_CONNECTION_LOST"', self.source)

    def test_certificate_challenge_is_atomic_in_state_and_keeps_legacy_callback(
        self,
    ) -> None:
        for body, challenge_name in (
            (self.verify_pem_certificate, "challenge"),
            (self.verify_rich_certificate, "certificate"),
        ):
            state_notification = sequence_index(
                body,
                ["certificate", ":", challenge_name, "]", ";"],
            )
            legacy_callback = sequence_index(
                body,
                [
                    "self",
                    ".",
                    "delegate",
                    "rdpEngineDidRequireCertificateDecision",
                    ":",
                    challenge_name,
                    "]",
                    ";",
                ],
            )
            self.assertLess(state_notification, legacy_callback)

        self.assertIn(
            "[self notifyState:phase code:code message:message certificate:nil];",
            self.source,
        )
        self.assertEqual(
            self.source.count('[self notifyState:@"awaitingCertificateTrust"'),
            2,
        )
        self.assertIn('state[@"certificate"] = certificate;', self.source)

    def test_certificate_boolean_fields_use_real_objc_booleans(self) -> None:
        self.assertEqual(
            self.source.count(
                '@"hostMismatch": @((BOOL)((flags & VERIFY_CERT_FLAG_MISMATCH) != 0))'
            ),
            2,
        )
        self.assertIn('@"pinnedMismatch": @(pinnedMismatch)', self.source)

    def test_pem_trust_once_mismatch_is_not_reported_as_a_persistent_pin(self) -> None:
        body = CONTRACT.token_values(self.verify_pem_certificate)

        self.assertIn("hasPinnedFingerprint", body)
        self.assertIn("hasTrustOnceFingerprint", body)
        self.assertIn(
            "The RDP certificate no longer matches the fingerprint trusted for this connection. The connection was blocked.",
            self.source,
        )
        self.assertIn('@"pinnedMismatch": @(hasPinnedFingerprint)', self.source)

    def test_rich_certificate_callback_hashes_bounded_pem_fingerprints(self) -> None:
        self.assertIn(
            "if ((flags & VERIFY_CERT_FLAG_FP_IS_PEM) != 0)",
            self.source,
        )
        self.assertIn(
            "strnlen(fingerprint, JTMaximumCertificateChainBytes + 1)",
            self.source,
        )
        self.assertIn(
            "JTLeafCertificateSHA256FromPEM((const BYTE *)fingerprint, length)",
            self.source,
        )
        body = CONTRACT.token_values(self.verify_rich_certificate)
        self.assertGreaterEqual(body.count("certificateFingerprintFromCString"), 2)

    def test_rich_pinned_mismatch_is_always_reported_as_changed(self) -> None:
        body = CONTRACT.token_values(self.verify_rich_certificate)
        self.assertIn("pinnedMismatch", body)
        self.assertIn("trustOnceMismatch", body)
        self.assertIn("certificateChanged", body)
        self.assertIn('@"changed": @(certificateChanged)', self.source)


if __name__ == "__main__":
    unittest.main()
