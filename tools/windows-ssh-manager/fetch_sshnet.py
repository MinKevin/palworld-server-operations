#!/usr/bin/env python3
"""Fetch the pinned official SSH.NET dependency closure for the Admin EXE.

This is a maintainer-only build step. Runtime clients never download code.
"""

from __future__ import annotations

import hashlib
import io
import json
import re
import shutil
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


ROOT_PACKAGE = ("SSH.NET", "2025.1.0")
PACKAGE_SHA256_PINS = {
    ("SSH.NET", "2025.1.0"): "beda6f13907e231a0c92af4240c7a1a11e5946d8a16874385728669242232fdf",
    ("BouncyCastle.Cryptography", "2.6.2"): "623936fb1fd171579c706390390711282898cf2c759a5167852e5ab82208f8cb",
    ("Microsoft.Extensions.Logging.Abstractions", "8.0.3"): "e4c498d5a13051b4577a148f1d8c3470167215c507e2392069b75dc61322bb74",
    ("System.Formats.Asn1", "8.0.2"): "4d5a09377f5cb02cdad97b732c4278cd38acf420b91453793aabc8c213e438df",
    ("Microsoft.Extensions.DependencyInjection.Abstractions", "8.0.2"): "51f2df1100245f10da54f0bb7e813f277155117777d4fbbab902214e27372606",
    ("System.Buffers", "4.5.1"): "c30b3dd2c7e2f4cee4b823d692fd42118309b42ab1f5007f923d329a5b0d6b12",
    ("System.Memory", "4.5.5"): "10f43da352a29fb2b3188e4edd4dcf5100194c8b526e4f61fe2e2b5623775a22",
    ("System.ValueTuple", "4.5.0"): "9e21fa9767d4e76bc0cee065c1d40cc34384a114bfec4d70e6c981168a926802",
    ("Microsoft.Bcl.AsyncInterfaces", "8.0.0"): "f5a5a68b03092ab2abf68843d4a4aea25dfbcbe8dd0f13c625cb779b6fc1927c",
    ("System.Threading.Tasks.Extensions", "4.5.4"): "a304a963cc0796c5179f9c6b7d8022bbce3b2fa7c029eb6196f631f7b462d678",
    ("System.Numerics.Vectors", "4.5.0"): "a9d49320581fda1b4f4be6212c68c01a22cdf228026099c20a8eabefcf90f9cf",
    ("System.Runtime.CompilerServices.Unsafe", "4.5.3"): "96764c52a44ee1161151e48ef07489f72047a851cb55b99e9f01d6908536d1a9",
}
BASE_URL = "https://api.nuget.org/v3-flatcontainer"
OUTPUT_DIR = Path(__file__).resolve().parent / "vendor"
FRAMEWORK_ORDER = (
    "net462",
    "net461",
    "net46",
    "net452",
    "net451",
    "net45",
    "net40",
    "netstandard2.0",
)
LEGAL_DOCUMENT_NAMES = {
    "license",
    "license.txt",
    "license.md",
    "notice",
    "notice.txt",
    "third-party-notices.txt",
    "third_party_notices.txt",
}
MIT_PERMISSION_TEXT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


def minimum_version(value: str) -> str:
    value = value.strip()
    if value.startswith("[") and value.endswith("]") and "," not in value:
        return value[1:-1]
    if value[:1] in "[(":
        value = value[1:]
    candidate = value.split(",", 1)[0].strip()
    if not candidate:
        raise ValueError(f"dependency has no supported minimum version: {value}")
    return candidate


def package_url(package: str, version: str) -> str:
    package_lower = package.lower()
    version_lower = version.lower()
    return f"{BASE_URL}/{package_lower}/{version_lower}/{package_lower}.{version_lower}.nupkg"


