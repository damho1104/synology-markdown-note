#!/usr/bin/env python3
"""Cache an authenticated keychain helper independently of the app's UI build."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / '.build/credential-helper'
SOURCES = [ROOT / 'tools/CredentialHelper/main.swift', ROOT / 'Sources/NoteCore/CredentialStore.swift']


def run(*args):
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def main():
    identity = run('python3', str(ROOT / 'script/local_signing_identity.py'))
    fingerprint = hashlib.sha256(identity.encode() + b''.join(path.read_bytes() for path in SOURCES)).hexdigest()
    binary = CACHE / 'SynologyCredentialHelper'
    manifest = CACHE / 'manifest.json'
    cached = json.loads(manifest.read_text()) if manifest.exists() else {}
    if cached.get('fingerprint') == fingerprint and binary.exists():
        run('/usr/bin/codesign', '--verify', '--strict',
            f'-R=identifier "com.damho.SynologyMarkdown.CredentialHelper" and certificate leaf = H"{identity}"', str(binary))
    else:
        CACHE.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=CACHE) as temporary:
            temporary = pathlib.Path(temporary)
            candidate = temporary / binary.name
            run('xcrun', 'swiftc', '-parse-as-library', '-O', *map(str, SOURCES), '-o', str(candidate))
            run('/bin/bash', str(ROOT / 'script/sign_app.sh'), str(candidate), 'com.damho.SynologyMarkdown.CredentialHelper')
            candidate.replace(binary)
            manifest.write_text(json.dumps({'fingerprint': fingerprint}) + '\n')
    print(binary)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stderr, file=sys.stderr)
        raise SystemExit(1)
