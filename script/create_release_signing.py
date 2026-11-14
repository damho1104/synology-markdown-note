"""Create a dedicated self-signed release identity and store it in GitHub Secrets.

Never reads or exports the developer's existing Keychain identities.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile

NAMES = ("MACOS_SIGNING_P12_BASE64", "MACOS_SIGNING_P12_PASSWORD", "MACOS_SIGNING_CERT_SHA1")


def run(*args: str, **kwargs) -> bytes:
    result = subprocess.run(args, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} operation failed")
    return result.stdout


def main(repository: str) -> None:
    existing = json.loads(run("gh", "secret", "list", "--repo", repository, "--json", "name"))
    if any(item["name"] in NAMES for item in existing):
        raise RuntimeError("Release signing secrets already exist; refusing to rotate the identity")
    with tempfile.TemporaryDirectory(prefix="synonote-release-identity-") as temporary:
        directory = Path(temporary)
        config, key, cert, archive = [directory / name for name in ("cert.cnf", "key.pem", "cert.pem", "identity.p12")]
        config.write_text("""[req]
distinguished_name = name
x509_extensions = code_signing
prompt = no
[name]
CN = SynologyNote GitHub Release
[code_signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        run("openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes", "-x509", "-days", "3650",
            "-config", str(config), "-keyout", str(key), "-out", str(cert))
        password = secrets.token_urlsafe(32)
        run("openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(cert),
            "-name", "SynologyNote GitHub Release", "-out", str(archive),
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1",
            "-passout", "env:RELEASE_ARCHIVE_PASSWORD", env={**os.environ, "RELEASE_ARCHIVE_PASSWORD": password})
        fingerprint = run("openssl", "x509", "-in", str(cert), "-noout", "-fingerprint", "-sha1")
        identity = fingerprint.decode().strip().split("=")[-1].replace(":", "").upper()
        values = (base64.b64encode(archive.read_bytes()), password.encode(), identity.encode())
        for name, value in zip(NAMES, values):
            run("gh", "secret", "set", name, "--repo", repository, input=value)
        print("Configured three dedicated release signing secrets; temporary private key files removed on exit.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    main(parser.parse_args().repo)
