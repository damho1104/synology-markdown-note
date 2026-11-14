"""Import a dedicated release identity into a temporary GitHub Actions keychain."""

import base64
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys


def security(*args: str) -> str:
    result = subprocess.run(["/usr/bin/security", *args], text=True, capture_output=True)
    if result.returncode:
        # Never include a command line containing the keychain/P12 password.
        raise RuntimeError("Release keychain operation failed")
    return result.stdout


def main() -> None:
    run = f"{os.environ['GITHUB_RUN_ID']}-{os.environ['GITHUB_RUN_ATTEMPT']}"
    directory = Path(os.environ["RUNNER_TEMP"]) / f"synonote-release-signing-{run}"
    keychain = directory / "release.keychain-db"
    if sys.argv[1:] == ["cleanup"]:
        if keychain.exists():
            # Preserve the persistent runner's other keychains and any changes
            # made while the job was running; remove only our temporary entry.
            current = shlex.split(security("list-keychains", "-d", "user"))
            remaining = [item for item in current if item != str(keychain)]
            if remaining != current:
                security("list-keychains", "-d", "user", "-s", *remaining)
            security("delete-keychain", str(keychain))
        shutil.rmtree(directory, ignore_errors=True)
        return
    encoded = os.environ["MACOS_SIGNING_P12_BASE64"]
    password = os.environ["MACOS_SIGNING_P12_PASSWORD"]
    identity = os.environ["MACOS_SIGNING_CERT_SHA1"].upper()
    if not encoded or not password or not re.fullmatch(r"[0-9A-F]{40}", identity):
        raise ValueError("Configure the three MACOS_SIGNING_* repository secrets first")
    os.umask(0o077)
    directory.mkdir(mode=0o700)
    archive = directory / "release.p12"
    archive.write_bytes(base64.b64decode(encoded, validate=True))
    keychain_password = secrets.token_urlsafe(32)
    search_list = shlex.split(security("list-keychains", "-d", "user"))
    security("create-keychain", "-p", keychain_password, str(keychain))
    security("set-keychain-settings", "-lut", "21600", str(keychain))
    security("unlock-keychain", "-p", keychain_password, str(keychain))
    security("list-keychains", "-d", "user", "-s", str(keychain), *search_list)
    security("import", str(archive), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign")
    archive.unlink()
    security("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychain_password, str(keychain))
    available = security("find-identity", "-p", "codesigning", str(keychain)).upper()
    if identity not in set(re.findall(r"\b[0-9A-F]{40}\b", available)):
        raise ValueError("Release signing certificate does not match the pinned fingerprint")
    metadata = directory / "identity.json"
    metadata.write_text(json.dumps({"sha1": identity, "name": "SynologyNote GitHub Release"}) + "\n")
    with Path(os.environ["GITHUB_ENV"]).open("a") as environment:
        environment.write(f"SYNOLOGY_NOTE_SIGNING_IDENTITY_FILE={metadata}\n")
        environment.write(f"SYNOLOGY_NOTE_SIGNING_KEYCHAIN={keychain}\n")
    print("Configured isolated release signing keychain")


if __name__ == "__main__":
    main()
