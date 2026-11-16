#!/usr/bin/env python3
"""Vendor a pinned, verified Spectrum subset. Requires curl and rsvg-convert.
Normal builds use committed assets and do not run this script or use the network.
"""
import base64
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

VERSION = '1.7.0'
ICONS = ['Brush', 'Erase', 'RectSelect', 'SelectCircular', 'SelectionMove', 'ColorFill',
         'Sampler', 'Line', 'Rectangle', 'Ellipse', 'Text', 'Crop', 'MergeLayers',
         'Group', 'Ungroup', 'Duplicate', 'Rename', 'Effects', 'LayersForward',
         'LayersBackward', 'Layers', 'InvertAdj']
ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / 'Sources/PaintMac/Resources/Spectrum'

def fetch(url):
    return subprocess.check_output(['curl', '--fail', '--silent', '--show-error', url])

def main():
    meta = json.loads(fetch('https://registry.npmjs.org/@adobe%2fspectrum-css-workflow-icons/' + VERSION))
    assert meta['license'] == 'Apache-2.0'
    payload = fetch(meta['dist']['tarball'])
    integrity = 'sha512-' + base64.b64encode(hashlib.sha512(payload).digest()).decode()
    assert integrity == meta['dist']['integrity'], 'Upstream integrity mismatch'
    archive = tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz')
    DEST.mkdir(parents=True, exist_ok=True)
    for name in ['LICENSE', 'COPYRIGHT']:
        (DEST / name).write_bytes(archive.extractfile('package/' + name).read())
    for name in ICONS:
        svg = archive.extractfile('package/dist/18/' + name + '.svg').read()
        (DEST / (name + '.svg')).write_bytes(svg)
        subprocess.run(['rsvg-convert', '--format=pdf', '--width=18', '--height=18',
                        '--output', str(DEST / (name + '.pdf')), str(DEST / (name + '.svg'))], check=True)
    (DEST / 'UPSTREAM.json').write_text(json.dumps({
        'package': meta['name'], 'version': VERSION, 'url': meta['dist']['tarball'],
        'integrity': integrity, 'license': meta['license'], 'icons': ICONS
    }, indent=2) + '\n')
    (DEST / 'NOTICES.txt').write_text('''Adobe Spectrum Workflow Icons
Source: https://github.com/adobe/spectrum-css-workflow-icons
Package: @adobe/spectrum-css-workflow-icons 1.7.0 (legacy 18 px set)
© Copyright 2015-2022 Adobe. All rights reserved.
Licensed under the Apache License, Version 2.0; see LICENSE and COPYRIGHT.

Paint.MAC includes a selected subset. The SVG source files are unmodified.
The PDF files are derived vector conversions made by Paint.MAC using librsvg.
Sizing, template tinting, and action mappings are supplied by Paint.MAC.
Adobe does not endorse or sponsor Paint.MAC. No Adobe product logos are used.
''')
    print('Vendored', len(ICONS), 'icons into', DEST)

if __name__ == '__main__':
    main()
