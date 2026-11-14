import json
from importlib.metadata import version as package_version
from pathlib import Path
import re
import subprocess
import sys

import pytest

from synonote_cli import main


def test_version_command_matches_package_and_current_git_commit(monkeypatch, capsys):
    root = Path(__file__).resolve().parents[2]
    commit = subprocess.check_output(["git", "rev-parse", "--short=7", "HEAD"], cwd=root, text=True).strip()
    expected = f"{package_version('synonote-cli')}-{commit}"
    monkeypatch.setattr(main, "connected", lambda: pytest.fail("version must not connect to NAS"))
    monkeypatch.setattr(sys, "argv", ["synonote", "version"])
    main.run()
    assert capsys.readouterr().out == f"{expected}\n"


def test_version_command_json_output(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["synonote", "version", "--json"])
    main.run()
    output = capsys.readouterr().out
    result = json.loads(output)
    assert output.count("\n") == 1
    assert result["schema_version"] == 1
    assert result["action"] == "version"
    assert result["status"] == "ok"
    assert re.fullmatch(r"\d+\.\d+\.\d+-[0-9a-f]{7,}", result["version"])


def test_missing_required_arguments_return_one_json_object(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["synonote", "upload", "--json"])
    with pytest.raises(SystemExit) as error:
        main.run()
    output = capsys.readouterr()
    assert error.value.code == 2
    assert json.loads(output.out)["error"]["code"] == "INVALID_ARGUMENT"
    assert output.out.count("\n") == 1


def test_login_non_interactive_without_password_is_json_error(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["synonote", "login", "--server", "https://nas.example", "--username", "test", "--json", "--non-interactive"])
    with pytest.raises(SystemExit) as error:
        main.run()
    output = capsys.readouterr()
    assert error.value.code == 5
    assert json.loads(output.out)["error"]["code"] == "AUTH_REQUIRED"


def test_auth_set_server_json_output(monkeypatch, capsys):
    monkeypatch.setattr(main.auth, "set_server", lambda url: {
        "status": "updated", "server": url, "username": "alice"})
    monkeypatch.setattr(sys, "argv", ["synonote", "auth", "set-server", "--server",
                                          "https://new-nas.example", "--json"])
    main.run()
    output = json.loads(capsys.readouterr().out)
    assert output == {"schema_version": 1, "action": "auth.set-server", "status": "updated",
                      "server": "https://new-nas.example", "username": "alice"}


def test_https_server_rejects_plaintext_credentials_and_query():
    from synonote_cli.api import checked_server
    from synonote_cli.errors import CLIError
    for url in ("http://nas.example", "https://user:secret@nas.example", "https://nas.example/?password=secret"):
        with pytest.raises(CLIError):
            checked_server(url)


def test_note_info_does_not_hide_nas_download_failure(monkeypatch, capsys):
    from synonote_cli.errors import CLIError
    from test_transfers import FakeNAS

    api = FakeNAS()
    api.close = lambda: None

    def fail_download(_file_id, _note_id):
        raise CLIError("TRANSPORT_ERROR", "download unavailable")

    api.download = fail_download
    monkeypatch.setattr(main, "connected", lambda: api)
    monkeypatch.setattr(sys, "argv", ["synonote", "note", "info", "--id", "n1", "--json"])
    with pytest.raises(SystemExit) as error:
        main.run()
    assert error.value.code == 8
    assert json.loads(capsys.readouterr().out)["error"]["code"] == "TRANSPORT_ERROR"
