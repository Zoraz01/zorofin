#!/usr/bin/env python3
"""Copy a release TPK into the public download source after package-boundary checks."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET
from zipfile import ZipFile


def inspect(package):
    with ZipFile(package) as archive:
        assert archive.testzip() is None, 'Corrupt TPK'
        names = archive.namelist()
        assert len(set(names)) == len(names), 'Duplicate package members'
        for name in names:
            path = Path(name)
            assert not path.is_absolute() and '..' not in path.parts, 'Unsafe package path'
            assert not name.endswith(('.p12', '.pfx', '.key', '.pdb')), 'Private key or debug symbols in package'
            assert path.name != '.env', 'Environment file in package'
            data = archive.read(name)
            assert b'-----BEGIN PRIVATE KEY' not in data and b'-----BEGIN RSA PRIVATE KEY' not in data, 'Private key in package'
        manifest = ET.fromstring(archive.read('tizen-manifest.xml'))
        ns = {'t': 'http://tizen.org/ns/packages'}
        assert manifest.attrib['package'] == 'org.zorofin.tv'
        assert manifest.attrib['version'] == '1.3.0'
        assert manifest.attrib['api-version'] == '6.0'
        assert manifest.find('t:profile', ns).attrib['name'] == 'tv-samsung'
        app = manifest.find('t:ui-application', ns)
        assert app.attrib['appid'] == 'org.zorofin.tv' and app.attrib['type'] == 'dotnet'
        assert {e.text for e in manifest.findall('t:privileges/t:privilege', ns)} == {
            'http://tizen.org/privilege/internet', 'http://tizen.org/privilege/network.get'}
        assert 'res/flutter_assets/NOTICES.Z' in names, 'Third-party notices missing'
        assert {'lib/libapp.so', 'bin/Runner.dll', 'signature1.xml', 'author-signature.xml'} <= set(names)
    return {'file': 'zorofin-tizen-1.3.0.tpk', 'bytes': package.stat().st_size,
            'sha256': hashlib.sha256(package.read_bytes()).hexdigest(), 'package_id': 'org.zorofin.tv',
            'version': '1.3.0', 'minimum_tizen': '6.0', 'status': 'experimental',
            'device_testing': 'Not run on a Samsung TV or emulator',
            'signing': 'Re-sign with Samsung certificates covering the target TV DUID before installation'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    record = inspect(args.input)
    args.output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.input, args.output / record['file'])
    (args.output / 'package.json').write_text(json.dumps(record, indent=2) + '\n')
    (args.output / 'SHA256SUMS').write_text(record['sha256'] + '  ' + record['file'] + '\n')
    print(json.dumps(record))


if __name__ == '__main__':
    main()
