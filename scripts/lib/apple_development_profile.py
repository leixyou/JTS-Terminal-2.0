"""Validation for an optional embedded macOS development provisioning profile."""

from __future__ import annotations

import dataclasses
import datetime as dt
import hashlib
import json
import plistlib
import re
import subprocess
from collections.abc import Callable


class DevelopmentProfileError(RuntimeError):
    """The embedded profile is not valid for this build and Mac."""


@dataclasses.dataclass(frozen=True)
class DevelopmentProfileIdentity:
    uuid: str
    name: str
    expiration: str
    matched_device_identifier: str
    matched_certificate_sha1: str


CommandRunner = Callable[..., subprocess.CompletedProcess[bytes]]


def current_mac_provisioning_identifier(
    *,
    runner: CommandRunner = subprocess.run,
) -> str:
    """Read the UDID used by Apple Development provisioning profiles."""

    result = runner(
        ["/usr/sbin/system_profiler", "SPHardwareDataType", "-json"],
        text=False,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise DevelopmentProfileError(
            "system_profiler could not read the current Mac provisioning UDID."
        )
    return parse_mac_provisioning_identifier(result.stdout)


def parse_mac_provisioning_identifier(payload: bytes) -> str:
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as error:
        raise DevelopmentProfileError(
            "system_profiler returned invalid hardware JSON."
        ) from error
    hardware = (
        document.get("SPHardwareDataType")
        if isinstance(document, dict)
        else None
    )
    if not isinstance(hardware, list):
        raise DevelopmentProfileError(
            "system_profiler hardware JSON has no hardware overview."
        )
    for item in hardware:
        if not isinstance(item, dict):
            continue
        value = item.get("provisioning_UDID")
        if isinstance(value, str) and value:
            _normalize_device_identifier(value)
            return value
    raise DevelopmentProfileError(
        "The current Mac has no provisioning UDID in system_profiler."
    )


def validate_development_profile(
    profile_bytes: bytes,
    *,
    expected_team_identifier: str,
    expected_bundle_identifier: str,
    expected_certificate_sha1: str,
    current_device_identifier: str,
    now: dt.datetime | None = None,
) -> DevelopmentProfileIdentity:
    try:
        profile = plistlib.loads(profile_bytes)
    except (plistlib.InvalidFileException, ValueError, TypeError) as error:
        raise DevelopmentProfileError(
            "Decoded development profile is not a valid plist."
        ) from error
    if not isinstance(profile, dict):
        raise DevelopmentProfileError("Decoded development profile must be a dictionary.")
    if not re.fullmatch(r"[A-Z0-9]{10}", expected_team_identifier):
        raise DevelopmentProfileError("Expected TeamIdentifier is invalid.")
    certificate_sha1 = expected_certificate_sha1.upper()
    if not re.fullmatch(r"[0-9A-F]{40}", certificate_sha1):
        raise DevelopmentProfileError("Expected certificate SHA-1 is invalid.")

    platforms = profile.get("Platform")
    if not isinstance(platforms, list) or "OSX" not in platforms:
        raise DevelopmentProfileError("Development profile Platform must include OSX.")
    if profile.get("ProvisionsAllDevices") is True:
        raise DevelopmentProfileError(
            "Development profile must bind explicit registered devices."
        )
    teams = profile.get("TeamIdentifier")
    if teams != [expected_team_identifier]:
        raise DevelopmentProfileError(
            "Development profile TeamIdentifier does not match the build team."
        )
    prefixes = profile.get("ApplicationIdentifierPrefix")
    if not isinstance(prefixes, list) or expected_team_identifier not in prefixes:
        raise DevelopmentProfileError(
            "Development profile application identifier prefix does not include the team."
        )

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        raise DevelopmentProfileError("Development profile has no valid expiration date.")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    current_time = now or dt.datetime.now(dt.timezone.utc)
    if current_time.tzinfo is None:
        current_time = current_time.replace(tzinfo=dt.timezone.utc)
    if expiration <= current_time:
        raise DevelopmentProfileError("Development profile is expired.")

    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        raise DevelopmentProfileError("Development profile entitlements are missing.")
    expected_application_identifier = (
        f"{expected_team_identifier}.{expected_bundle_identifier}"
    )
    if (
        entitlements.get("com.apple.application-identifier")
        != expected_application_identifier
    ):
        raise DevelopmentProfileError(
            "Development profile application identifier does not match the app."
        )
    if (
        entitlements.get("com.apple.developer.team-identifier")
        != expected_team_identifier
    ):
        raise DevelopmentProfileError(
            "Development profile entitlement TeamIdentifier does not match."
        )
    keychain_groups = entitlements.get("keychain-access-groups")
    if not isinstance(keychain_groups, list) or (
        f"{expected_team_identifier}.*" not in keychain_groups
        and expected_application_identifier not in keychain_groups
    ):
        raise DevelopmentProfileError(
            "Development profile does not authorize the app's keychain access group."
        )

    normalized_device = _normalize_device_identifier(current_device_identifier)
    devices = profile.get("ProvisionedDevices")
    if not isinstance(devices, list) or not devices:
        raise DevelopmentProfileError(
            "Development profile contains no registered devices."
        )
    normalized_devices = {
        _normalize_device_identifier(device)
        for device in devices
        if isinstance(device, str)
    }
    if normalized_device not in normalized_devices:
        raise DevelopmentProfileError(
            "Development profile does not include the current Mac."
        )

    developer_certificates = profile.get("DeveloperCertificates")
    if not isinstance(developer_certificates, list):
        raise DevelopmentProfileError(
            "Development profile contains no developer certificates."
        )
    profile_certificate_sha1s = {
        hashlib.sha1(value).hexdigest().upper()
        for value in developer_certificates
        if isinstance(value, bytes)
    }
    if certificate_sha1 not in profile_certificate_sha1s:
        raise DevelopmentProfileError(
            "Development profile does not contain the selected signing certificate."
        )

    uuid = profile.get("UUID")
    name = profile.get("Name")
    if not isinstance(uuid, str) or not uuid:
        raise DevelopmentProfileError("Development profile UUID is missing.")
    if not isinstance(name, str) or not name:
        raise DevelopmentProfileError("Development profile name is missing.")
    return DevelopmentProfileIdentity(
        uuid=uuid,
        name=name,
        expiration=expiration.astimezone(dt.timezone.utc).isoformat().replace(
            "+00:00", "Z"
        ),
        matched_device_identifier=current_device_identifier,
        matched_certificate_sha1=certificate_sha1,
    )


def _normalize_device_identifier(value: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9]", "", value).upper()
    if len(normalized) < 8:
        raise DevelopmentProfileError("Current Mac device identifier is invalid.")
    return normalized
