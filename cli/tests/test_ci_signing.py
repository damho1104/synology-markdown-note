import importlib.util
from pathlib import Path
import shlex
import sys


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci_signing", ROOT / "script/ci_signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def test_cleanup_preserves_persistent_runners_other_keychains(monkeypatch, tmp_path):
    monkeypatch.setenv("RUNNER_TEMP", str(tmp_path))
    monkeypatch.setenv("GITHUB_RUN_ID", "123")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "2")
    monkeypatch.setattr(sys, "argv", ["ci_signing.py", "cleanup"])
    directory = tmp_path / "synonote-release-signing-123-2"
    directory.mkdir()
    keychain = directory / "release.keychain-db"
    keychain.touch()
    existing = ["/example/login.keychain-db", str(keychain), "/example/Other Keychain.keychain-db"]
    calls = []

    def security(*args):
        calls.append(args)
        return shlex.join(existing) if args == ("list-keychains", "-d", "user") else ""

    monkeypatch.setattr(signing, "security", security)
    signing.main()
    assert calls == [
        ("list-keychains", "-d", "user"),
        ("list-keychains", "-d", "user", "-s", existing[0], existing[2]),
        ("delete-keychain", str(keychain)),
    ]
    assert not directory.exists()


def test_cleanup_before_import_does_not_touch_user_keychains(monkeypatch, tmp_path):
    monkeypatch.setenv("RUNNER_TEMP", str(tmp_path))
    monkeypatch.setenv("GITHUB_RUN_ID", "123")
    monkeypatch.setenv("GITHUB_RUN_ATTEMPT", "1")
    monkeypatch.setattr(sys, "argv", ["ci_signing.py", "cleanup"])
    monkeypatch.setattr(signing, "security", lambda *args: (_ for _ in ()).throw(AssertionError(args)))
    signing.main()
