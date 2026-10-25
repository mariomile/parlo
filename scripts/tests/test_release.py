#!/usr/bin/env python3
"""Release state-machine regressions: local Git, fake GitHub/build/signing, real Ed25519 verification."""
import json
import base64
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import re
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def run(*args, cwd=None, env=None):
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(0o755)


BUILD = r"""#!/usr/bin/env python3
import os, pathlib, plistlib, re
root = pathlib.Path.cwd()
state = pathlib.Path(os.environ["RELEASE_TEST_STATE"])
with (state / "builds").open("a") as out: out.write("build\n")
config = (root / "project.yml").read_text()
version = re.search(r'CFBundleShortVersionString: "(.*?)"', config)[1]
build = re.search(r'CFBundleVersion: "(.*?)"', config)[1]
info = {"CFBundleIdentifier": "com.mariomiletta.parlo", "CFBundleShortVersionString": version,
        "CFBundleVersion": build, "SUPublicEDKey": (state / "public-key").read_text()}
for path in [root / "App/Info.plist", root / "build/DerivedData/Build/Products/Release/Parlo.app/Contents/Info.plist"]:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(info))
bin_dir = root / "build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
bin_dir.mkdir(parents=True, exist_ok=True)
for name in ["generate_keys", "generate_appcast"]:
    target = bin_dir / name
    target.write_text((state / name).read_text())
    target.chmod(0o755)
"""

