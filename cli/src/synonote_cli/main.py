"""Typer front end for LLM-friendly Note Station commands."""
import getpass
import json
from pathlib import Path
import sys
import typer
from typer._click.exceptions import ClickException
from . import auth
from .api import NoteStationAPI
from .errors import CLIError
from .indexing import build as build_index
from .operations import status as operation_status
from .transfers import download as download_note, upload as upload_note
from .version import display_version

app = typer.Typer(no_args_is_help=True, add_completion=False)
auth_app, stack_app, book_app, note_app, op_app, index_app = (typer.Typer() for _ in range(6))
for name, sub in (("auth", auth_app), ("stack", stack_app), ("notebook", book_app),
                  ("note", note_app), ("operation", op_app), ("index", index_app)):
    app.add_typer(sub, name=name)


def emit(action: str, value: dict, json_mode: bool) -> None:
    data = {"schema_version": 1, "action": action, **value}
    if json_mode:
        typer.echo(json.dumps(data, ensure_ascii=False))
    else:
        for key, val in data.items():
            if key != "schema_version":
                typer.echo(f"{key}: {val}")


@app.command()
def version(json_mode: bool = typer.Option(False, "--json")):
    """CLI 버전과 Git 커밋을 표시합니다."""
    value = display_version()
    if json_mode:
        emit("version", {"status": "ok", "version": value}, True)
    else:
        typer.echo(value)


def connected() -> NoteStationAPI:
    profile = auth.load_profile()
    api = NoteStationAPI(profile["server"])
    try:
        auth.authenticate(api)
    except Exception:
        api.close()
        raise
    return api


def execute(action: str, json_mode: bool, fn) -> None:
    api = connected()
    try:
        emit(action, fn(api), json_mode)
    finally:
        api.close()


@app.command()
def login(server: str = typer.Option(...), username: str = typer.Option(...),
          remember: bool = typer.Option(False, "--remember"),
          otp: str | None = typer.Option(None),
          password_stdin: bool = typer.Option(False, "--password-stdin"),
          json_mode: bool = typer.Option(False, "--json"),
          non_interactive: bool = typer.Option(False, "--non-interactive")):
    if password_stdin:
        password = sys.stdin.readline().rstrip("\r\n")
    elif non_interactive or not sys.stdin.isatty():
        raise CLIError("AUTH_REQUIRED", "비대화형 로그인에는 --password-stdin이 필요합니다.")
    else:
        password = getpass.getpass("NAS password: ")
    if not password:
        raise CLIError("INVALID_ARGUMENT", "비밀번호가 비어 있습니다.")
    try:
        result = auth.login(server, username, password, otp, remember)
    except CLIError as ex:
        if ex.code != "OTP_REQUIRED" or otp or non_interactive or not sys.stdin.isatty():
            raise
        result = auth.login(server, username, password, getpass.getpass("NAS OTP: "), remember)
    emit("login", {"status": "authenticated", **result}, json_mode)


@app.command()
def logout(json_mode: bool = typer.Option(False, "--json")):
    auth.logout()
    emit("logout", {"status": "logged_out"}, json_mode)


@auth_app.command("status")
def auth_status(json_mode: bool = typer.Option(False, "--json")):
    execute("auth.status", json_mode, lambda api: {"status": "authenticated", **auth.load_profile()})


@auth_app.command("set-server")
def auth_set_server(server: str = typer.Option(..., "--server"),
                    json_mode: bool = typer.Option(False, "--json")):
    """저장된 로그인을 유지하면서 같은 NAS의 접속 URL을 변경합니다."""
    emit("auth.set-server", auth.set_server(server), json_mode)


@stack_app.command("list")
def stacks(json_mode: bool = typer.Option(False, "--json")):
    execute("stack.list", json_mode, lambda api: {"status": "ok", "stacks": sorted({v["stack"] for v in api.notebooks()})})


@book_app.command("list")
def notebooks(stack: str | None = typer.Option(None, "--stack"),
              json_mode: bool = typer.Option(False, "--json")):
    execute("notebook.list", json_mode, lambda api: {"status": "ok", "notebooks": [
        v for v in api.notebooks() if stack is None or v["stack"] == stack]})


@note_app.command("list")
def notes(stack: str | None = typer.Option(None, "--stack"),
          notebook: str | None = typer.Option(None, "--notebook"),
          notebook_id: str | None = typer.Option(None, "--notebook-id"),
          json_mode: bool = typer.Option(False, "--json")):
    from .transfers import select_notebook
    def fetch(api):
        values = api.notes()
        if notebook or notebook_id:
            target = select_notebook(api, stack=stack, notebook=notebook, notebook_id=notebook_id)
            values = [v for v in values if v["notebook_id"] == target["id"]]
        return {"status": "ok", "notes": values}
    execute("note.list", json_mode, fetch)


