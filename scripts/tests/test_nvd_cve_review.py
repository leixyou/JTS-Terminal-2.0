import unittest

from scripts.lib.nvd_cve_review import review_response


CPE = "cpe:2.3:a:freerdp:freerdp:3.31.1:*:*:*:*:*:*:*"
OPENSSL_CPE = "cpe:2.3:a:openssl:openssl:3.6.4:*:*:*:*:*:*:*"


def response(*records):
    return {"format": "NVD_CVE", "version": "2.0", "startIndex": 0,
            "resultsPerPage": len(records), "totalResults": len(records),
            "vulnerabilities": [{"cve": record} for record in records]}


def record(status="Analyzed", **bounds):
    return {"id": "CVE-2026-66401", "vulnStatus": status,
            "configurations": [{"nodes": [{"operator": "OR", "cpeMatch": [{
                "vulnerable": True, "criteria": CPE.replace(":3.31.1:", ":*:"), **bounds
            }]}]}]}


def environment_record(status="Modified"):
    """Model the saved NVD Apache/OpenSSL AND plus other-product OR shape."""
    return {
        "id": "CVE-2019-0190", "vulnStatus": status,
        "configurations": [
            {"operator": "AND", "nodes": [
                {"operator": "OR", "negate": False, "cpeMatch": [{
                    "vulnerable": True,
                    "criteria": "cpe:2.3:a:apache:http_server:2.4.37:*:*:*:*:*:*:*",
                }]},
                {"operator": "OR", "negate": False, "cpeMatch": [{
                    "vulnerable": False,
                    "criteria": OPENSSL_CPE.replace(":3.6.4:", ":*:"),
                    "versionStartIncluding": "1.1.1",
                }]},
            ]},
            {"nodes": [{"operator": "OR", "negate": False, "cpeMatch": [{
                "vulnerable": True,
                "criteria": "cpe:2.3:a:oracle:enterprise_manager_ops_center:12.3.3:*:*:*:*:*:*:*",
            }]}]},
        ],
    }