GH = r"""#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
state = pathlib.Path(os.environ["RELEASE_TEST_STATE"])
args = sys.argv[1:]
with (state / "gh-log").open("a") as out: out.write(" ".join(args) + "\n")
remote = state / "release.json"
def fail_once(name):
    flag = state / name
    if flag.exists():
        flag.unlink()
        sys.exit(1)
if args[0] == "auth": sys.exit(0)
if args[0] == "api":
    fail_once("api-failure")
    if remote.exists(): print(str(json.loads(remote.read_text())["draft"]).lower())
    sys.exit(0)
action = args[1]
assets = state / "assets"
assets.mkdir(exist_ok=True)
if action == "create":
    assert "--draft" in args and "--verify-tag" in args
    assert not remote.exists()
    remote.write_text(json.dumps({"draft": True}))
    fail_once("create-response-failure")
elif action == "upload":
    assert json.loads(remote.read_text())["draft"]
    for source in args[3:5]:
        shutil.copyfile(source, assets / pathlib.Path(source).name)
        fail_once("upload-failure")
elif action == "download":
    destination = pathlib.Path(args[args.index("--dir") + 1])
    for index, value in enumerate(args):
        if value == "--pattern":
            source = assets / args[index + 1]
            if not source.exists(): sys.exit(1)
            shutil.copyfile(source, destination / source.name)
    if (state / "corrupt-download").exists():
        for file in destination.glob("*.zip"):
            with file.open("ab") as out: out.write(b"corruption")
elif action == "edit":
    assert "--draft=false" in args
    assert len(list(assets.iterdir())) == 2
    remote.write_text(json.dumps({"draft": False}))
else:
    raise AssertionError(args)
"""


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binaries = tempfile.TemporaryDirectory(prefix="parlo-release-binaries-")
        cls.fixture = Path(cls.binaries.name) / "fixture"
        cls.verifier = Path(cls.binaries.name) / "verify"
        for source, target in [(ROOT / "scripts/tests/ReleaseFixtures.swift", cls.fixture),
                               (ROOT / "scripts/verify-appcast.swift", cls.verifier)]:
            result = run("swiftc", str(source), "-o", str(target))
            if result.returncode: raise AssertionError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.binaries.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="parlo-release-test-")
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.state = self.base / "state"
        self.state.mkdir()
        self.repo.mkdir()
        self.env = dict(os.environ, RELEASE_TEST_STATE=str(self.state))
        self.env.pop("GIT_DIR", None)
        self.env.pop("GIT_WORK_TREE", None)
        self.check(run(str(self.fixture), "key", str(self.state)))
        key = (self.state / "public-key").read_text()
        (self.repo / "scripts").mkdir()
        (self.repo / "App").mkdir()
        for name in ["release.sh", "verify-appcast.swift"]:
            shutil.copyfile(ROOT / "scripts" / name, self.repo / "scripts" / name)
        executable(self.repo / "scripts/build.sh", BUILD)
        (self.repo / "project.yml").write_text(
            f'CFBundleShortVersionString: "0.1.0"\nCFBundleVersion: "1"\nSUPublicEDKey: {key}\n')
        (self.repo / "App/Info.plist").write_bytes(plistlib.dumps({}))
        (self.repo / "App/Parlo.entitlements").write_bytes(plistlib.dumps({}))
        (self.repo / ".gitignore").write_text("build/\n")
        self.check(run("git", "init", "--quiet", "-b", "main", str(self.repo)))
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "test: initial fixture")
        self.initial_head = self.git("rev-parse", "HEAD").stdout.strip()
        self.origin = self.base / "origin.git"
        self.check(run("git", "init", "--quiet", "--bare", str(self.origin)))
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "--quiet", "-u", "origin", "main")
        bin_dir = self.base / "bin"
        executable(bin_dir / "gh", GH)
        executable(bin_dir / "codesign", "#!/bin/sh\nexit 0\n")
        executable(bin_dir / "swift", f'#!/bin/sh\nshift\nexec "{self.verifier}" "$@"\n')
        self.env["PATH"] = str(bin_dir) + os.pathsep + self.env["PATH"]
        executable(self.state / "generate_keys", '#!/bin/sh\ncat "$RELEASE_TEST_STATE/public-key"\n')
        executable(self.state / "generate_appcast", f"""#!/usr/bin/env python3
import os, pathlib, re, subprocess, sys
state = pathlib.Path(os.environ["RELEASE_TEST_STATE"])
dist = pathlib.Path(sys.argv[-1])
config = pathlib.Path("project.yml").read_text()
version = re.search(r'CFBundleShortVersionString: "(.*?)"', config)[1]
build = re.search(r'CFBundleVersion: "(.*?)"', config)[1]
mode = (state / "mode").read_text() if (state / "mode").exists() else "valid"
subprocess.run([{str(self.fixture)!r}, "sign", str(state), str(dist / f"Parlo-{{version}}.zip"),
                str(dist / "appcast.xml"), version, build, mode], check=True)
""")

    def tearDown(self):
        self.temp.cleanup()

    def check(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def git(self, *args):
        return self.check(run("git", *args, cwd=self.repo, env=self.env))

    def release(self):
        return run("zsh", "scripts/release.sh", "0.2.0", cwd=self.repo, env=self.env)

    def assert_not_published(self):
        remote = self.state / "release.json"
        self.assertTrue(not remote.exists() or json.loads(remote.read_text())["draft"])

    def advance_origin(self):
        other = self.base / "other-checkout"
        self.check(run("git", "clone", "--quiet", "--branch", "main", str(self.origin), str(other), env=self.env))
        for key, value in [("user.name", "Release Test"), ("user.email", "release-test@example.invalid")]:
            self.check(run("git", "config", key, value, cwd=other, env=self.env))
        (other / "remote-change").write_text("Work after the release attempt\n")
        for args in [("add", "remote-change"), ("commit", "--quiet", "-m", "test: advance remote main"),
                     ("push", "--quiet", "origin", "main")]:
            self.check(run("git", *args, cwd=other, env=self.env))
        return self.check(run("git", "rev-parse", "HEAD", cwd=other, env=self.env)).stdout.strip()

    def test_failed_upload_resumes_when_remote_main_advances(self):
        (self.state / "upload-failure").touch()
        self.assertNotEqual(self.release().returncode, 0)
        committed = self.git("rev-parse", "HEAD").stdout.strip()
        archive = self.repo / "build/release/0.2.0/Parlo-0.2.0.zip"
        original_archive = archive.read_bytes()
        later = self.advance_origin()
        self.check(self.release())
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), committed)
        self.assertEqual(self.git("rev-parse", "v0.2.0").stdout.strip(), committed)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").stdout.split()[0], later)
        self.assertEqual((self.state / "builds").read_text().count("build"), 1)
        self.assertEqual(archive.read_bytes(), original_archive)
        self.assertEqual((self.state / "assets/Parlo-0.2.0.zip").read_bytes(), original_archive)
        self.assertFalse(json.loads((self.state / "release.json").read_text())["draft"])
        uploads = (self.state / "gh-log").read_text().count("release upload")
        self.check(self.release())
        self.assertEqual((self.state / "gh-log").read_text().count("release upload"), uploads)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), committed)

    def test_resume_rejects_divergent_remote_main(self):
        hook = self.origin / "hooks/pre-receive"
        executable(hook, "#!/bin/sh\nexit 1\n")
        self.assertNotEqual(self.release().returncode, 0)
        committed = self.git("rev-parse", "HEAD").stdout.strip()
        hook.unlink()
        later = self.advance_origin()
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("diverged", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), committed)
        self.assertEqual(self.git("ls-remote", "origin", "refs/heads/main").stdout.split()[0], later)
        self.assertEqual((self.state / "builds").read_text().count("build"), 1)
        self.assertFalse((self.state / "release.json").exists())

    def test_fresh_release_fast_forwards_before_building(self):
        later = self.advance_origin()
        self.check(self.release())
        self.assertEqual(self.git("rev-parse", "HEAD^").stdout.strip(), later)
        self.assertTrue((self.repo / "remote-change").exists())

    def test_failed_upload_resumes_and_published_rerun_is_read_only(self):
        (self.state / "upload-failure").touch()
        self.assertNotEqual(self.release().returncode, 0)
        self.assert_not_published()
        committed = self.git("rev-parse", "HEAD").stdout
        self.check(self.release())
        self.assertFalse(json.loads((self.state / "release.json").read_text())["draft"])
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, committed)
        self.assertEqual((self.state / "builds").read_text().count("build"), 1)
        before = (self.state / "gh-log").read_text().count("release upload")
        self.check(self.release())
        self.assertEqual((self.state / "gh-log").read_text().count("release upload"), before)

    def test_failed_push_resumes_same_commit(self):
        hook = self.origin / "hooks/pre-receive"
        executable(hook, "#!/bin/sh\nexit 1\n")
        self.assertNotEqual(self.release().returncode, 0)
        self.assert_not_published()
        committed = self.git("rev-parse", "HEAD").stdout
        hook.unlink()
        self.check(self.release())
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, committed)
        self.assertEqual((self.state / "builds").read_text().count("build"), 1)

    def test_lost_create_response_resumes_existing_draft(self):
        (self.state / "create-response-failure").touch()
        self.assertNotEqual(self.release().returncode, 0)
        self.assert_not_published()
        self.check(self.release())
        self.assertEqual((self.state / "gh-log").read_text().count("release create"), 1)

    def test_missing_and_wrong_signatures_fail_before_commit(self):
        for mode in ["unsigned", "wrong-signature"]:
            with self.subTest(mode=mode):
                (self.state / "mode").write_text(mode)
                result = self.release()
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Release verification failed", result.stderr)
                self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial_head)
                self.assertEqual(self.git("status", "--porcelain").stdout, "")
                self.assertEqual(self.git("tag", "--list").stdout, "")
                self.assert_not_published()

    def test_wrong_key_stops_before_signing(self):
        (self.state / "generate_keys").write_text("#!/bin/sh\necho wrong-key\n")
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Signing key does not match", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial_head)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_corrupt_uploaded_archive_keeps_draft(self):
        (self.state / "corrupt-download").touch()
        self.assertNotEqual(self.release().returncode, 0)
        self.assert_not_published()
        (self.state / "corrupt-download").unlink()
        self.check(self.release())

    def test_api_failure_does_not_mutate_version_or_create_release(self):
        (self.state / "api-failure").touch()
        self.assertNotEqual(self.release().returncode, 0)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertFalse((self.state / "builds").exists())
        self.assertFalse((self.state / "release.json").exists())

    def test_tag_for_other_commit_cannot_be_overwritten(self):
        self.git("tag", "v0.2.0")
        (self.repo / "change").write_text("later commit")
        self.git("add", "change")
        self.git("commit", "--quiet", "-m", "test: advance head")
        self.assertNotEqual(self.release().returncode, 0)
        self.assertFalse((self.state / "builds").exists())
        self.assertEqual(self.git("rev-parse", "v0.2.0").stdout.strip(), self.initial_head)

    def verify_local(self):
        dist = self.repo / "build/release/0.2.0"
        return run(str(self.verifier), str(dist / "appcast.xml"), str(dist / "Parlo-0.2.0.zip"),
                   (self.state / "public-key").read_text(), "0.2.0", "2",
                   "https://github.com/mariomile/parlo/releases/download/v0.2.0/Parlo-0.2.0.zip")

    def test_feed_metadata_and_archive_tampering_rejected(self):
        self.check(self.release())
        dist = self.repo / "build/release/0.2.0"
        feed = dist / "appcast.xml"
        archive = dist / "Parlo-0.2.0.zip"
        original = feed.read_text()
        changes = [(f'length="{archive.stat().st_size}"', 'length="1"'),
                   ("<sparkle:version>2", "<sparkle:version>3"),
                   ("<sparkle:shortVersionString>0.2.0", "<sparkle:shortVersionString>0.3.0"),
                   ("releases/download/v0.2.0/", "releases/download/v9.9.9/")]
        for before, after in changes:
            with self.subTest(field=before):
                feed.write_text(original.replace(before, after))
                self.assertNotEqual(self.verify_local().returncode, 0)
        old_size = archive.stat().st_size
        with archive.open("ab") as out: out.write(b"tampering")
        feed.write_text(original.replace(f'length="{old_size}"', f'length="{archive.stat().st_size}"'))
        result = self.verify_local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature does not match", result.stderr)

    def test_signed_archive_cannot_change_embedded_key(self):
        self.check(self.release())
        dist = self.repo / "build/release/0.2.0"
        archive = dist / "Parlo-0.2.0.zip"
        with zipfile.ZipFile(archive) as source:
            info = plistlib.loads(source.read("Parlo.app/Contents/Info.plist"))
        info["SUPublicEDKey"] = "different-public-key"
        with zipfile.ZipFile(archive, "w") as target:
            target.writestr("Parlo.app/Contents/Info.plist", plistlib.dumps(info))
        self.check(run(str(self.fixture), "sign", str(self.state), str(archive), str(dist / "appcast.xml"),
                       "0.2.0", "2", "valid"))
        result = self.verify_local()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changes the trusted update key", result.stderr)

    def test_signature_interoperates_with_pinned_sparkle(self):
        signer = ROOT / "build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
        if not signer.exists(): self.skipTest("Build once to make pinned Sparkle tools available")
        self.check(self.release())
        dist = self.repo / "build/release/0.2.0"
        archive = dist / "Parlo-0.2.0.zip"
        feed = dist / "appcast.xml"
        key = self.state / "synthetic-seed.txt"
        key.write_bytes(base64.b64encode((self.state / "test-key").read_bytes()))
        original = feed.read_text()
        signature = re.search(r'sparkle:edSignature="([^"]+)"', original)[1]
        self.check(run(str(signer), "--ed-key-file", str(key), "--verify", str(archive), signature))
        signed = self.check(run(str(signer), "--ed-key-file", str(key), "-p", str(archive))).stdout.strip()
        feed.write_text(original.replace(signature, signed))
        self.check(self.verify_local())


if __name__ == "__main__":
    unittest.main()
