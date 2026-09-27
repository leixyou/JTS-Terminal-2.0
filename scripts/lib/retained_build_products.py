"""Keep only the latest Debug and latest Release development apps."""

from __future__ import annotations

import os
import plistlib
import shutil
import stat
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from .rdp_candidate_binding import EXPECTED_APP_IDENTIFIER
from .rdp_process_recovery import DarwinProcessInspector, ProcessInspector
from .release_testing_runtime import unregister_runtime


APP_NAME = "JTS Terminal.app"
APP_EXECUTABLE_NAME = "JTS Terminal"
CANONICAL_DEBUG_RELATIVE = Path("DerivedData/Run/Build/Products/Debug") / APP_NAME
Configuration = Literal["debug", "release"]


class RetentionError(RuntimeError):
    """A fail-closed build-product retention error."""


@dataclass(frozen=True)
class DiscoveredProduct:
    configuration: Configuration
    app: Path
    removal_root: Path
    executable: Path | None
    mtime_ns: int


@dataclass(frozen=True)
class RetentionResult:
    kept_debug: Path | None
    kept_release: Path | None
    removed: tuple[Path, ...]


def retain_latest_debug_and_release(
    repo_root: Path,
    *,
    keep_app: Path | None = None,
    xcode_derived_data_root: Path | None = None,
    unregistrar: Callable[[Path], None] | None = None,
    process_inspector: ProcessInspector | None = None,
    remover: Callable[[Path], None] | None = None,
) -> RetentionResult:
    root = _require_repo_root(repo_root)
    xcode_root = _resolve_existing_directory(
        Path.home() / "Library/Developer/Xcode/DerivedData"
        if xcode_derived_data_root is None
        else xcode_derived_data_root,
        "Xcode DerivedData root",
        must_exist=False,
    )
    allowed_roots = _allowed_roots(root, xcode_root)
    products = _discover_products(root, xcode_root)
    keepers = _select_keepers(products, root=root, keep_app=keep_app)
    inspector = _resolve_inspector(process_inspector)
    unregister = unregistrar or unregister_runtime
    delete = remover or _remove_tree
    removed: list[Path] = []

    for product in products:
        keeper = keepers.get(product.configuration)
        if keeper is not None and product.removal_root == keeper.removal_root:
            continue
        _assert_idle(product, inspector)
        _assert_safe_to_remove(product.removal_root, allowed_roots)
        if product.app.is_dir() and not product.app.is_symlink():
            unregister(product.app)
        delete(product.removal_root)
        removed.append(product.removal_root)

    kept_release_root = (
        None if keepers.get("release") is None else keepers["release"].removal_root
    )
    for orphan in _orphaned_release_testing_directories(root, kept_release_root):
        _assert_safe_to_remove(orphan, allowed_roots)
        delete(orphan)
        removed.append(orphan)

    return RetentionResult(
        kept_debug=_app_for(keepers.get("debug")),
        kept_release=_app_for(keepers.get("release")),
        removed=tuple(removed),
    )


def _require_repo_root(repo_root: Path) -> Path:
    root = _resolve_existing_directory(repo_root, "repository root")
    if not (root / "JTSTerminal.xcodeproj").is_dir():
        raise RetentionError(
            f"Repository root does not contain JTSTerminal.xcodeproj: {root}"
        )
    return root


def _resolve_existing_directory(
    path: Path,
    description: str,
    *,
    must_exist: bool = True,
) -> Path:
    absolute = _require_absolute_normalized(path, description)
    if not absolute.exists():
        if must_exist:
            raise RetentionError(f"{description} does not exist: {absolute}")
        return absolute
    try:
        resolved = absolute.resolve()
    except OSError as error:
        raise RetentionError(f"{description} is unavailable: {error}") from error
    if not resolved.is_dir() or resolved.is_symlink():
        raise RetentionError(f"{description} is not a directory: {resolved}")
    return resolved


def _require_absolute_normalized(path: Path, description: str) -> Path:
    if not path.is_absolute() or Path(os.path.normpath(path)) != path:
        raise RetentionError(f"{description} must be an absolute normalized path.")
    return path


def _reject_internal_symlinks(path: Path, root: Path) -> None:
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise RetentionError(
            f"Path is outside its allowed root {root}: {path}"
        ) from error
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise RetentionError(f"Symlink path components are not allowed: {current}")


def _allowed_roots(repo_root: Path, xcode_root: Path) -> tuple[Path, ...]:
    roots = [
        repo_root / "DerivedData",
        repo_root / "build" / "ReleaseTesting",
    ]
    roots.extend(_workspace_derived_data_folders(repo_root, xcode_root))
    return tuple(roots)


