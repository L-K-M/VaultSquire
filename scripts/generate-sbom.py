#!/usr/bin/env python3
"""Generate a complete SPDX 2.3 inventory for the current dependency-free app."""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
DEPENDENCY_MANIFEST_NAMES = {
    "Package.swift",
    "Package.resolved",
    "Podfile",
    "Podfile.lock",
    "Cartfile",
    "Cartfile.resolved",
}


def digest(path: pathlib.Path, algorithm: str) -> str:
    value = hashlib.new(algorithm)
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def tracked_source_files() -> list[pathlib.Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    untracked = subprocess.run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    for raw_path in untracked.stdout.split(b"\0"):
        if raw_path and pathlib.Path(os.fsdecode(raw_path)).name in DEPENDENCY_MANIFEST_NAMES:
            raise ValueError(f"untracked dependency manifest: {os.fsdecode(raw_path)}")
    files = []
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        path = ROOT / os.fsdecode(raw_path)
        if path.name in DEPENDENCY_MANIFEST_NAMES:
            raise ValueError(f"unreviewed dependency manifest: {path.relative_to(ROOT)}")
        if path.is_file() and not path.is_symlink():
            files.append(path)
    return sorted(files)


def artifact_files(app: pathlib.Path) -> list[pathlib.Path]:
    nested_code = [
        app / "Contents" / "Frameworks",
        app / "Contents" / "SharedFrameworks",
        app / "Contents" / "PlugIns",
        app / "Contents" / "Plug-ins",
        app / "Contents" / "XPCServices",
        app / "Contents" / "Helpers",
    ]
    if any(path.exists() for path in nested_code):
        raise ValueError("nested code requires a reviewed SBOM dependency adapter")
    symlinks = [path for path in app.rglob("*") if path.is_symlink()]
    if symlinks:
        raise ValueError(f"artifact symlink inventory is not implemented: {symlinks[0]}")
    return sorted(path for path in app.rglob("*") if path.is_file() and not path.is_symlink())


def spdx_file(path: pathlib.Path, name: str, identifier: str) -> dict:
    return {
        "fileName": name,
        "SPDXID": identifier,
        "checksums": [
            {"algorithm": "SHA1", "checksumValue": digest(path, "sha1")},
            {"algorithm": "SHA256", "checksumValue": digest(path, "sha256")},
        ],
        "licenseConcluded": "NOASSERTION",
        "licenseInfoInFiles": ["NOASSERTION"],
        "copyrightText": "NOASSERTION",
    }


def verification_code(paths: list[pathlib.Path]) -> str:
    checksums = sorted(digest(path, "sha1") for path in paths)
    return hashlib.sha1("".join(checksums).encode("ascii")).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    if not args.app.is_dir():
        parser.error(f"application bundle does not exist: {args.app}")
    if not __import__("re").fullmatch(r"(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})", args.version):
        parser.error("version must use X.Y.Z form without leading zeroes")
    if not __import__("re").fullmatch(r"[1-9][0-9]{0,8}", args.build):
        parser.error("build must be a positive integer")
    if not __import__("re").fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("commit must be a full lowercase Git object ID")

    source_paths = tracked_source_files()
    app_paths = artifact_files(args.app)
    app_digest = digest(args.app / "Contents" / "MacOS" / "VaultSquire", "sha256")
    commit_timestamp = int(subprocess.run(
        ["git", "show", "-s", "--format=%ct", args.commit],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip())
    created = datetime.datetime.fromtimestamp(
        commit_timestamp, datetime.timezone.utc
    ).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    source_files = [
        spdx_file(path, f"./source/{path.relative_to(ROOT)}", f"SPDXRef-SourceFile-{index}")
        for index, path in enumerate(source_paths, 1)
    ]
    app_files = [
        spdx_file(path, f"./artifact/{args.app.name}/{path.relative_to(args.app)}", f"SPDXRef-AppFile-{index}")
        for index, path in enumerate(app_paths, 1)
    ]

    relationships = [
        {
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": "SPDXRef-Package-App",
        },
        {
            "spdxElementId": "SPDXRef-Package-App",
            "relationshipType": "GENERATED_FROM",
            "relatedSpdxElement": "SPDXRef-Package-Source",
        },
    ]
    relationships.extend(
        {
            "spdxElementId": "SPDXRef-Package-Source",
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": item["SPDXID"],
        }
        for item in source_files
    )
    relationships.extend(
        {
            "spdxElementId": "SPDXRef-Package-App",
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": item["SPDXID"],
        }
        for item in app_files
    )

    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"VaultSquire-{args.version}-{args.build}",
        "documentNamespace": f"https://github.com/L-K-M/VaultSquire/sbom/{args.commit}/{args.version}/{args.build}/{app_digest}/{verification_code(source_paths)}/{verification_code(app_paths)}",
        "creationInfo": {
            "created": created,
            "creators": ["Tool: VaultSquire-SBOM-Generator-1.0"],
        },
        "documentDescribes": ["SPDXRef-Package-App"],
        "packages": [
            {
                "name": "VaultSquire-source",
                "SPDXID": "SPDXRef-Package-Source",
                "versionInfo": args.version,
                "downloadLocation": f"git+https://github.com/L-K-M/VaultSquire.git@{args.commit}",
                "filesAnalyzed": True,
                "packageVerificationCode": {"packageVerificationCodeValue": verification_code(source_paths)},
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "Apache-2.0",
                "copyrightText": "Copyright 2026 VaultSquire contributors",
                "externalRefs": [{
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": f"pkg:github/L-K-M/VaultSquire@{args.commit}",
                }],
            },
            {
                "name": "VaultSquire.app",
                "SPDXID": "SPDXRef-Package-App",
                "versionInfo": f"{args.version}+{args.build}",
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": True,
                "packageVerificationCode": {"packageVerificationCodeValue": verification_code(app_paths)},
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "Apache-2.0",
                "copyrightText": "Copyright 2026 VaultSquire contributors",
                "comment": "No third-party application package is adopted. Apple system libraries are runtime platform components and are not redistributed in this bundle.",
            },
        ],
        "files": source_files + app_files,
        "relationships": relationships,
    }
    args.output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
