#!/usr/bin/env python3
"""Inspect a local deb without installing it; record small reproducible results."""
import argparse
import gzip
import hashlib
import io
import json
import lzma
from pathlib import Path
import plistlib
import struct
import subprocess
import tarfile

p = argparse.ArgumentParser()
p.add_argument('package', type=Path)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()

def member(name):
    return subprocess.check_output(['ar', '-p', str(a.package), name])

def unpack(raw):
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as archive:
        result = {}
        for entry in archive.getmembers():
            if entry.isdir():
                continue
            assert entry.isfile(), f'Unexpected archive link/special file: {entry.name}'
            name = entry.name.removeprefix('./')
            assert not name.startswith('/') and '..' not in Path(name).parts
            assert name not in result
            result[name] = archive.extractfile(entry).read()
        return result

control = unpack(gzip.decompress(member('control.tar.gz')))
assert set(control) <= {'control', 'md5sums'}, 'Unexpected maintainer script'
text = control['control'].decode()
assert 'Architecture: iphoneos-arm64\n' in text
assert 'Package: com.local.externalstagemanager16.routing\n' in text
payload = unpack(lzma.decompress(member('data.tar.lzma')))
root = 'var/jb/Library/'
dynamic = root + 'MobileSubstrate/DynamicLibraries/'
options = root + 'Application Support/ExternalStageManager16Routing/Modules.plist'
expected = {dynamic + f'{name}.{ext}' for name in ('ESMSceneRouting', 'ESMBackboardRouting')
            for ext in ('dylib', 'plist')} | {options}
assert set(payload) == expected, set(payload) ^ expected
assert plistlib.loads(payload[dynamic + 'ESMSceneRouting.plist']) == {
    'Filter': {'Bundles': ['com.apple.springboard']}}
assert plistlib.loads(payload[dynamic + 'ESMBackboardRouting.plist']) == {
    'Filter': {'Executables': ['backboardd']}}
assert plistlib.loads(payload[options]) == {
    'SceneMenus': True, 'PointerRouting': True, 'SidebarDisplayScope': True}

def inspect_fat(data, scene):
    magic, count = struct.unpack_from('>II', data)
    assert magic == 0xcafebabe and count == 2
    slices = []
    for i in range(count):
        cpu, sub, offset, size, align = struct.unpack_from('>IIIII', data, 8 + i * 20)
        assert cpu == 0x100000c and (sub & 0xffffff) in (0, 2)
        image = data[offset:offset + size]
        assert len(image) == size and struct.unpack_from('<I', image)[0] == 0xfeedfacf
        commands, command_bytes = struct.unpack_from('<II', image, 16)
        pos = 32
        deps, rpaths, version, signature = [], [], None, False
        for _ in range(commands):
            cmd, length = struct.unpack_from('<II', image, pos)
            assert length >= 8 and pos + length <= 32 + command_bytes <= len(image)
            if cmd in (0xc, 0x80000018, 0x8000001f, 0x8000001c):
                string_offset = struct.unpack_from('<I', image, pos + 8)[0]
                assert 8 <= string_offset < length
                value = image[pos + string_offset:pos + length].split(b'\0', 1)[0].decode()
                (rpaths if cmd == 0x8000001c else deps).append(value)
            if cmd == 0x32:
                platform, minimum, sdk = struct.unpack_from('<III', image, pos + 8)
                assert platform == 2 and minimum == 0x100100
                version = {'minimum': '16.1', 'sdk_hex': hex(sdk)}
            if cmd == 0x1d:
                start, amount = struct.unpack_from('<II', image, pos + 8)
                signature = amount > 0 and start + amount <= len(image)
            pos += length
        assert version and signature and pos == 32 + command_bytes
        assert any('UIKit.framework' in d for d in deps) == scene
        assert any('CydiaSubstrate.framework' in d for d in deps) == scene
        assert all(d.startswith(('/usr/lib/', '/System/Library/Frameworks/', '@rpath/CydiaSubstrate.framework/')) for d in deps)
        slices.append({'arch': 'arm64e' if (sub & 0xffffff) == 2 else 'arm64',
                       'dependencies': deps, 'rpaths': rpaths, 'build': version,
                       'has_code_signature': signature})
    assert {s['arch'] for s in slices} == {'arm64', 'arm64e'}
    return slices

images = {}
for name in ('ESMSceneRouting', 'ESMBackboardRouting'):
    images[name] = inspect_fat(payload[dynamic + name + '.dylib'], name == 'ESMSceneRouting')
result = {'result': 'PASS', 'package': a.package.name,
          'package_sha256': hashlib.sha256(a.package.read_bytes()).hexdigest(),
          'package_bytes': a.package.stat().st_size, 'control': text,
          'payload': {path: {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                      for path, data in sorted(payload.items())},
          'images': images,
          'limitations': ['Static package inspection only; signature presence is not device trust verification.',
                         'No installation, process restart or real-device behavioral validation.']}
a.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
print('package verification: PASS', result['package_sha256'])