@note_app.command("info")
def note_info(note_id: str = typer.Option(..., "--id"),
              json_mode: bool = typer.Option(False, "--json")):
    from .transfers import verified_source
    def fetch(api):
        note = api.fetch(note_id)
        try:
            source, _, _ = verified_source(api, note)
        except CLIError as ex:
            if ex.code not in ("INVALID_SOURCE", "UNSUPPORTED_DOCUMENT_TYPE"):
                raise
            source = None
        return {"status": "ok", "note_id": note.id, "title": note.title,
                "notebook_id": note.notebook_id, "remote_version": note.version,
                "document_type": "verified_markdown" if source else "unverified",
                "document_id": source.document_id if source else None}
    execute("note.info", json_mode, fetch)


@app.command()
def download(note_id: str = typer.Option(..., "--id"),
             output: Path = typer.Option(..., "--output"),
             force_local: bool = typer.Option(False, "--force-local"),
             json_mode: bool = typer.Option(False, "--json"),
             non_interactive: bool = typer.Option(False, "--non-interactive")):
    execute("download", json_mode, lambda api: download_note(api, note_id, output, force=force_local))


@app.command()
def upload(path: Path, stack: str | None = typer.Option(None, "--stack"),
           notebook: str | None = typer.Option(None, "--notebook"),
           notebook_id: str | None = typer.Option(None, "--notebook-id"),
           title: str | None = typer.Option(None, "--title"),
           note_id: str | None = typer.Option(None, "--note-id"),
           overwrite: bool = typer.Option(False, "--overwrite"),
           compare_only: bool = typer.Option(False, "--diff"),
           json_mode: bool = typer.Option(False, "--json"),
           non_interactive: bool = typer.Option(False, "--non-interactive")):
    api = connected()
    try:
        result = upload_note(api, path, stack=stack, notebook=notebook,
                             notebook_id=notebook_id, title=title, note_id=note_id,
                             overwrite=overwrite, compare_only=compare_only)
        emit("upload", result, json_mode)
        if result["status"] == "different":
            raise typer.Exit(3)
    finally:
        api.close()


@op_app.command("status")
def op_status(operation_id: str = typer.Option(..., "--id"),
              json_mode: bool = typer.Option(False, "--json")):
    execute("operation.status", json_mode, lambda api: operation_status(api, operation_id))


@op_app.command("recover")
def op_recover(operation_id: str = typer.Option(..., "--id"),
               json_mode: bool = typer.Option(False, "--json")):
    execute("operation.recover", json_mode, lambda api: operation_status(api, operation_id))


@index_app.command("build")
def index_build(stack: str = typer.Option(..., "--stack"),
                index_notebook: str = typer.Option("llm-index", "--index-notebook"),
                project_min_days: int = typer.Option(3, "--project-min-days", min=2),
                apply: bool = typer.Option(False, "--apply"),
                dry_run: bool = typer.Option(False, "--dry-run"),
                json_mode: bool = typer.Option(False, "--json")):
    """일일 노트의 전체·프로젝트·주제·연관 지식 인덱스를 생성합니다 (기본 dry-run)."""
    if apply and dry_run:
        raise CLIError("INVALID_ARGUMENT", "--apply와 --dry-run은 함께 사용할 수 없습니다.")
    execute("index.build", json_mode, lambda api: build_index(
        api, stack=stack, index_notebook=index_notebook, apply=apply,
        project_min_days=project_min_days))


def run():
    try:
        app(standalone_mode=False)
    except ClickException as ex:
        if "--json" in sys.argv:
            typer.echo(json.dumps({"schema_version": 1, "action": "error", "status": "error",
                                   "uploaded": False, "error": {"code": "INVALID_ARGUMENT", "message": ex.format_message()}},
                                  ensure_ascii=False))
        else:
            typer.echo(f"INVALID_ARGUMENT: {ex.format_message()}", err=True)
        raise SystemExit(2) from None
    except CLIError as ex:
        data = {"schema_version": 1, "action": "error", "status": "error",
                "uploaded": False, "error": {"code": ex.code, "message": str(ex)}, **ex.details}
        if "--json" in sys.argv:
            typer.echo(json.dumps(data, ensure_ascii=False))
        else:
            typer.echo(f"{ex.code}: {ex}", err=True)
            if ex.details.get("diff"):
                typer.echo(ex.details["diff"])
        raise SystemExit(ex.exit_code) from None
    except typer.Exit as ex:
        raise SystemExit(ex.exit_code) from None


if __name__ == "__main__":
    run()
