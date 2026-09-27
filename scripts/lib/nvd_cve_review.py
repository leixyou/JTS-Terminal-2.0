"""Fail-closed review of one complete NVD exact-CPE response."""

import json
from pathlib import Path
import re
import sys


def version_key(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
        raise ValueError(f"Unsupported version bound: {value!r}")
    parts = tuple(int(part) for part in value.split("."))
    while len(parts) > 1 and parts[-1] == 0:
        parts = parts[:-1]
    return parts


def node_matches(node, *, configuration=False):
    if not isinstance(node, dict):
        raise ValueError("Malformed NVD configuration node")
    if set(node) - {"operator", "negate", "nodes", "cpeMatch"}:
        raise ValueError("Unsupported NVD configuration structure")
    if ("operator" in node or not configuration) and node.get("operator") not in ("AND", "OR"):
        raise ValueError("Unsupported or missing NVD configuration operator")
    if type(node.get("negate", False)) is not bool or node.get("negate", False):
        raise ValueError("Negated or malformed NVD configurations require upstream review")
    if configuration and "nodes" not in node:
        raise ValueError("Missing NVD configuration nodes")
    if not any(key in node for key in ("nodes", "cpeMatch")):
        raise ValueError("Missing NVD node applicability")
    for key in ("nodes", "cpeMatch"):
        if key not in node:
            continue
        entries = node[key]
        if not isinstance(entries, list) or not entries:
            raise ValueError(f"Malformed or empty NVD {key} list")
        for entry in entries:
            if key == "nodes":
                yield from node_matches(entry)
            else:
                yield entry


def cpe_matches(configurations):
    if configurations is None:
        return
    if not isinstance(configurations, list):
        raise ValueError("Malformed NVD configurations list")
    for configuration in configurations:
        yield from node_matches(configuration, configuration=True)


def cpe_parts(value):
    if not isinstance(value, str):
        raise ValueError("Malformed NVD CPE criteria")
    parts = value.split(":")
    if len(parts) != 13 or parts[:2] != ["cpe", "2.3"] or parts[2] not in ("a", "o", "h"):
        raise ValueError("Malformed NVD CPE criteria")
    if any(part not in ("*", "-") and not re.fullmatch(r"[A-Za-z0-9_.-]+", part)
           for part in parts[3:]):
        raise ValueError("Unsupported NVD CPE pattern; upstream review required")
    if any(part in ("*", "-") for part in parts[3:5]):
        raise ValueError("Unknown NVD CPE vendor or product; upstream review required")
    return [part.lower() for part in parts]


def version_bounds(match):
    lower_keys = ("versionStartIncluding", "versionStartExcluding")
    upper_keys = ("versionEndIncluding", "versionEndExcluding")
    allowed = lower_keys + upper_keys
    if any(key.startswith("version") and key not in allowed for key in match):
        raise ValueError("Unsupported NVD version bound")
    # Parse every bound before comparing, including ranges that would otherwise
    # short-circuit or belong to a non-target environment component.
    bounds = {key: version_key(match[key]) for key in allowed if key in match}
    lower = [key for key in lower_keys if key in bounds]
    upper = [key for key in upper_keys if key in bounds]
    if len(lower) > 1 or len(upper) > 1:
        raise ValueError("NVD range specifies both inclusive and exclusive bounds")
    if lower and upper:
        start, end = bounds[lower[0]], bounds[upper[0]]
        if start > end or (start == end and any(key.endswith("Excluding") for key in lower + upper)):
            raise ValueError("Contradictory or empty NVD version range")
    return bounds


def within_bounds(current, bounds):
    comparisons = (
        ("versionStartIncluding", lambda bound: current >= bound),
        ("versionStartExcluding", lambda bound: current > bound),
        ("versionEndIncluding", lambda bound: current <= bound),
        ("versionEndExcluding", lambda bound: current < bound),
    )
    return all(compare(bounds[key]) for key, compare in comparisons if key in bounds)


def version_in_match(match, target_cpe, version):
    """Return target vulnerability applicability, or None for another product."""
    if not isinstance(match, dict) or not isinstance(match.get("vulnerable"), bool):
        raise ValueError("Malformed NVD vulnerability match")
    criteria = cpe_parts(match.get("criteria"))
    bounds = version_bounds(match)
    target = cpe_parts(target_cpe)
    if criteria[2:5] != target[2:5]:
        return None
    if criteria[5] == "-":
        raise ValueError("Target CPE has no interpretable version applicability")
    exact = None if criteria[5] == "*" else version_key(criteria[5])
    if exact is not None and not within_bounds(exact, bounds):
        raise ValueError("Exact CPE version contradicts its NVD version range")
    current = version_key(version)
    # NVD exact-CPE results can describe a different vulnerable application
    # that merely uses this component as a non-vulnerable environment.
    return match["vulnerable"] and (exact is None or exact == current) and within_bounds(current, bounds)


def review_response(document, target_cpe, version):
    """Return blocking findings; incomplete/unanalyzed data is never a pass."""
    if not isinstance(document, dict) or document.get("format") != "NVD_CVE" or document.get("version") != "2.0":
        raise ValueError("Expected NVD CVE 2.0 response")
    target = cpe_parts(target_cpe)
    if target[5] != version:
        raise ValueError("Expected exact version-bound target CPE")
    version_key(version)
    records = document.get("vulnerabilities")
    total, start, page_size = (document.get(key) for key in ("totalResults", "startIndex", "resultsPerPage"))
    if (not isinstance(records, list)
            or any(type(value) is not int or value < 0 for value in (total, start, page_size))
            or start != 0 or total != len(records) or page_size < len(records)):
        raise ValueError("Incomplete or malformed NVD response; all result pages are required")
    findings = []
    seen = set()
    for record in records:
        cve = record.get("cve") if isinstance(record, dict) else None
        if not isinstance(cve, dict) or not re.fullmatch(r"CVE-[0-9]{4}-[0-9]{4,}", cve.get("id", "")):
            raise ValueError("Malformed NVD CVE record")
        identifier = cve["id"]
        if identifier in seen:
            raise ValueError(f"Duplicate NVD record: {identifier}")
        seen.add(identifier)
        if cve.get("vulnStatus") == "Rejected":
            continue
        configurations = cve.get("configurations")
        matches = list(cpe_matches(configurations))
        applicability = [version_in_match(match, target_cpe, version) for match in matches]
        if not matches:
            findings.append((identifier, "unresolved: no analyzed CPE applicability; upstream review required"))
        elif any(result is True for result in applicability):
            findings.append((identifier, "affected: version matches vulnerable CPE range"))
        elif not any(result is False for result in applicability):
            findings.append((identifier, "unresolved: no understood target CPE applicability; upstream review required"))
        elif cve.get("vulnStatus") not in ("Analyzed", "Modified"):
            findings.append((identifier, "unresolved: NVD analysis is not complete"))
    return findings


def main():
    component, version, cpe, path = sys.argv[1:]
    try:
        findings = review_response(json.loads(Path(path).read_text(encoding="utf-8")), cpe, version)
    except (ValueError, TypeError, AttributeError, OSError) as error:
        print(f"NVD review failed for {component} {version}: {error}", file=sys.stderr)
        return 1
    if findings:
        print(f"NVD requires review of {len(findings)} record(s) for {component} {version}:", file=sys.stderr)
        for identifier, reason in findings:
            print(f"  {identifier}: {reason}", file=sys.stderr)
        return 1
    print(f"NVD returned no applicable or unresolved CVE records for {component} {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
