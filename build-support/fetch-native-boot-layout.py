#!/usr/bin/env python3
"""Fetch the immutable ARM64 boot image through the verified OCI layout reader."""

import json
from pathlib import Path
import runpy
import sys
from urllib.request import ProxyHandler, build_opener


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: fetch-native-boot-layout.py OUTPUT_DIRECTORY')
    target = Path(sys.argv[1])
    repo = Path(__file__).resolve().parents[1]
    staging = runpy.run_path(str(repo / 'benchmarks/fetch-comparison-build-bases.py'))
    manifest = json.loads(staging['MANIFEST'].read_bytes())
    image = manifest['images']['alpine']
    reader = build_opener(ProxyHandler({}), staging['RegistryRedirect']())
    staging['stage_base'](reader, target, image)
    print(image['ref'])


if __name__ == '__main__':
    main()
