#!/usr/bin/env python3
"""Locate the checksum-verified Sparkle artifact resolved by SwiftPM."""
import argparse
import pathlib

parser = argparse.ArgumentParser()
group = parser.add_mutually_exclusive_group(required=True)
group.add_argument("--framework", action="store_true")
group.add_argument("--tool", choices=["generate_keys", "generate_appcast", "sign_update"])
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent / ".build/artifacts"
matches = list(root.glob("**/Sparkle.xcframework"))
if len(matches) != 1:
    raise SystemExit("Run swift package resolve on macOS first; expected one pinned Sparkle artifact.")
distribution = matches[0].parent
if args.framework:
    frameworks = list(matches[0].glob("macos-*/Sparkle.framework"))
    if len(frameworks) != 1:
        raise SystemExit("Expected one Universal macOS framework.")
    print(frameworks[0])
else:
    tool = distribution / "bin" / args.tool
    if not tool.is_file():
        raise SystemExit("Sparkle distribution tool is missing: " + args.tool)
    print(tool)
