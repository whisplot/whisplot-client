import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

script = Path(__file__).resolve().parents[1] / "build_config.py"
spec = importlib.util.spec_from_file_location("build_config", script)
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class BuildConfigurationTests(unittest.TestCase):
    values = {"DEFAULT_API_BASE_URL": "https://example.com", "DEFAULT_REGISTRATION_CODE": "example-app-code"}

    def test_deployment_selects_only_app_fields(self):
        result = config.from_deployment({
            "api_base_url": "https://example.com/", "registration_code": "example-app-code",
            "api_token": "management-example-must-not-embed", "turn_secret": "turn-example-must-not-embed",
        })
        self.assertEqual(result, self.values)

    def test_explicit_defines_reject_extra_fields(self):
        with self.assertRaises(ValueError):
            config.validate_defines({**self.values, "API_TOKEN": "must-not-embed"})

    def test_rejects_insecure_or_credentialed_service(self):
        for address in ["http://example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?token=x"]:
            with self.subTest(address=address), self.assertRaises(ValueError):
                config.validate_defines({**self.values, "DEFAULT_API_BASE_URL": address})

    def test_missing_or_header_breaking_code_fails(self):
        for code in ["", None, "example\nheader", " padded "]:
            with self.subTest(kind=type(code).__name__), self.assertRaises(ValueError):
                config.validate_defines({**self.values, "DEFAULT_REGISTRATION_CODE": code})

    def test_generated_file_is_private_and_contains_only_allowed_values(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "private.json"
            source.write_text(json.dumps(self.values))
            with patch.dict(os.environ, {"HELLO_MENTOR_DART_DEFINE_FILE": str(source)}):
                generated = Path(config.prepare("android"))
            try:
                self.assertEqual(stat.S_IMODE(generated.stat().st_mode), 0o600)
                self.assertEqual(json.loads(generated.read_text()), self.values)
            finally:
                generated.unlink()

    def test_compiled_binary_must_contain_both_configured_values(self):
        with tempfile.TemporaryDirectory() as directory:
            source, binary = Path(directory) / "private.json", Path(directory) / "binary"
            source.write_text(json.dumps(self.values))
            binary.write_bytes(b"example-app-code")
            with self.assertRaises(ValueError):
                config.verify_embedded(source, binary)
            binary.write_bytes(b"https://example.com\0example-app-code")
            config.verify_embedded(source, binary)


if __name__ == "__main__":
    unittest.main()
