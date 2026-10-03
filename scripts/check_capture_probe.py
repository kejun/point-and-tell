#!/usr/bin/env python3
"""Keep probe evidence intact; apply only recorded, source-pinned acceptance."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent
INPUTS = ("Sources", "Resources", "Package.swift", "Package.resolved", "VERSION",
          "scripts/build-app.sh", "scripts/sparkle-path.py")


def decision(report, exit_code, acceptance, context, identities):
    if exit_code == 0 and report.get("status") == "passed":
        return "passed"
    if exit_code == 77 and report.get("status") == "unavailable":
        return "unavailable"
    allowed = (
        acceptance is not None
        and exit_code == 1 and report.get("status") == "failed"
        and report.get("detail") == acceptance["probe_failure"]
        and not report.get("captureError")
        and context["arch"] == acceptance["architecture"] == "x86_64"
        and context["version"] == acceptance["version"] == "0.5.1"
        and context["build"] == acceptance["build"] == "13"
        and context["ref"] == "refs/heads/main"
        and context["event"] in ("push", "workflow_dispatch")
        and set(identities) == set(INPUTS)
        and identities == acceptance["git_objects"]
    )
    if allowed:
        return "accepted-on-device"
    raise ValueError("Capture probe failed without matching device acceptance")


def source_identities(root):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, text=True).strip()
    if git("status", "--porcelain", "--untracked-files=all", "--", *INPUTS):
        raise ValueError("App inputs differ from the committed, device-tested source")
    return {path: git("rev-parse", "HEAD:" + path) for path in INPUTS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("exit_code", type=int)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    version = (ROOT / "VERSION").read_text().strip()
    info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    path = ROOT / "docs" / f"release-acceptance-{version}.json"
    acceptance = json.loads(path.read_text()) if path.is_file() else None
    context = {"arch": platform.machine(), "version": version, "build": info["CFBundleVersion"],
               "ref": os.environ.get("GITHUB_REF"), "event": os.environ.get("GITHUB_EVENT_NAME")}
    identities = source_identities(ROOT) if args.exit_code == 1 and acceptance else {}
    result = decision(report, args.exit_code, acceptance, context, identities)
    if result == "accepted-on-device":
        message = ("0.5.1 Intel device acceptance applies to the unchanged app inputs. "
                   "The CI probe still FAILED: paused magenta screen was written into MOV. "
                   "Evidence is retained; this is not a probe pass. See docs/PAUSE-RECORDING.md.")
        print("::warning::" + message)
    elif result == "unavailable":
        message = "Native capture unavailable on this runner; not verified and not passed."
        print("::notice::" + message)
    else:
        message = "Native capture pause probe passed."
        print(message)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as stream:
            stream.write(f"\n### Capture pause: {result}\n\n{message}\n")


if __name__ == "__main__":
    main()
