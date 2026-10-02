#!/usr/bin/env python3
"""Verify repository-stored release bytes without extracting or executing them."""
import hashlib
import json
import pathlib
import plistlib
import re
import struct
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
for manifest_file in sorted((root / 'releases').glob('v*/build.json')):
    manifest = json.loads(manifest_file.read_text())
    name = manifest['archive']
    assert pathlib.Path(name).name == name
    assert re.fullmatch(r'[0-9a-f]{40}', manifest['source_commit'])
    path = manifest_file.parent / name
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    assert digest == manifest['sha256']
    assert len(data) == manifest['bytes']
    assert (manifest_file.parent / (name + '.sha256')).read_text().strip() == digest + '  ' + name
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        executable = archive.getinfo('Point & Tell.app/Contents/MacOS/PointAndTell')
        assert (executable.external_attr >> 16) & 0o111
        plist = plistlib.loads(archive.read('Point & Tell.app/Contents/Info.plist'))
        assert plist['CFBundleShortVersionString'] == manifest['version']
        assert plist['LSMinimumSystemVersion'] == '11.0'
        binary = archive.read(executable)
        magic, count = struct.unpack_from('>II', binary)
        assert magic == 0xcafebabe and count == 2
        cpus = set()
        for index in range(count):
            cpu, subtype, offset, size, align = struct.unpack_from('>IIIII', binary, 8 + index * 20)
            cpus.add(cpu)
            part = memoryview(binary)[offset:offset + size]
            assert struct.unpack_from('<I', part)[0] == 0xfeedfacf
            commands = struct.unpack_from('<I', part, 16)[0]
            cursor, minimum_checked, signed = 32, False, False
            for _ in range(commands):
                command, length = struct.unpack_from('<II', part, cursor)
                assert length >= 8 and cursor + length <= len(part)
                if command == 0x32:
                    platform, minimum, sdk, tools = struct.unpack_from('<IIII', part, cursor + 8)
                    assert platform == 1 and minimum == 0x000b0000
                    minimum_checked = True
                if command == 0x1d:
                    signed = True
                cursor += length
            assert minimum_checked and signed
        assert cpus == {0x1000007, 0x100000c}
    print(f'Verified {path.relative_to(root)}: {len(data)} bytes, Universal, macOS 11.0, SHA-256 {digest}')
