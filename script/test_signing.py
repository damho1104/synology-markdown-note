#!/usr/bin/env python3
"""Exercise real keychain access from two changed app builds via a stable helper."""
import json
import pathlib
import shutil
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
CALLER = r'''import Foundation
@main struct Caller {
    static func main() throws {
        let args = CommandLine.arguments
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: args[1])
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var request: [String: Any] = ["action": args[2], "account": args[3], "interactive": false]
        if args[2] == "save" { request["credentials"] = ["password": "synthetic-test-value", "deviceID": "synthetic-device"] }
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
        let reply = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        guard (reply["status"] as? Int) == 0 else { print("keychain status:", reply["status"] ?? "missing"); exit(1) }
        if args[2] == "load" {
            let credentials = reply["credentials"] as? [String: String]
            guard credentials?["password"] == "synthetic-test-value", credentials?["deviceID"] == "synthetic-device" else { exit(1) }
        }
        print("BUILD_REVISION: keychain operation passed")
    }
}
'''


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=30, **kwargs)


def signature(binary):
    result = run('/usr/bin/codesign', '-d', '-r-', '-vvvv', str(binary))
    lines = [line.lstrip('# ') for line in (result.stdout + result.stderr).splitlines()]
    return (next(line for line in lines if line.startswith('designated => ')),
            next(line for line in lines if line.startswith('CDHash=')))


def main():
    helper = pathlib.Path(run('python3', str(ROOT / 'script/build_credential_helper.py')).stdout.strip())
    original_helper_hash = signature(helper)[1]
    # An unsigned/unrelated caller must be rejected before keychain access.
    denied = subprocess.run([str(helper)], input='{}', capture_output=True, text=True, timeout=5)
    assert denied.returncode == 77, 'Helper accepted an unauthenticated caller'
    with tempfile.TemporaryDirectory(prefix='synology-signing-test-') as directory:
        directory = pathlib.Path(directory)
        binaries = []
        for revision in (1, 2):
            source = directory / f'caller-{revision}.swift'
            source.write_text(CALLER.replace('BUILD_REVISION', f'build-{revision}'))
            binary = directory / f'caller-{revision}'
            run('xcrun', 'swiftc', '-parse-as-library', str(source), '-o', str(binary))
            run('/bin/bash', str(ROOT / 'script/sign_app.sh'), str(binary), 'com.damho.SynologyMarkdown')
            binaries.append(binary)
        first, second = map(signature, binaries)
        assert first[1] != second[1], 'Caller binaries must contain different code'
        assert first[0] == second[0], 'App designated requirements must remain stable'
        account = 'signing-test-' + uuid.uuid4().hex
        saved = False
        try:
            print(run(str(binaries[0]), str(helper), 'save', account).stdout.strip(), flush=True)
            saved = True
            print(run(str(binaries[1]), str(helper), 'load', account).stdout.strip(), flush=True)
            # Signing with the right certificate alone does not authorize another app.
            rejected = directory / 'unrelated-app'
            shutil.copy2(binaries[1], rejected)
            run('/bin/bash', str(ROOT / 'script/sign_app.sh'), str(rejected), 'com.damho.UnrelatedApp')
            result = subprocess.run([str(rejected), str(helper), 'load', account], capture_output=True, text=True, timeout=5)
            assert result.returncode == 77, 'Helper accepted a different signed app identifier'
        finally:
            if saved: run(str(binaries[0]), str(helper), 'remove', account)
        assert signature(helper)[1] == original_helper_hash, 'App rebuild changed keychain helper identity'
        print('PASS: two changed app builds read the same synthetic keychain credentials through the unchanged authenticated helper')


if __name__ == '__main__':
    try: main()
    except (AssertionError, subprocess.SubprocessError) as error:
        print('FAIL:', error)
        if isinstance(error, subprocess.CalledProcessError): print(error.stdout or '', error.stderr or '')
        raise SystemExit(1)
