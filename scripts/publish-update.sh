#!/bin/bash
# Invoked only by the trusted main-branch release job, after native verification.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
: "${SOURCE_COMMIT:?}"
: "${SPARKLE_PUBLIC_ED_KEY:?}"
: "${SPARKLE_PRIVATE_ED_KEY:?Configure signing with scripts/setup-updates.sh}"
umask 077
KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$KEY_DIR"' EXIT
# No secrets in process arguments, the repository, artifacts, or printed output.
python3 - "$KEY_DIR/key" <<'PY'
import os, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(os.environ["SPARKLE_PRIVATE_ED_KEY"].strip())
PY
unset SPARKLE_PRIVATE_ED_KEY
DERIVED_KEY="$(swift scripts/update-signing.swift public-key "$KEY_DIR/key")"
[[ "$DERIVED_KEY" == "$SPARKLE_PUBLIC_ED_KEY" ]] || { echo "Signing keys do not match." >&2; exit 1; }
SIGN="$(python3 scripts/sparkle-path.py --tool sign_update)"
GENERATE="$(python3 scripts/sparkle-path.py --tool generate_appcast)"
git fetch origin main
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" && "$(git rev-parse origin/main)" == "$SOURCE_COMMIT" ]] || {
  echo "main advanced; release again from its latest commit." >&2; exit 1;
}
python3 scripts/release_support.py prepare
VERSION="$(tr -d '[:space:]' < VERSION)"
STAGE="dist/update-release"
ARCHIVE="$STAGE/Point-and-Tell-v$VERSION-macOS-universal.zip"
# Validate the original feed before accepting any of its older entries.
if python3 -c 'import xml.etree.ElementTree as E; import sys; sys.exit(0 if E.parse("updates/appcast.xml").findall("./channel/item") else 1)'; then
  "$SIGN" --ed-key-file "$KEY_DIR/key" --verify updates/appcast.xml
fi
# Two local commits, one fast-forward push: clients can never observe the new
# feed without its ancestor containing the immutable, signed archive.
cp -R "$STAGE" "releases/v$VERSION"
git add "releases/v$VERSION"
git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -m "release: archive Point & Tell v$VERSION"
ARCHIVE_COMMIT="$(git rev-parse HEAD)"
"$GENERATE" --ed-key-file "$KEY_DIR/key" --maximum-deltas 0 --maximum-versions 0 \
  --download-url-prefix "https://raw.githubusercontent.com/kejun/point-and-tell/$ARCHIVE_COMMIT/releases/v$VERSION/" \
  --embed-release-notes --output updates/appcast.xml "$STAGE"
"$SIGN" --ed-key-file "$KEY_DIR/key" --verify updates/appcast.xml
SIGNATURE="$(python3 scripts/release_support.py verify-feed --archive-commit "$ARCHIVE_COMMIT")"
swift scripts/update-signing.swift verify "$SPARKLE_PUBLIC_ED_KEY" "$ARCHIVE" "$SIGNATURE"
python3 scripts/verify-releases.py
python3 scripts/release_support.py update-downloads
git add updates/appcast.xml README.md
git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -m "release: publish signed update feed for v$VERSION"
# No force/rebase; a concurrent main change fails safely before publication.
git push origin HEAD:main
echo "Published v$VERSION; source $SOURCE_COMMIT, archive $ARCHIVE_COMMIT"
