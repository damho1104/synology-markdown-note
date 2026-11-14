#!/usr/bin/env python3
"""Keep a local code-signing identity in the login keychain across app rebuilds.

No root trust, TLS trust, or existing credential ACL is changed. Private key
material is imported for /usr/bin/codesign only, then removed from temporary files.
"""
import json
import os
import pathlib
import re
import secrets
import subprocess
import tempfile
import sys

# CI can isolate signing metadata from an interactive user's existing app identity.
DEFAULT_DIRECTORY = pathlib.Path.home() / 'Library/Application Support/SynologyMarkdown/DevelopmentSigning'
IDENTITY_FILE = pathlib.Path(os.environ['SYNOLOGY_NOTE_SIGNING_IDENTITY_FILE']).expanduser() if os.environ.get('SYNOLOGY_NOTE_SIGNING_IDENTITY_FILE') else DEFAULT_DIRECTORY / 'identity.json'
DIRECTORY = IDENTITY_FILE.parent
NAME = 'SynologyNote Local Development'


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=45, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{pathlib.Path(args[0]).name}: {result.stderr.strip()}')
    return result.stdout


def available():
    args = ['/usr/bin/security', 'find-identity', '-p', 'codesigning']
    # Headless CI services can have an empty default keychain search list.
    if keychain := os.environ.get('SYNOLOGY_NOTE_SIGNING_KEYCHAIN'):
        args.append(keychain)
    output = run(*args)
    return set(re.findall(r'\b[0-9A-Fa-f]{40}\b', output.upper()))


def headless_identity():
    """Validate a protected P12 directly, without Keychain or GUI interaction."""
    archive = os.environ.get('SYNOLOGY_NOTE_SIGNING_P12_FILE')
    password = os.environ.get('SYNOLOGY_NOTE_SIGNING_P12_PASSWORD_FILE')
    if not archive and not password:
        return None
    if not archive or not password:
        raise RuntimeError('Both signing P12 and password file are required')
    for path in (archive, password):
        if not pathlib.Path(path).is_file():
            raise RuntimeError('Headless signing credential file is missing')
    with tempfile.TemporaryDirectory(prefix='synonote-certs-') as temporary:
        output = pathlib.Path(temporary) / 'certs.pem'
        with output.open('wb') as stream:
            result = subprocess.run(['/usr/bin/openssl', 'pkcs12', '-in', archive,
                                     '-nokeys', '-passin', 'file:' + password],
                                    stdout=stream, stderr=subprocess.PIPE, timeout=30)
        if result.returncode:
            raise RuntimeError('Unable to decrypt headless signing P12')
        blocks = re.findall(rb'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                            output.read_bytes(), flags=re.S)
        digests = []
        for block in blocks:
            value = subprocess.check_output(['/usr/bin/openssl', 'x509', '-noout',
                                             '-fingerprint', '-sha1'], input=block, timeout=10)
            digests.append(value.decode().strip().split('=')[-1].replace(':', '').upper())
        if len(digests) != 1:
            raise RuntimeError('Expected exactly one certificate in headless signing P12')
        return digests[0]


def main():
    os.umask(0o077)
    headless = headless_identity()
    if headless is not None:
        if not IDENTITY_FILE.is_file():
            raise RuntimeError('Pinned headless signing identity metadata is missing')
        expected = json.loads(IDENTITY_FILE.read_text())['sha1']
        if not re.fullmatch(r'[0-9A-F]{40}', expected) or headless != expected:
            raise RuntimeError('Headless P12 certificate differs from pinned identity')
        print(headless)
        return
    DIRECTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    if IDENTITY_FILE.exists():
        identity = json.loads(IDENTITY_FILE.read_text())['sha1']
        if not re.fullmatch(r'[0-9A-F]{40}', identity) or identity not in available():
            raise RuntimeError('Saved local signing identity is unavailable in the keychain; restore it instead of silently replacing it.')
        print(identity)
        return

    # The certificate identifies local builds, without granting it root trust.
    with tempfile.TemporaryDirectory(prefix='bootstrap-', dir=DIRECTORY) as temporary:
        temporary = pathlib.Path(temporary)
        configuration = temporary / 'certificate.cnf'
        key = temporary / 'private-key.pem'
        certificate = temporary / 'certificate.pem'
        archive = temporary / 'identity.p12'
        configuration.write_text('''[req]
distinguished_name = name
x509_extensions = code_signing
prompt = no
[name]
CN = SynologyNote Local Development
[code_signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
        run('/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:3072', '-nodes', '-x509', '-days', '3650',
            '-config', str(configuration), '-keyout', str(key), '-out', str(certificate))
        identity = run('/usr/bin/openssl', 'x509', '-in', str(certificate), '-noout', '-fingerprint', '-sha1').strip().split('=')[-1].replace(':', '').upper()
        archive_password = secrets.token_urlsafe(24)
        run('/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(certificate),
            '-name', NAME, '-out', str(archive), '-passout', 'env:SYNOLOGY_NOTE_P12_PASSWORD',
            env={**os.environ, 'SYNOLOGY_NOTE_P12_PASSWORD': archive_password})
        keychain = run('/usr/bin/security', 'default-keychain', '-d', 'user').strip().strip('"')
        run('/usr/bin/security', 'import', str(archive), '-k', keychain, '-P', archive_password, '-T', '/usr/bin/codesign')
        if identity not in available():
            raise RuntimeError('The new local signing identity could not be found after import.')
        # Only public metadata persists on disk; the private key stays in Keychain.
        staging = DIRECTORY / 'identity.json.tmp'
        staging.write_text(json.dumps({'sha1': identity, 'name': NAME}) + '\n')
        staging.replace(IDENTITY_FILE)
        print(identity)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('Local code signing setup failed:', error, file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        raise SystemExit(1)