def download(package: str, version: str) -> bytes:
    request = urllib.request.Request(
        package_url(package, version),
        headers={"User-Agent": "palworld-server-admin-build/1"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def nuspec_root(archive: zipfile.ZipFile) -> ET.Element:
    names = [name for name in archive.namelist() if name.lower().endswith(".nuspec")]
    if len(names) != 1:
        raise ValueError(f"expected exactly one nuspec, found: {names}")
    return ET.fromstring(archive.read(names[0]))


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def package_dependencies(root: ET.Element) -> list[tuple[str, str]]:
    dependencies = next(
        (element for element in root.iter() if local_name(element.tag) == "dependencies"),
        None,
    )
    if dependencies is None:
        return []
    groups = [item for item in dependencies if local_name(item.tag) == "group"]
    selected: ET.Element | None = None
    for group in groups:
        normalized = re.sub(r"[^a-z0-9]", "", group.attrib.get("targetFramework", "").lower())
        if normalized in {"netframework462", "net462"}:
            selected = group
            break
    if selected is None and groups:
        for wanted in FRAMEWORK_ORDER:
            selected = next(
                (
                    group
                    for group in groups
                    if re.sub(
                        r"[^a-z0-9]",
                        "",
                        group.attrib.get("targetFramework", "").lower(),
                    )
                    in {wanted, wanted.replace("net", "netframework", 1)}
                ),
                None,
            )
            if selected is not None:
                break
    source = list(selected) if selected is not None else list(dependencies)
    result: list[tuple[str, str]] = []
    for item in source:
        if local_name(item.tag) != "dependency":
            continue
        result.append((item.attrib["id"], minimum_version(item.attrib["version"])))
    return result


def package_license(root: ET.Element) -> str:
    metadata = next(
        (element for element in root.iter() if local_name(element.tag) == "metadata"),
        None,
    )
    if metadata is None:
        return "UNKNOWN"
    license_element = next(
        (element for element in metadata if local_name(element.tag) == "license"),
        None,
    )
    if license_element is not None and license_element.text:
        value = license_element.text.strip()
        if license_element.attrib.get("type", "").lower() == "expression":
            return value
        return f"file:{value}"
    license_url = next(
        (element for element in metadata if local_name(element.tag) == "licenseUrl"),
        None,
    )
    if license_url is not None and license_url.text:
        return license_url.text.strip()
    return "UNKNOWN"


def package_metadata_value(root: ET.Element, name: str) -> str:
    metadata = next(
        (element for element in root.iter() if local_name(element.tag) == "metadata"),
        None,
    )
    if metadata is None:
        return ""
    element = next(
        (item for item in metadata if local_name(item.tag) == name),
        None,
    )
    return element.text.strip() if element is not None and element.text else ""


def legal_documents(archive: zipfile.ZipFile) -> list[tuple[str, bytes, str]]:
    documents: list[tuple[str, bytes, str]] = []
    for member in archive.namelist():
        if Path(member).name.lower() not in LEGAL_DOCUMENT_NAMES:
            continue
        payload = archive.read(member)
        try:
            text = payload.decode("utf-8-sig")
        except UnicodeDecodeError as error:
            raise ValueError(f"legal document is not UTF-8: {member}") from error
        normalized = "\n".join(
            line.rstrip() for line in text.replace("\r\n", "\n").split("\n")
        )
        documents.append((member, payload, normalized))
    return documents


def select_framework_dlls(archive: zipfile.ZipFile) -> list[str]:
    names = archive.namelist()
    for framework in FRAMEWORK_ORDER:
        prefix = f"lib/{framework}/".lower()
        selected = [
            name
            for name in names
            if name.lower().startswith(prefix)
            and name.lower().endswith(".dll")
            and "/ref/" not in name.lower()
        ]
        if selected:
            return selected
    raise ValueError("package has no compatible .NET Framework assembly")


def main() -> int:
    staging = OUTPUT_DIR.with_name(OUTPUT_DIR.name + ".building")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    queue = [ROOT_PACKAGE]
    handled: dict[str, str] = {}
    records: list[dict[str, object]] = []
    legal_payloads: dict[str, dict[str, object]] = {}
    while queue:
        package, version = queue.pop(0)
        key = package.lower()
        if key in handled:
            if handled[key] != version:
                raise ValueError(
                    f"conflicting package versions for {package}: {handled[key]} and {version}"
                )
            continue
        payload = download(package, version)
        package_hash = hashlib.sha256(payload).hexdigest()
        expected_package_hash = PACKAGE_SHA256_PINS.get((package, version))
        if expected_package_hash is None:
            raise ValueError(f"NuGet package is not explicitly pinned: {package} {version}")
        if package_hash != expected_package_hash:
            raise ValueError(
                f"NuGet package hash mismatch for {package} {version}: "
                f"expected {expected_package_hash}, received {package_hash}"
            )
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            root = nuspec_root(archive)
            dependencies = package_dependencies(root)
            license_value = package_license(root)
            authors = package_metadata_value(root, "authors")
            copyright_value = package_metadata_value(root, "copyright")
            document_records: list[dict[str, str]] = []
            documents = legal_documents(archive)
            if not documents and license_value == "MIT":
                if not copyright_value:
                    raise ValueError(
                        f"{package} declares MIT but has no legal file or copyright metadata"
                    )
                synthetic = (
                    f"MIT License\n\n{copyright_value}\n\n{MIT_PERMISSION_TEXT}"
                ).encode("utf-8")
                documents = [("package metadata + SPDX MIT text", synthetic, synthetic.decode("utf-8"))]
            if not documents:
                raise ValueError(f"{package} contains no distributable legal notice")
            for member, source_payload, text in documents:
                document_hash = hashlib.sha256(source_payload).hexdigest()
                document_records.append({"file": member, "sha256": document_hash})
                legal = legal_payloads.setdefault(
                    document_hash,
                    {"text": text, "packages": [], "files": []},
                )
                if legal["text"] != text:
                    raise ValueError(f"legal document hash collision: {member}")
                legal["packages"].append(f"{package} {version}")
                legal["files"].append(member)
            assemblies: list[dict[str, object]] = []
            for member in select_framework_dlls(archive):
                content = archive.read(member)
                destination = staging / Path(member).name
                if destination.exists() and destination.read_bytes() != content:
                    raise ValueError(f"duplicate assembly name with different content: {destination.name}")
                destination.write_bytes(content)
                assemblies.append(
                    {
                        "file": destination.name,
                        "sha256": hashlib.sha256(content).hexdigest(),
                        "size": len(content),
                    }
                )
        handled[key] = version
        queue.extend(dependencies)
        records.append(
            {
                "id": package,
                "version": version,
                "source": package_url(package, version),
                "package_sha256": package_hash,
                "license": license_value,
                "authors": authors,
                "copyright": copyright_value,
                "legal_documents": document_records,
                "dependencies": [
                    {"id": dependency, "version": dependency_version}
                    for dependency, dependency_version in dependencies
                ],
                "assemblies": assemblies,
            }
        )
        print(f"Fetched {package} {version}")
    (staging / "packages.lock.json").write_text(
        json.dumps({"target": "net462", "packages": records}, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    package_lines = []
    for record in records:
        package_lines.extend(
            (
                f"- {record['id']} {record['version']}",
                f"  License: {record['license']}",
                f"  Authors: {record['authors']}",
                f"  Copyright: {record['copyright']}",
                f"  Source package: {record['source']}",
            )
        )
    notice_sections = []
    for document_hash, legal in legal_payloads.items():
        packages = ", ".join(dict.fromkeys(legal["packages"]))
        files = ", ".join(dict.fromkeys(legal["files"]))
        text = str(legal["text"]).rstrip() + "\n"
        notice_sections.append(
            "=" * 79
            + f"\nPackages: {packages}\n"
            + f"Package document(s): {files}\n"
            + f"Source package document SHA-256: {document_hash}\n"
            + "=" * 79
            + "\n\n"
            + text
        )
    (staging / "THIRD_PARTY.txt").write_text(
        "Third-party packages embedded in Palworld Server Operations - Admin\n\n"
        + "\n".join(package_lines)
        + "\n\nThe following license and notice texts were extracted from the pinned "
        + "NuGet packages. When a package declared SPDX MIT without shipping a separate "
        + "file, the exact package copyright metadata is combined with the standard MIT "
        + "text. Duplicate package documents are included once and list every package "
        + "to which they apply.\n\n"
        + "\n".join(notice_sections),
        encoding="utf-8",
        newline="\n",
    )
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)
    staging.replace(OUTPUT_DIR)
    print(OUTPUT_DIR)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
