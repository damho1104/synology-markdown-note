import json
import os
import stat

import pytest

from synonote_cli import auth
from synonote_cli.errors import CLIError


def test_malformed_secure_store_is_a_structured_auth_error(monkeypatch):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: False)
    monkeypatch.setattr(auth.keyring, "get_password", lambda *_args: "[]")
    with pytest.raises(CLIError) as error:
        auth._get({"server": "https://nas.example", "username": "alice"})
    assert error.value.code == "AUTH_REQUIRED"


def test_login_remembered_authentication_and_logout(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: False)
    vault = {}
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config")
    monkeypatch.setattr(auth.keyring, "set_password", lambda service, user, secret: vault.__setitem__((service, user), secret))
    monkeypatch.setattr(auth.keyring, "get_password", lambda service, user: vault.get((service, user)))
    monkeypatch.setattr(auth.keyring, "delete_password", lambda service, user: vault.pop((service, user)))

    class FakeAPI:
        def __init__(self, _server=None):
            self.calls = []

        def login(self, username, password, *, otp=None, remember=True, device_id=None):
            self.calls.append((username, password, otp, remember, device_id))
            return "trusted-device-42"

        def close(self):
            pass

    monkeypatch.setattr(auth, "NoteStationAPI", FakeAPI)
    assert auth.login("https://nas.example:5001", "alice", "private-password", "123456", True)["remembered"]
    assert auth.load_profile() == {"server": "https://nas.example:5001", "username": "alice"}
    assert "private-password" not in auth.profile_path().read_text()

    api = FakeAPI()
    auth.authenticate(api)
    assert api.calls == [("alice", "private-password", None, True, "trusted-device-42")]
    auth.logout()
    assert not auth.profile_path().exists()
    assert vault == {}


class FakeAPI:
    def __init__(self, _server=None):
        self.calls = []

    def login(self, username, password, *, otp=None, remember=True, device_id=None):
        self.calls.append((username, password, otp, remember, device_id))
        return "trusted-device-42"

    def close(self):
        pass


