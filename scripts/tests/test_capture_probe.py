import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_capture_probe import INPUTS, ROOT, decision, source_identities


class CaptureProbeGateTests(unittest.TestCase):
    def setUp(self):
        self.acceptance = json.loads((ROOT / "docs/release-acceptance-0.5.1.json").read_text())
        self.report = {"status": "failed", "detail": self.acceptance["probe_failure"], "captureError": ""}
        self.context = {"arch": "x86_64", "version": "0.5.1", "build": "13",
                        "ref": "refs/heads/main", "event": "workflow_dispatch"}
        self.identities = copy.deepcopy(self.acceptance["git_objects"])

    def check(self, code=1, acceptance=True):
        return decision(self.report, code, self.acceptance if acceptance else None,
                        self.context, self.identities)

    def test_known_device_acceptance_preserves_failed_evidence(self):
        before = copy.deepcopy(self.report)
        self.assertEqual(self.check(), "accepted-on-device")
        self.assertEqual(self.report, before)
        self.context["event"] = "push"
        self.assertEqual(self.check(), "accepted-on-device")

    def use_release_approval(self):
        self.acceptance = json.loads((ROOT / "docs/release-acceptance-0.5.2.json").read_text())
        self.context.update(version="0.5.2", build="14")
        self.identities = copy.deepcopy(self.acceptance["git_objects"])

    def test_release_approval_does_not_claim_device_or_probe_success(self):
        self.use_release_approval()
        before = copy.deepcopy(self.report)
        self.assertEqual(self.check(), "accepted-for-release")
        self.assertEqual(self.report, before)
        self.context["event"] = "push"
        self.assertEqual(self.check(), "accepted-for-release")

    def test_release_approval_requires_its_own_explicit_scope(self):
        self.use_release_approval()
        for key, value in [("arch", "arm64"), ("version", "0.5.3"), ("build", "15"),
                           ("ref", "refs/heads/topic"), ("event", "pull_request"), ("event", "schedule")]:
            with self.subTest(key=key, value=value):
                old = self.context[key]
                self.context[key] = value
                with self.assertRaises(ValueError):
                    self.check()
                self.context[key] = old
        del self.acceptance["basis_type"]
        with self.assertRaises(ValueError):
            self.check()
        self.use_release_approval()
        self.context.update(version="0.5.3", build="15")
        self.acceptance.update(version="0.5.3", build="15")
        with self.assertRaises(ValueError):
            self.check()

    def test_release_approval_rejects_new_errors_and_changed_app_inputs(self):
        self.use_release_approval()
        with self.assertRaises(ValueError):
            self.check(acceptance=False)
        for code in (0, 77, 139):
            with self.assertRaises(ValueError):
                self.check(code)
        for key, value in [("detail", "Invalid media PTS"), ("status", "unavailable"),
                           ("captureError", "Microphone disconnected")]:
            old = self.report[key]
            self.report[key] = value
            with self.assertRaises(ValueError):
                self.check()
            self.report[key] = old
        for path in INPUTS:
            with self.subTest(path=path):
                old = self.identities[path]
                self.identities[path] = "0" * 40
                with self.assertRaises(ValueError):
                    self.check()
                self.identities[path] = old
        del self.identities["Sources"]
        with self.assertRaises(ValueError):
            self.check()

    def test_future_versions_other_architectures_and_prs_fail_closed(self):
        for key, value in [("arch", "arm64"), ("version", "0.5.2"), ("build", "14"),
                           ("ref", "refs/heads/topic"), ("event", "pull_request"), ("event", "schedule")]:
            with self.subTest(key=key, value=value):
                old = self.context[key]
                self.context[key] = value
                with self.assertRaises(ValueError):
                    self.check()
                self.context[key] = old

    def test_other_failures_missing_acceptance_and_crashes_still_block(self):
        with self.assertRaises(ValueError):
            self.check(acceptance=False)
        for code in (0, 77, 139):
            with self.assertRaises(ValueError):
                self.check(code)
        for key, value in [("detail", "Invalid media PTS"), ("status", "unavailable"),
                           ("captureError", "Microphone disconnected")]:
            old = self.report[key]
            self.report[key] = value
            with self.assertRaises(ValueError):
                self.check()
            self.report[key] = old

    def test_any_app_or_packaging_change_invalidates_acceptance(self):
        for path in INPUTS:
            with self.subTest(path=path):
                old = self.identities[path]
                self.identities[path] = "0" * 40
                with self.assertRaises(ValueError):
                    self.check()
                self.identities[path] = old
        del self.identities["Sources"]
        with self.assertRaises(ValueError):
            self.check()

    def test_passed_and_unavailable_require_matching_exit_codes(self):
        for status, code in [("passed", 0), ("unavailable", 77)]:
            self.report["status"] = status
            self.assertEqual(self.check(code, acceptance=False), status)
            with self.assertRaises(ValueError):
                self.check(1, acceptance=False)

    def test_source_identity_rejects_modified_and_new_runtime_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL)
            git("init", "-q")
            for path in INPUTS:
                file = root / path / "fixture" if path in ("Sources", "Resources") else root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("original")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
            self.assertEqual(set(source_identities(root)), set(INPUTS))
            (root / "Sources/extra.swift").write_text("new code")
            with self.assertRaises(ValueError):
                source_identities(root)
            (root / "Sources/extra.swift").unlink()
            (root / "Sources/fixture").write_text("changed")
            with self.assertRaises(ValueError):
                source_identities(root)
