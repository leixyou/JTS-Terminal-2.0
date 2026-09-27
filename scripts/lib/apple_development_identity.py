"""Fail-closed Apple Development identity selection by certificate Team OU."""

from __future__ import annotations

import dataclasses
import re
import subprocess
from collections.abc import Callable


class IdentitySelectionError(RuntimeError):
    """The local keychains do not expose one unambiguous signing identity."""


@dataclasses.dataclass(frozen=True)
class CertificateSubject:
    sha1: str
    common_name: str
    organizational_unit: str


@dataclasses.dataclass(frozen=True)
class AppleDevelopmentIdentity:
    sha1: str
    label: str
    common_name: str
    team_identifier: str


def parse_valid_code_signing_identities(output: str) -> dict[str, str]:
    """Return the SHA-1 and label for identities with an available private key."""

    identities: dict[str, str] = {}
    pattern = re.compile(
        r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"\s*$',
        re.MULTILINE,
    )
    for match in pattern.finditer(output):
        sha1 = match.group(1).upper()
        label = match.group(2)
        previous = identities.setdefault(sha1, label)
        if previous != label:
            raise IdentitySelectionError(
                f"Signing identity {sha1} has conflicting keychain labels."
            )
    return identities


def inspect_pem_certificates(
    pem_bundle: bytes,
    *,
    runner: Callable[..., subprocess.CompletedProcess[bytes]] = subprocess.run,
) -> dict[str, CertificateSubject]:
    """Read leaf fingerprint/CN/OU values without relying on keychain labels."""

    blocks = re.findall(
        rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\s*",
        pem_bundle,
        flags=re.DOTALL,
    )
    if not blocks:
        raise IdentitySelectionError("No certificates were exported from the keychains.")

    records: dict[str, CertificateSubject] = {}
    for block in blocks:
        result = runner(
            [
                "/usr/bin/openssl",
                "x509",
                "-noout",
                "-fingerprint",
                "-sha1",
                "-subject",
                "-nameopt",
                "RFC2253",
            ],
            input=block,
            capture_output=True,
            check=False,
        )
        if result.returncode != 0:
            raise IdentitySelectionError(
                "OpenSSL could not inspect an exported keychain certificate."
            )
        record = parse_openssl_certificate_details(
            result.stdout.decode("utf-8", errors="strict")
        )
        previous = records.setdefault(record.sha1, record)
        if previous != record:
            raise IdentitySelectionError(
                f"Certificate {record.sha1} has conflicting subject metadata."
            )
    return records


def parse_openssl_certificate_details(output: str) -> CertificateSubject:
    fingerprint_match = re.search(
        r"^sha1 Fingerprint=([0-9A-Fa-f:]+)$",
        output,
        re.MULTILINE | re.IGNORECASE,
    )
    subject_match = re.search(r"^subject=(.+)$", output, re.MULTILINE)
    if fingerprint_match is None or subject_match is None:
        raise IdentitySelectionError(
            "OpenSSL certificate output omitted the fingerprint or subject."
        )
    sha1 = fingerprint_match.group(1).replace(":", "").upper()
    if not re.fullmatch(r"[0-9A-F]{40}", sha1):
        raise IdentitySelectionError("Certificate SHA-1 fingerprint is invalid.")

    attributes: dict[str, list[str]] = {}
    for component in _split_rfc2253_name(subject_match.group(1)):
        if "=" not in component:
            continue
        key, value = component.split("=", 1)
        attributes.setdefault(key, []).append(_unescape_rfc2253_value(value))
    common_names = attributes.get("CN", [])
    organizational_units = attributes.get("OU", [])
    if len(common_names) > 1 or len(organizational_units) > 1:
        raise IdentitySelectionError(
            "Certificate subject contains ambiguous CN or OU values."
        )
    return CertificateSubject(
        sha1=sha1,
        common_name=common_names[0] if common_names else "",
        organizational_unit=(organizational_units[0] if organizational_units else ""),
    )


def select_apple_development_identity(
    valid_identities: dict[str, str],
    certificates: dict[str, CertificateSubject],
    *,
    expected_team_identifier: str,
) -> AppleDevelopmentIdentity:
    if not re.fullmatch(r"[A-Z0-9]{10}", expected_team_identifier):
        raise IdentitySelectionError("Expected TeamIdentifier is invalid.")

    matches: list[AppleDevelopmentIdentity] = []
    for sha1, label in valid_identities.items():
        certificate = certificates.get(sha1.upper())
        if certificate is None:
            continue
        if not certificate.common_name.startswith("Apple Development: "):
            continue
        if certificate.organizational_unit != expected_team_identifier:
            continue
        if label != certificate.common_name:
            raise IdentitySelectionError(
                f"Identity {sha1} label does not match its certificate common name."
            )
        matches.append(
            AppleDevelopmentIdentity(
                sha1=sha1.upper(),
                label=label,
                common_name=certificate.common_name,
                team_identifier=certificate.organizational_unit,
            )
        )

    matches.sort(key=lambda item: item.sha1)
    if len(matches) != 1:
        fingerprints = ", ".join(item.sha1 for item in matches) or "none"
        raise IdentitySelectionError(
            "Expected exactly one usable Apple Development identity with certificate "
            f"OU={expected_team_identifier}; found {len(matches)} ({fingerprints})."
        )
    return matches[0]


def _split_rfc2253_name(value: str) -> list[str]:
    components: list[str] = []
    current: list[str] = []
    escaped = False
    for character in value:
        if escaped:
            current.append(character)
            escaped = False
        elif character == "\\":
            current.append(character)
            escaped = True
        elif character == ",":
            components.append("".join(current))
            current = []
        else:
            current.append(character)
    components.append("".join(current))
    return components


def _unescape_rfc2253_value(value: str) -> str:
    return re.sub(r"\\([,=+<>#;\\\"])", r"\1", value)