def test_linux_credentials_file_login_authenticate_logout(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config" / "synonote")
    monkeypatch.setattr(auth, "NoteStationAPI", FakeAPI)
    monkeypatch.setattr(auth.keyring, "set_password", lambda *_args: pytest.fail("Linux invoked keyring"))
    monkeypatch.setattr(auth.keyring, "get_password", lambda *_args: pytest.fail("Linux invoked keyring"))
    monkeypatch.setattr(auth.keyring, "delete_password", lambda *_args: pytest.fail("Linux invoked keyring"))

    result = auth.login("https://nas.example:5001", "alice", "private-password", "123456", True)
    assert result["remembered"] is True
    assert auth.load_profile() == {"server": "https://nas.example:5001", "username": "alice"}
    stored = json.loads(auth.credentials_path().read_text(encoding="utf-8"))
    assert stored["password"] == "private-password"
    assert stored["device_id"] == "trusted-device-42"
    assert "private-password" not in auth.profile_path().read_text(encoding="utf-8")

    if os.name == "posix":
        assert stat.S_IMODE(auth.state_dir().stat().st_mode) == 0o700
        assert stat.S_IMODE(auth.credentials_path().stat().st_mode) == 0o600
        assert stat.S_IMODE(auth.profile_path().stat().st_mode) == 0o600

    api = FakeAPI()
    auth.authenticate(api)
    assert api.calls == [("alice", "private-password", None, True, "trusted-device-42")]
    auth.logout()
    assert not auth.credentials_path().exists()
    assert not auth.profile_path().exists()


def test_linux_set_server_preserves_remembered_login(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config")
    requests = []

    class RecordingAPI(FakeAPI):
        def __init__(self, server):
            super().__init__(server)
            self.server = server

        def login(self, username, password, *, otp=None, remember=True, device_id=None):
            requests.append((self.server, username, password, device_id))
            return "trusted-device-42"

    monkeypatch.setattr(auth, "NoteStationAPI", RecordingAPI)
    auth.login("https://old-nas.example:5001", "alice", "private-password", None, True)
    assert auth.set_server("https://new-nas.example:5001/") == {
        "status": "updated", "server": "https://new-nas.example:5001", "username": "alice"}
    assert requests[-1] == ("https://new-nas.example:5001", "alice", "private-password", "trusted-device-42")
    assert auth.load_profile()["server"] == "https://new-nas.example:5001"
    stored = json.loads(auth.credentials_path().read_text())
    assert stored == {"server": "https://new-nas.example:5001", "username": "alice",
                      "password": "private-password", "device_id": "trusted-device-42"}
    if os.name == "posix":
        assert stat.S_IMODE(auth.credentials_path().stat().st_mode) == 0o600
        assert stat.S_IMODE(auth.profile_path().stat().st_mode) == 0o600
    auth.authenticate(RecordingAPI("https://new-nas.example:5001"))
    assert auth.set_server("https://new-nas.example:5001")["status"] == "unchanged"


def test_linux_set_server_failed_auth_keeps_saved_login(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config")
    monkeypatch.setattr(auth, "NoteStationAPI", FakeAPI)
    auth.login("https://old-nas.example", "alice", "secret", None, True)
    original_profile = auth.profile_path().read_bytes()
    original_credentials = auth.credentials_path().read_bytes()

    class FailingAPI(FakeAPI):
        def login(self, *args, **kwargs):
            raise CLIError("TRANSPORT_ERROR", "NAS 연결 실패")

    monkeypatch.setattr(auth, "NoteStationAPI", FailingAPI)
    with pytest.raises(CLIError) as error:
        auth.set_server("https://new-nas.example")
    assert error.value.code == "TRANSPORT_ERROR"
    assert auth.profile_path().read_bytes() == original_profile
    assert auth.credentials_path().read_bytes() == original_credentials


def test_linux_set_server_rolls_back_credentials_on_profile_write_failure(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config")
    monkeypatch.setattr(auth, "NoteStationAPI", FakeAPI)
    auth.login("https://old-nas.example", "alice", "secret", None, True)
    original = json.loads(auth.credentials_path().read_text())
    real_write = auth._atomic_write_json

    def fail_profile(path, value):
        if path == auth.profile_path():
            raise OSError("disk full")
        return real_write(path, value)

    monkeypatch.setattr(auth, "_atomic_write_json", fail_profile)
    with pytest.raises(CLIError) as error:
        auth.set_server("https://new-nas.example")
    assert error.value.code == "CREDENTIAL_STORE_UNAVAILABLE"
    assert auth.load_profile()["server"] == "https://old-nas.example"
    assert json.loads(auth.credentials_path().read_text()) == original


def test_set_server_rejects_http_without_touching_credentials(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config")
    monkeypatch.setattr(auth, "NoteStationAPI", FakeAPI)
    auth.login("https://old-nas.example", "alice", "secret", None, True)
    with pytest.raises(CLIError) as error:
        auth.set_server("http://new-nas.example")
    assert error.value.code == "INVALID_ARGUMENT"
    assert auth.load_profile()["server"] == "https://old-nas.example"


@pytest.mark.parametrize("platform", ["darwin", "win32"])
def test_native_keyring_set_server_moves_credential(monkeypatch, tmp_path, platform):
    monkeypatch.setattr(auth.sys, "platform", platform)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config")
    monkeypatch.setattr(auth, "NoteStationAPI", FakeAPI)
    vault = {}
    monkeypatch.setattr(auth.keyring, "set_password", lambda service, user, raw: vault.__setitem__((service, user), raw))
    monkeypatch.setattr(auth.keyring, "get_password", lambda service, user: vault.get((service, user)))
    auth.login("https://old-nas.example", "alice", "secret", None, True)
    assert auth.set_server("https://new-nas.example")["status"] == "updated"
    assert ("synonote-cli|https://new-nas.example", "alice") in vault
    assert auth.load_profile()["server"] == "https://new-nas.example"
    assert auth._get(auth.load_profile())["password"] == "secret"


@pytest.mark.parametrize("platform", ["darwin", "win32"])
def test_native_keyring_selected_on_macos_and_windows(monkeypatch, tmp_path, platform):
    monkeypatch.setattr(auth.sys, "platform", platform)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config")
    monkeypatch.setattr(auth, "NoteStationAPI", FakeAPI)
    vault = {}
    monkeypatch.setattr(auth.keyring, "set_password", lambda service, user, raw: vault.__setitem__((service, user), raw))
    monkeypatch.setattr(auth.keyring, "get_password", lambda service, user: vault.get((service, user)))
    monkeypatch.setattr(auth.keyring, "delete_password", lambda service, user: vault.pop((service, user)))

    assert auth._uses_file_credentials() is False
    auth.login("https://nas.example", "alice", "private-password", None, True)
    assert vault
    assert not auth.credentials_path().exists()
    auth.authenticate(FakeAPI())
    auth.logout()
    assert vault == {}


def test_linux_platform_selected_without_keyring(monkeypatch):
    monkeypatch.setattr(auth.sys, "platform", "linux")
    assert auth._uses_file_credentials() is True


def test_linux_state_dir_uses_xdg_config_home(monkeypatch, tmp_path):
    monkeypatch.setattr(auth.sys, "platform", "linux")
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "settings"))
    assert auth.credentials_path() == tmp_path / "settings" / "synonote" / "credentials.json"


def test_linux_credentials_must_match_saved_profile(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path)
    auth.credentials_path().write_text(json.dumps({
        "server": "https://other-nas.example", "username": "alice",
        "password": "secret", "device_id": None,
    }), encoding="utf-8")
    auth.credentials_path().chmod(0o600)
    with pytest.raises(CLIError) as error:
        auth._get({"server": "https://nas.example", "username": "alice"})
    assert error.value.code == "AUTH_REQUIRED"


@pytest.mark.parametrize("raw", ["{broken", "[]", '{"password": ""}', '{"password": 42}'])
def test_linux_invalid_credentials_raise_auth_error(monkeypatch, tmp_path, raw):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path)
    auth.credentials_path().write_text(raw, encoding="utf-8")
    auth.credentials_path().chmod(0o600)

    with pytest.raises(CLIError) as error:
        auth._get({"server": "https://nas.example", "username": "alice"})
    assert error.value.code == "AUTH_REQUIRED"
    assert "password" not in str(error.value).lower()


def test_linux_missing_credentials_raise_auth_required(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path)
    with pytest.raises(CLIError) as error:
        auth._get({"server": "https://nas.example", "username": "alice"})
    assert error.value.code == "AUTH_REQUIRED"


@pytest.mark.skipif(os.name != "posix", reason="POSIX file permissions")
def test_linux_rejects_overly_open_credentials(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path)
    auth.credentials_path().write_text('{"password": "secret"}', encoding="utf-8")
    auth.credentials_path().chmod(0o644)
    with pytest.raises(CLIError) as error:
        auth._get({"server": "https://nas.example", "username": "alice"})
    assert error.value.code == "CREDENTIAL_STORE_UNAVAILABLE"


@pytest.mark.skipif(os.name != "posix", reason="POSIX symlink semantics")
def test_linux_rejects_credentials_symlink(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config")
    auth.state_dir().mkdir()
    target = tmp_path / "not-owned.json"
    target.write_text("untouched", encoding="utf-8")
    auth.credentials_path().symlink_to(target)

    with pytest.raises(CLIError) as error:
        auth._get({"server": "https://nas.example", "username": "alice"})
    assert error.value.code == "CREDENTIAL_STORE_UNAVAILABLE"
    with pytest.raises(CLIError) as error:
        auth._save_credentials({"server": "https://nas.example", "username": "alice"}, "new", None)
    assert error.value.code == "CREDENTIAL_STORE_UNAVAILABLE"
    assert target.read_text(encoding="utf-8") == "untouched"


@pytest.mark.skipif(os.name != "posix", reason="POSIX symlink semantics")
def test_linux_rejects_symlink_config_directory(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    target = tmp_path / "other"
    target.mkdir()
    state = tmp_path / "config"
    state.symlink_to(target, target_is_directory=True)
    monkeypatch.setattr(auth, "state_dir", lambda: state)
    with pytest.raises(CLIError) as error:
        auth._save_credentials({"server": "https://nas.example", "username": "alice"}, "new", None)
    assert error.value.code == "CREDENTIAL_STORE_UNAVAILABLE"
    assert list(target.iterdir()) == []


def test_linux_failed_file_write_raises_structured_error_and_no_profile(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path / "config")
    monkeypatch.setattr(auth, "NoteStationAPI", FakeAPI)
    monkeypatch.setattr(auth.tempfile, "mkstemp", lambda **_kwargs: (_ for _ in ()).throw(PermissionError("blocked")))

    with pytest.raises(CLIError) as error:
        auth.login("https://nas.example", "alice", "secret", None, True)
    assert error.value.code == "CREDENTIAL_STORE_UNAVAILABLE"
    assert "secret" not in str(error.value)
    assert not auth.profile_path().exists()


def test_linux_logout_missing_credential_file_cleans_profile(monkeypatch, tmp_path):
    monkeypatch.setattr(auth, "_uses_file_credentials", lambda: True)
    monkeypatch.setattr(auth, "state_dir", lambda: tmp_path)
    auth.profile_path().write_text(json.dumps({"server": "https://nas.example", "username": "alice"}))
    auth.logout()
    assert not auth.profile_path().exists()