def _discover_products(
    repo_root: Path, xcode_root: Path
) -> tuple[DiscoveredProduct, ...]:
    discovered: list[DiscoveredProduct] = []
    seen: set[Path] = set()
    for app in (
        *_iter_derived_data_container_apps(repo_root / "DerivedData"),
        *_iter_release_testing_apps(repo_root / "build" / "ReleaseTesting"),
        *(
            app
            for folder in _workspace_derived_data_folders(repo_root, xcode_root)
            for app in _iter_derived_data_folder_apps(folder)
        ),
    ):
        product = _product_from_app(app, repo_root=repo_root)
        if product is None or product.removal_root in seen:
            continue
        seen.add(product.removal_root)
        discovered.append(product)
    return tuple(discovered)


def _iter_derived_data_container_apps(derived_data_root: Path) -> Iterable[Path]:
    if not _is_safe_directory(derived_data_root):
        return
    for child in derived_data_root.iterdir():
        if child.name.startswith(".") or not _is_safe_directory(child):
            continue
        yield from _iter_derived_data_folder_apps(child)


def _iter_derived_data_folder_apps(folder: Path) -> Iterable[Path]:
    if not _is_safe_directory(folder):
        return
    for configuration in ("Debug", "Release"):
        app = folder / "Build" / "Products" / configuration / APP_NAME
        if _is_physical_app(app):
            yield app


def _orphaned_release_testing_directories(
    repo_root: Path, kept_release_root: Path | None
) -> tuple[Path, ...]:
    release_testing_root = repo_root / "build" / "ReleaseTesting"
    if not _is_safe_directory(release_testing_root):
        return ()
    orphans: list[Path] = []
    for child in release_testing_root.iterdir():
        if child.name.startswith(".") or not _is_safe_directory(child):
            continue
        if kept_release_root is not None and child == kept_release_root:
            continue
        app = child / APP_NAME
        if _is_physical_app(app) and _bundle_identifier(app) == EXPECTED_APP_IDENTIFIER:
            continue
        orphans.append(child)
    return tuple(orphans)


def _iter_release_testing_apps(release_testing_root: Path) -> Iterable[Path]:
    if not _is_safe_directory(release_testing_root):
        return
    for child in release_testing_root.iterdir():
        if child.name.startswith(".") or not _is_safe_directory(child):
            continue
        app = child / APP_NAME
        if _is_physical_app(app):
            yield app


def _workspace_derived_data_folders(
    repo_root: Path, xcode_root: Path
) -> tuple[Path, ...]:
    if not _is_safe_directory(xcode_root):
        return ()
    matched: list[Path] = []
    for child in xcode_root.iterdir():
        if child.name.startswith(".") or not _is_safe_directory(child):
            continue
        if _derived_data_belongs_to_repo(child, repo_root):
            matched.append(child)
    return tuple(matched)


def _derived_data_belongs_to_repo(folder: Path, repo_root: Path) -> bool:
    info = folder / "info.plist"
    if not info.is_file() or info.is_symlink():
        return False
    try:
        with info.open("rb") as stream:
            payload = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return False
    workspace = payload.get("WorkspacePath") or payload.get("IDEWorkspacePath")
    if not isinstance(workspace, str) or not workspace:
        return False
    try:
        workspace_path = Path(workspace)
    except TypeError:
        return False
    if not workspace_path.is_absolute():
        return False
    return workspace_path == repo_root or _is_relative_to(workspace_path, repo_root)


def _product_from_app(app: Path, *, repo_root: Path) -> DiscoveredProduct | None:
    if not _is_physical_app(app):
        return None
    try:
        app = app.resolve()
    except OSError:
        return None
    bundle_identifier = _bundle_identifier(app)
    # The normal Debug run uses the isolated UI-testing identity. Only its
    # canonical run location is a development product; other test hosts stay out.
    canonical_debug = (
        app == repo_root / CANONICAL_DEBUG_RELATIVE
        and bundle_identifier == f"{EXPECTED_APP_IDENTIFIER}.UITesting"
    )
    if bundle_identifier != EXPECTED_APP_IDENTIFIER and not canonical_debug:
        return None
    configuration = _classify_app(app)
    if configuration is None:
        return None
    executable = app / "Contents" / "MacOS" / APP_EXECUTABLE_NAME
    executable_path = executable if executable.is_file() and not executable.is_symlink() else None
    stamp = executable_path if executable_path is not None else app
    return DiscoveredProduct(
        configuration=configuration,
        app=app,
        removal_root=_removal_root(app, configuration),
        executable=executable_path,
        mtime_ns=stamp.stat().st_mtime_ns,
    )


def _classify_app(app: Path) -> Configuration | None:
    parts = app.parts
    try:
        products_index = parts.index("Products")
    except ValueError:
        products_index = -1
    if (
        products_index >= 2
        and parts[products_index - 1] == "Build"
        and products_index + 2 < len(parts)
        and parts[products_index + 2] == APP_NAME
    ):
        configuration = parts[products_index + 1]
        if configuration == "Debug":
            return "debug"
        if configuration == "Release":
            return "release"
    if "ReleaseTesting" in parts and app.parent.name.startswith("JTSTerminal-"):
        return "release"
    return None


