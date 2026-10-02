# Versioned builds

`VERSION`, Info.plist and CHANGELOG.md agree on semantic version. The first preview is 0.1.0. Build identifiers increase independently for subsequent builds.

Published application ZIPs live in `releases/vX.Y.Z/`. Each directory is immutable after publication and contains the Universal ZIP, SHA-256 checksum and build.json recording source_commit, version, target architecture, minimum macOS, CI run, signature status and explicitly unverified runtime checks. The source build commit precedes the commit adding binary files; this avoids a circular source SHA.

To roll back, download a prior version directory, verify its checksum, quit the app and replace its Applications copy. Project schema version is separate from app version; keep a backup before opening projects in newer versions. No automatic updates or project migration is attempted in v0.1.0.

A Git tag may be added when supported and authorized; a versioned directory/manifest does not imply that a tag exists. No GitHub Release or external deployment is required to use a repository-stored ZIP.

Starting with the v0.4.0 source, official builds may use Sparkle updates. See
[AUTO-UPDATES.md](AUTO-UPDATES.md). The existing v0.3.3 binary cannot bootstrap
itself: install a signing-configured v0.4.0 release manually once.

The release workflow requires an increasing semantic VERSION and integer
CFBundleVersion (v0.4.0 starts at build 10). It never overwrites a published
directory. It prepares an archive commit and a signed-feed commit locally, then
publishes both in one non-forced fast-forward push. Feed download URLs pin the
archive commit, not main. A concurrent change to main aborts publication.

Application version and project schema remain independent. This update keeps
schema 1 and performs no migration. Retain old ZIPs for manual rollback; there
is no automatic downgrade or crash recovery installation.