class NVDReviewTests(unittest.TestCase):
    def review(self, document):
        return review_response(document, CPE, "3.31.1")

    def test_complete_empty_response_is_clear(self):
        self.assertEqual(self.review(response()), [])

    def test_affected_version_blocks(self):
        self.assertIn("affected", self.review(response(record(versionEndIncluding="3.31.1")))[0][1])

    def test_patched_version_is_clear_only_with_analyzed_range(self):
        self.assertEqual(self.review(response(record(versionEndExcluding="3.31.1"))), [])

    def test_undergoing_analysis_without_configurations_blocks(self):
        self.assertIn("unresolved", self.review(response({
            "id": "CVE-2026-66402", "vulnStatus": "Undergoing Analysis"
        }))[0][1])

    def test_unanalyzed_nonmatching_range_is_not_a_clean_result(self):
        self.assertTrue(self.review(response(record("Awaiting Analysis", versionEndExcluding="3.29.0"))))

    def test_rejected_record_does_not_block(self):
        self.assertEqual(self.review(response({"id": "CVE-2026-66402", "vulnStatus": "Rejected"})), [])

    def test_missing_configuration_even_when_analyzed_blocks(self):
        self.assertTrue(self.review(response({"id": "CVE-2026-66402", "vulnStatus": "Analyzed"})))

    def test_partial_or_malformed_response_fails_closed(self):
        for update in ({"totalResults": 1}, {"startIndex": 1}, {"format": "error"},
                       {"resultsPerPage": True}, {"vulnerabilities": None}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                self.review({**response(), **update})

    def test_duplicate_and_malformed_records_fail_closed(self):
        for document in (response(record(), record()), response({"id": "bad"}), response({})):
            with self.subTest(document=document), self.assertRaises(ValueError):
                self.review(document)

    def test_unknown_version_comparison_fails_closed(self):
        with self.assertRaises(ValueError):
            self.review(response(record(versionEndExcluding="3.32.0-beta1")))

    def test_nested_environment_constraints_are_conservative(self):
        cve = record()
        cve["configurations"][0]["operator"] = "AND"
        cve["configurations"][0]["nodes"].append({"operator": "OR", "cpeMatch": [{
            "vulnerable": False, "criteria": "cpe:2.3:o:microsoft:windows_11:*:*:*:*:*:*:*:*"
        }]})
        self.assertTrue(self.review(response(cve)))

    def test_explicit_environment_can_coexist_with_patched_target(self):
        cve = record(versionEndExcluding="3.31.1")
        cve["configurations"][0]["operator"] = "AND"
        cve["configurations"][0]["nodes"].append({"operator": "OR", "cpeMatch": [{
            "vulnerable": False,
            "criteria": "cpe:2.3:o:microsoft:windows_11:22h2:*:*:*:*:*:*:*",
        }]})
        self.assertEqual(self.review(response(cve)), [])

    def test_unknown_cpe_patterns_never_exclude_target(self):
        for criteria in (
            CPE.replace(":3.31.1:", ":3.31.*:"),
            CPE.replace(":freerdp:freerdp:", ":*:freerdp:"),
            CPE.replace(":freerdp:freerdp:", ":freerdp:freerd?:"),
            CPE.replace(":3.31.1:", ":-:"),
            CPE.replace(":3.31.1:", ":3.31.1-beta1:"),
        ):
            cve = record(versionEndExcluding="3.30.0")
            cve["configurations"][0]["nodes"][0]["cpeMatch"][0]["criteria"] = criteria
            with self.subTest(criteria=criteria), self.assertRaises(ValueError):
                self.review(response(cve))

    def test_unrelated_matches_are_not_target_exclusion_proof(self):
        cve = record(versionEndExcluding="3.30.0")
        cve["configurations"][0]["nodes"][0]["cpeMatch"][0]["criteria"] = CPE.replace(
            ":freerdp:freerdp:", ":other:product:",
        )
        self.assertIn("unresolved", self.review(response(cve))[0][1])

    def test_analyzed_target_environment_is_not_a_component_vulnerability(self):
        for status in ("Analyzed", "Modified"):
            for bounded in (False, True):
                cve = environment_record(status)
                if not bounded:
                    del cve["configurations"][0]["nodes"][1]["cpeMatch"][0]["versionStartIncluding"]
                with self.subTest(status=status, bounded=bounded):
                    self.assertEqual(review_response(response(cve), OPENSSL_CPE, "3.6.4"), [])

    def test_target_environment_still_requires_analysis_and_explicit_target(self):
        for case in ("undergoing", "absent"):
            cve = environment_record("Undergoing Analysis" if case == "undergoing" else "Modified")
            if case == "absent":
                cve["configurations"][0]["nodes"].pop()
            with self.subTest(case=case):
                findings = review_response(response(cve), OPENSSL_CPE, "3.6.4")
                self.assertIn("unresolved", findings[0][1])

    def test_nonvulnerable_environment_cannot_hide_a_vulnerable_target_match(self):
        cve = environment_record()
        cve["configurations"][1]["nodes"][0]["cpeMatch"].append({
            "vulnerable": True, "criteria": OPENSSL_CPE,
        })
        findings = review_response(response(cve), OPENSSL_CPE, "3.6.4")
        self.assertIn("affected", findings[0][1])

    def test_target_environment_unknown_pattern_and_invalid_bounds_fail_closed(self):
        for update in (
            {"criteria": OPENSSL_CPE.replace(":3.6.4:", ":3.6.*:")},
            {"versionEndExcluding": "invalid"},
            {"versionEndExcluding": "1.0.0"},
        ):
            cve = environment_record()
            cve["configurations"][0]["nodes"][1]["cpeMatch"][0].update(update)
            with self.subTest(update=update), self.assertRaises(ValueError):
                review_response(response(cve), OPENSSL_CPE, "3.6.4")

    def test_all_bounds_are_parsed_before_excluding_version_or_environment(self):
        for criteria in (
            CPE.replace(":3.31.1:", ":*:"),
            CPE.replace(":3.31.1:", ":3.20.0:"),
            CPE.replace(":freerdp:freerdp:", ":other:product:"),
        ):
            cve = record(versionStartIncluding="4.0.0", versionEndExcluding="invalid")
            cve["configurations"][0]["nodes"][0]["cpeMatch"][0]["criteria"] = criteria
            with self.subTest(criteria=criteria), self.assertRaises(ValueError):
                self.review(response(cve))

    def test_conflicting_empty_and_duplicate_bounds_fail_closed(self):
        for bounds in (
            {"versionStartIncluding": "4.0.0", "versionEndExcluding": "3.0.0"},
            {"versionStartIncluding": "3.0.0", "versionEndExcluding": "3.0.0"},
            {"versionStartExcluding": "3.0.0", "versionEndIncluding": "3.0.0"},
            {"versionStartIncluding": "3.0.0", "versionStartExcluding": "3.1.0"},
            {"versionEndIncluding": "3.0.0", "versionEndExcluding": "3.1.0"},
            {"versionEndExclusive": "3.0.0"},
        ):
            with self.subTest(bounds=bounds), self.assertRaises(ValueError):
                self.review(response(record(**bounds)))

    def test_exact_version_must_agree_with_its_bounds(self):
        cve = record(versionEndExcluding="3.0.0")
        cve["configurations"][0]["nodes"][0]["cpeMatch"][0]["criteria"] = CPE
        with self.assertRaises(ValueError):
            self.review(response(cve))

    def test_exact_versions_and_inclusive_single_version_ranges_remain_supported(self):
        for exact_version, expected in (("3.31.1.0", True), ("3.30.0", False)):
            cve = record()
            cve["configurations"][0]["nodes"][0]["cpeMatch"][0]["criteria"] = CPE.replace(
                ":3.31.1:", f":{exact_version}:",
            )
            with self.subTest(exact_version=exact_version):
                self.assertEqual(bool(self.review(response(cve))), expected)
        self.assertTrue(self.review(response(record(
            versionStartIncluding="3.31.1", versionEndIncluding="3.31.1.0",
        ))))

    def test_target_vendor_case_cannot_hide_an_affected_range(self):
        cve = record(versionEndExcluding="3.31.1")
        cve["configurations"][0]["nodes"][0]["cpeMatch"].append({
            "vulnerable": True, "criteria": CPE.replace("freerdp", "FreeRDP"),
        })
        self.assertIn("affected", self.review(response(cve))[0][1])

    def test_negation_and_unknown_operators_fail_closed_at_every_level(self):
        for level in ("configuration", "node"):
            for update in ({"negate": True}, {"negate": "false"}, {"operator": "XOR"}):
                cve = record(versionEndExcluding="3.31.1")
                config = cve["configurations"][0]
                node = config if level == "configuration" else config["nodes"][0]
                node.update(update)
                with self.subTest(level=level, update=update), self.assertRaises(ValueError):
                    self.review(response(cve))

    def test_malformed_or_missing_nodes_cannot_hide_beside_a_patched_range(self):
        for node in (
            None, {}, {"operator": "OR"}, {"operator": "OR", "cpeMatch": []},
            {"operator": "OR", "cpeMatch": {}}, {"operator": "OR", "children": []},
            {"cpeMatch": [{"vulnerable": True, "criteria": CPE}]},
        ):
            cve = record(versionEndExcluding="3.31.1")
            cve["configurations"][0]["nodes"].append(node)
            with self.subTest(node=node), self.assertRaises(ValueError):
                self.review(response(cve))

    def test_missing_match_fields_are_rejected_even_after_an_affected_match(self):
        for match in ({}, {"criteria": CPE}, {"vulnerable": True}):
            cve = record()
            cve["configurations"][0]["nodes"][0]["cpeMatch"].append(match)
            with self.subTest(match=match), self.assertRaises(ValueError):
                self.review(response(cve))


if __name__ == "__main__":
    unittest.main()