def _removal_root(app: Path, configuration: Configuration) -> Path:
    if configuration == "release" and app.parent.parent.name == "ReleaseTesting":
        return app.parent
    return app


def _select_keepers(
    products: tuple[DiscoveredProduct, ...],
    *,
    root: Path,
    keep_app: Path | None,
) -> dict[Configuration, DiscoveredProduct]:
    by_configuration: dict[Configuration, list[DiscoveredProduct]] = {
        "debug": [],
        "release": [],
    }
    for product in products:
        by_configuration[product.configuration].append(product)

    keepers: dict[Configuration, DiscoveredProduct] = {}
    forced = (
        None if keep_app is None else _forced_product(keep_app, products, root=root)
    )
    if forced is not None:
        keepers[forced.configuration] = forced

    if "debug" not in keepers:
        selected_debug = _preferred_debug(by_configuration["debug"], root)
        if selected_debug is not None:
            keepers["debug"] = selected_debug
    if "release" not in keepers:
        selected_release = _preferred_release(by_configuration["release"])
        if selected_release is not None:
            keepers["release"] = selected_release
    return keepers


def _forced_product(
    keep_app: Path, products: tuple[DiscoveredProduct, ...], *, root: Path
) -> DiscoveredProduct:
    app = _resolve_existing_directory(keep_app, "kept app")
    product = _product_from_app(app, repo_root=root)
    if product is None:
        raise RetentionError(
            "Kept app must be a physical JTS Terminal Debug or Release product: "
            f"{app}"
        )
    for discovered in products:
        if discovered.removal_root == product.removal_root:
            return discovered
    return product


def _preferred_debug(
    products: list[DiscoveredProduct], root: Path
) -> DiscoveredProduct | None:
    canonical = root / CANONICAL_DEBUG_RELATIVE
    for product in products:
        if product.app == canonical:
            return product
    return _newest(products)


def _preferred_release(products: list[DiscoveredProduct]) -> DiscoveredProduct | None:
    candidates = [
        product
        for product in products
        if product.removal_root != product.app
    ]
    if candidates:
        return _newest(candidates)
    return _newest(products)


def _newest(products: list[DiscoveredProduct]) -> DiscoveredProduct | None:
    if not products:
        return None
    return max(products, key=lambda product: (product.mtime_ns, str(product.app)))


def _resolve_inspector(
    process_inspector: ProcessInspector | None,
) -> ProcessInspector | None:
    if process_inspector is not None:
        return process_inspector
    if sys.platform != "darwin":
        return None
    return DarwinProcessInspector()


def _assert_idle(
    product: DiscoveredProduct, inspector: ProcessInspector | None
) -> None:
    if inspector is None or product.executable is None:
        return
    identities = inspector.identities_for_executable(product.executable)
    if identities:
        pids = ", ".join(str(identity.pid) for identity in identities)
        raise RetentionError(
            "Refusing to remove a running build product "
            f"{product.app} (pids {pids})."
        )


def _assert_safe_to_remove(path: Path, allowed_roots: tuple[Path, ...]) -> None:
    target = _require_absolute_normalized(path, "removal path")
    matching_roots = [root for root in allowed_roots if _is_relative_to(target, root)]
    if not matching_roots:
        raise RetentionError(f"Removal path is outside allowed roots: {target}")
    if target in allowed_roots:
        raise RetentionError(f"Refusing to remove an allowed search root: {target}")
    for root in matching_roots:
        _reject_internal_symlinks(target, root)
    metadata = os.lstat(target)
    if metadata.st_uid != os.getuid() or not stat.S_ISDIR(metadata.st_mode):
        raise RetentionError(
            f"Removal path must be an owner-controlled directory: {target}"
        )


def _remove_tree(path: Path) -> None:
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        current = Path(dirpath)
        if current.is_symlink():
            raise RetentionError(f"Refusing to remove a tree that contains a symlink: {current}")
        for name in (*dirnames, *filenames):
            child = current / name
            if child.is_symlink():
                raise RetentionError(
                    f"Refusing to remove a tree that contains a symlink: {child}"
                )
    shutil.rmtree(path)


def _bundle_identifier(app: Path) -> str | None:
    info = app / "Contents" / "Info.plist"
    if not info.is_file() or info.is_symlink():
        return None
    try:
        with info.open("rb") as stream:
            payload = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    identifier = payload.get("CFBundleIdentifier")
    return identifier if isinstance(identifier, str) else None


def _is_physical_app(app: Path) -> bool:
    return (
        app.name == APP_NAME
        and app.is_absolute()
        and Path(os.path.normpath(app)) == app
        and app.is_dir()
        and not app.is_symlink()
    )


def _is_safe_directory(path: Path) -> bool:
    return (
        path.is_absolute()
        and Path(os.path.normpath(path)) == path
        and path.is_dir()
        and not path.is_symlink()
    )


def _is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return path != root


def _app_for(product: DiscoveredProduct | None) -> Path | None:
    return None if product is None else product.app
