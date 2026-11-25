#!/usr/bin/env python3
"""Stage only the built web app and public metadata for LG packaging."""
import json
import os
from pathlib import Path
import re
import shutil

app = Path(__file__).resolve().parents[2]
source = app / 'build/web'
if not (source / 'main.dart.js').is_file():
    raise SystemExit('Build the JavaScript web release first.')
staged = app / 'build/webos-web/app'
if staged.exists():
    shutil.rmtree(staged)
shutil.copytree(source, staged)
for name in ('flutter_service_worker.js', '.last_build_id', 'version.json'):
    (staged / name).unlink(missing_ok=True)
metadata = json.loads((app / 'tool/webos-web/appinfo.json').read_text())
version = os.environ.get('WEBOS_VERSION', metadata['version'])
if not re.fullmatch(r'(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})', version):
    raise SystemExit('WEBOS_VERSION must be a valid LG x.y.z version.')
metadata['version'] = version
(staged / 'appinfo.json').write_text(json.dumps(metadata, indent=2) + '\n')
for name in ('icon.png', 'largeIcon.png'):
    shutil.copy2(app / 'webos/meta' / name, staged / name)
if not (staged / 'canvaskit/canvaskit.wasm').is_file():
    raise SystemExit('CanvasKit must be bundled, not fetched from a CDN.')
print(staged)
