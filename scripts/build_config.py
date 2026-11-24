#!/usr/bin/env python3
"""Prepare private Flutter build defines without logging their values."""

import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
from urllib.parse import urlsplit

DEFINE_KEYS = {"DEFAULT_API_BASE_URL", "DEFAULT_REGISTRATION_CODE"}


def load_json(path):
    try:
        value = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ValueError("Cannot read private build configuration JSON.") from None
    if not isinstance(value, dict):
        raise ValueError("Private build configuration must be a JSON object.")
    return value


def validate_defines(value):
    if set(value) != DEFINE_KEYS:
        raise ValueError("Define JSON must contain only DEFAULT_API_BASE_URL and DEFAULT_REGISTRATION_CODE.")
    address, code = value["DEFAULT_API_BASE_URL"], value["DEFAULT_REGISTRATION_CODE"]
    if not isinstance(address, str) or not isinstance(code, str):
        raise ValueError("The default service and app access code must be strings.")
    try:
        parsed = urlsplit(address)
        valid = (parsed.scheme == "https" and parsed.hostname and not parsed.username
                 and not parsed.password and not parsed.query and not parsed.fragment
                 and parsed.path in ("", "/") and parsed.port != 0)
    except ValueError:
        valid = False
    if not valid or any(char.isspace() for char in address):
        raise ValueError("The release default service must be an HTTPS origin without credentials or a path.")
    if (not code or code != code.strip() or len(code) > 1024
            or any(ord(char) < 32 or ord(char) == 127 for char in code)):
        raise ValueError("A nonempty app access code is required for this automatic-connect build.")
    return {"DEFAULT_API_BASE_URL": address.rstrip("/"), "DEFAULT_REGISTRATION_CODE": code}


def from_deployment(value):
    # Deliberately select two app fields. Management tokens, accounts and TURN
    # credentials must never become Flutter build defines.
    return validate_defines({
        "DEFAULT_API_BASE_URL": value.get("api_base_url"),
        "DEFAULT_REGISTRATION_CODE": value.get("registration_code"),
    })


def prepare(platform):
    repo = Path(__file__).resolve().parent.parent
    define_source = os.environ.get("HELLO_MENTOR_DART_DEFINE_FILE")
    deployment_source = os.environ.get("HELLO_MENTOR_DEPLOYMENT_FILE")
    if define_source:
        values = validate_defines(load_json(define_source))
    else:
        source = Path(deployment_source).expanduser() if deployment_source else repo / ".tooling/deployment.json"
        if not source.is_file():
            raise ValueError("Provide HELLO_MENTOR_DART_DEFINE_FILE or HELLO_MENTOR_DEPLOYMENT_FILE; no private configuration was found.")
        values = from_deployment(load_json(source))
    directory = repo / ".tooling/build-defines"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=f"{platform}-", suffix=".json",
                                     dir=directory, delete=False) as output:
        os.chmod(output.name, 0o600)
        json.dump(values, output, ensure_ascii=False)
        output.write("\n")
        return output.name


def verify_embedded(define_file, binary):
    values = validate_defines(load_json(define_file))
    data = Path(binary).read_bytes()
    for name in sorted(DEFINE_KEYS):
        if not any(values[name].encode(encoding) in data for encoding in ("utf-8", "utf-16-le", "utf-16-be")):
            raise ValueError(f"The compiled app is missing the expected {name}; refusing to package it.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    make = actions.add_parser("prepare")
    make.add_argument("--platform", choices=("android", "macos"), required=True)
    check = actions.add_parser("verify")
    check.add_argument("--define-file", required=True)
    check.add_argument("--binary", required=True)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            print(prepare(args.platform))  # Only the private file path, never its contents.
        else:
            verify_embedded(args.define_file, args.binary)
            print("Verified the embedded default service and app access code.")
    except (ValueError, OSError) as error:
        # Our validation errors contain field names only, never configuration values.
        print(str(error) if isinstance(error, ValueError) else "Build configuration file operation failed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
