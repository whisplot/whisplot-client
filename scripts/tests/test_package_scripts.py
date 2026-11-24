import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PackagingContractTests(unittest.TestCase):
    def fixture(self, directory, script_name, flutter_exit=0):
        repo = Path(directory)
        (repo / "scripts").mkdir()
        (repo / "apps/mobile").mkdir(parents=True)
        source = Path(__file__).resolve().parents[1]
        shutil.copy2(source / script_name, repo / "scripts" / script_name)
        defines = repo / "private-defines.json"
        defines.write_text("{}")
        (repo / "scripts/build_config.py").write_text(f"print({str(defines)!r})\n")
        flutter = repo / "scripts/flutter.sh"
        flutter.write_text(f"#!/usr/bin/env bash\nexit {flutter_exit}\n")
        flutter.chmod(0o755)
        validator = repo / "scripts/validate_android_package.py"
        validator.write_text("import json, pathlib, sys\npathlib.Path(__file__).with_name('arguments.json').write_text(json.dumps(sys.argv[1:]))\n")
        return repo, defines

    def test_previous_apk_environment_is_forwarded_before_changing_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, defines = self.fixture(directory, "package-android.sh")
            (repo / "previous.apk").touch()
            env = dict(os.environ, HELLO_MENTOR_PREVIOUS_ANDROID_APK="previous.apk")
            subprocess.run(["bash", "scripts/package-android.sh"], cwd=repo, env=env,
                           check=True, capture_output=True, text=True)
            arguments = json.loads((repo / "scripts/arguments.json").read_text())
            self.assertEqual(Path(arguments[arguments.index("--previous-apk") + 1]), (repo / "previous.apk").resolve())
            self.assertFalse(defines.exists())

    def test_failed_build_also_removes_private_define_file(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, defines = self.fixture(directory, "package-android.sh", flutter_exit=7)
            env = dict(os.environ)
            env.pop("HELLO_MENTOR_PREVIOUS_ANDROID_APK", None)
            result = subprocess.run(["bash", "scripts/package-android.sh"], cwd=repo,
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 7)
            self.assertFalse(defines.exists())


if __name__ == "__main__":
    unittest.main()
