#!/bin/bash
# Run once on the maintainer's Mac. The durable private key stays in Keychain.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo "Run this on macOS." >&2; exit 1; }
command -v gh >/dev/null || { echo "Install GitHub CLI and run gh auth login first." >&2; exit 1; }
REPO="kejun/point-and-tell"
[[ "$(gh api "repos/$REPO" --jq .full_name)" == "$REPO" ]]
swift package resolve
KEY_TOOL="$(python3 scripts/sparkle-path.py --tool generate_keys)"
ACCOUNT="io.github.kejun.point-and-tell.updates"
"$KEY_TOOL" --account "$ACCOUNT"
PUBLIC_KEY="$("$KEY_TOOL" --account "$ACCOUNT" -p)"
EXISTING_KEY="$(gh variable list --repo "$REPO" --json name,value --jq '.[] | select(.name == "SPARKLE_PUBLIC_ED_KEY") | .value')"
if [[ -n "$EXISTING_KEY" && "$EXISTING_KEY" != "$PUBLIC_KEY" ]]; then
    echo "The repository uses a different signing key. Restore its Keychain backup; refusing key rotation." >&2
    exit 1
fi
umask 077
KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$KEY_DIR"' EXIT
"$KEY_TOOL" --account "$ACCOUNT" -x "$KEY_DIR/key"
gh secret set SPARKLE_PRIVATE_ED_KEY --repo "$REPO" < "$KEY_DIR/key"
gh variable set SPARKLE_PUBLIC_ED_KEY --repo "$REPO" --body "$PUBLIC_KEY"
echo "Update signing configured. Keep a secure backup of the Sparkle key in your login Keychain."
echo "After merging the updater, run: gh workflow run release.yml --repo $REPO --ref main"
