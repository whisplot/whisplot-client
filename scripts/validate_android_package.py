#!/usr/bin/env python3
"""Verify the ARM64 release and copy only a valid APK to the output directory."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

from build_config import verify_embedded


def android_tools(app):
    sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if not sdk:
        properties = (app / "android/local.properties").read_text(encoding="utf-8")
        match = re.search(r"^sdk\.dir=(.+)$", properties, re.MULTILINE)
        if match:
            sdk = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), match.group(1))
            sdk = sdk.replace("\\:", ":").replace("\\ ", " ").replace("\\\\", "\\")
    if not sdk:
        raise ValueError("Set ANDROID_SDK_ROOT or configure the Android SDK before packaging.")
    candidates = [p for p in (Path(sdk) / "build-tools").iterdir()
                  if (p / "aapt").is_file() and (p / "apksigner").is_file()]
    if not candidates:
        raise ValueError("Android build-tools with aapt and apksigner are required.")
    return max(candidates, key=lambda p: tuple(int(n) for n in re.findall(r"\d+", p.name)))


def inspect(apk, tools):
    try:
        signature = subprocess.check_output([str(tools / "apksigner"), "verify", "--print-certs", str(apk)],
                                            text=True, stderr=subprocess.DEVNULL)
        badging = subprocess.check_output([str(tools / "aapt"), "dump", "badging", str(apk)],
                                          text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        raise ValueError("APK signature or manifest verification failed.") from None
    identity = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    certs = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)", signature)
    if not identity or len(certs) != 1:
        raise ValueError("APK package identity or its single signing certificate could not be verified.")
    min_sdk = re.search(r"^sdkVersion:'(\d+)'", badging, re.MULTILINE)
    target_sdk = re.search(r"^targetSdkVersion:'(\d+)'", badging, re.MULTILINE)
    with zipfile.ZipFile(apk) as archive:
        abis = sorted({name.split("/")[1] for name in archive.namelist()
                       if name.startswith("lib/") and name.endswith(".so")})
    return {"package": identity[1], "version_code": int(identity[2]), "version_name": identity[3],
            "min_sdk": int(min_sdk[1]) if min_sdk else None,
            "target_sdk": int(target_sdk[1]) if target_sdk else None,
            "debuggable": "application-debuggable" in badging,
            "signing_certificate_sha256": certs[0].lower(), "abis": abis}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True)
    parser.add_argument("--define-file", required=True)
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--previous-apk")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    app = repo / "apps/mobile"
    try:
        apk = Path(args.apk)
        tools = android_tools(app)
        metadata = inspect(apk, tools)
        match = re.search(r"^version:\s*([\w.\-]+)\+(\d+)\s*$", (app / "pubspec.yaml").read_text(), re.MULTILINE)
        if not match:
            raise ValueError("A versionName+buildNumber is required in pubspec.yaml.")
        # Flutter's ARM64 split APK adds 2000 to the pubspec build number.
        if metadata["version_name"] != match[1] or metadata["version_code"] != 2000 + int(match[2]):
            raise ValueError("APK version differs from the expected ARM64 split version.")
        if metadata["package"] != "com.nearlink.chat" or metadata["abis"] != ["arm64-v8a"]:
            raise ValueError("Unexpected package identity or native architecture.")
        if metadata["min_sdk"] != 24 or metadata["debuggable"]:
            raise ValueError("Expected a non-debuggable release supporting Android API 24 and later.")
        if args.previous_apk:
            previous = inspect(Path(args.previous_apk), tools)
            if previous["package"] != metadata["package"] or previous["signing_certificate_sha256"] != metadata["signing_certificate_sha256"]:
                raise ValueError("New APK is not signed with the previous app's certificate; refusing an incompatible update.")
            if metadata["version_code"] <= previous["version_code"]:
                raise ValueError("The Android update must have a higher actual versionCode.")
            metadata["previous_version_code"] = previous["version_code"]
            metadata["same_certificate_as_previous_apk"] = True
        with zipfile.ZipFile(apk) as archive, tempfile.TemporaryDirectory() as directory:
            aot = Path(directory) / "libapp.so"
            aot.write_bytes(archive.read("lib/arm64-v8a/libapp.so"))
            verify_embedded(args.define_file, aot)
        metadata["embedded_default_service_verified"] = True
        metadata["embedded_app_access_code_verified"] = True
        metadata["signature_verification_passed"] = True
        metadata["sha256"] = hashlib.sha256(apk.read_bytes()).hexdigest()
        metadata["bytes"] = apk.stat().st_size
        output = Path(args.output_directory)
        output.mkdir(parents=True, exist_ok=True)
        target = output / f'whisplot-{metadata["version_name"]}-android-arm64.apk'
        shutil.copy2(apk, target)
        target.with_suffix(".metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        print(f"Packaged Android ARM64, versionCode {metadata['version_code']}.")
        print(target)
        print(f"SHA-256: {metadata['sha256']}")
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(str(error) if isinstance(error, ValueError) else "Android package verification could not complete.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
