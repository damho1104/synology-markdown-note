"""Install the library action endpoint inside create_app, after its guards.

The host app supplies its existing Origin/JSON middleware and NasError handler.
No import of main or nas occurs during module initialization.

Payloads:
* note: id/version, favorite(bool), tags(list[str]), move(notebook id),
  trash/restore(no value).
* notebook: create(name, optional value=existing stack name), rename(id/name),
  move(id/value=existing stack name, or "" to ungroup).
* stack: create(name/value=nonempty notebook id list), rename(id=old name/name).
  Stack names are Unicode text, never NAS object identifiers.
"""
from __future__ import annotations

import uuid
from typing import Literal

from fastapi import HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field, model_validator

from .library_nas import LibraryPreflightError


def _text(value, *, empty: bool = False) -> bool:
    return (isinstance(value, str) and (bool(value) or empty) and len(value) <= 256
            and value == value.strip() and not any(ord(c) < 32 or ord(c) == 127 for c in value))


class LibraryActionInput(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    kind: Literal["note", "notebook", "stack"]
    id: str | None = Field(default=None, max_length=256)
    action: Literal["favorite", "tags", "trash", "restore", "move", "create", "rename", "delete"]
    version: str | None = Field(default=None, max_length=128)
    value: str | bool | list[str] | None = None
    name: str | None = Field(default=None, max_length=256)

    @model_validator(mode="after")
    def valid_action(self):
        valid = False
        if self.kind == "note":
            if not _text(self.id) or not _text(self.version) or self.name is not None:
                raise ValueError("NOTE_ID_AND_VERSION_REQUIRED")
            if self.action == "favorite":
                valid = type(self.value) is bool
            elif self.action == "tags":
                valid = (isinstance(self.value, list) and len(self.value) <= 500
                         and all(_text(v) for v in self.value)
                         and len(self.value) == len(set(self.value)))
            elif self.action == "move":
                valid = _text(self.value)
            elif self.action in {"trash", "restore"}:
                valid = self.value is None
        elif self.version is None:
            if self.action == "create":
                valid = self.id is None and _text(self.name)
                if self.kind == "stack":
                    valid = (valid and isinstance(self.value, list) and 0 < len(self.value) <= 500
                             and all(_text(v) for v in self.value)
                             and len(self.value) == len(set(self.value)))
                else:
                    valid = valid and (self.value is None or _text(self.value, empty=True))
            elif self.action == "rename":
                valid = _text(self.id) and _text(self.name) and self.value is None
            elif self.action == "delete":
                valid = _text(self.id) and self.name is None and self.value is None
            elif self.kind == "notebook" and self.action == "move":
                valid = _text(self.id) and self.name is None and _text(self.value, empty=True)
        if not valid:
            raise ValueError("INVALID_LIBRARY_ACTION")
        return self


def install_library_routes(app, *, nas, read_nas, nas_access, csrf_guard, checked_id, store):
    """Register inside create_app BEFORE app.mount("/"), using its guards/Store.

    Notes use the editor's exact target key (the NAS note ID). Catalog writes
    share one owner-scoped key, so an uncertain rename/create/move also blocks
    overlapping grouping changes until explicitly reviewed via existing /writes.
    """
    @app.post("/api/library/action")
    def library_action(body: LibraryActionInput, request: Request, response: Response):
        from .nas import NasError

        base, _, owner, csrf, _, _ = nas_access(request, response)
        csrf_guard(request, csrf)
        if body.kind in {"note", "notebook"} and body.id is not None:
            checked_id(body.id)
        if body.kind == "note" and body.action == "move":
            checked_id(body.value)
        if body.kind == "stack" and body.action == "create":
            for notebook_id in body.value:
                checked_id(notebook_id)
        # Stack id is its original arbitrary Unicode name; do NOT checked_id it.
        command = body.model_dump()
        operation_id = str(uuid.uuid4())
        target = body.id if body.kind == "note" else "library:catalog"
        if body.kind == "notebook" and body.action == "delete":
            target = store.NOTEBOOK_DELETE_TARGET
        note_id = body.id if body.kind == "note" else None
        title = body.name or body.id or body.action
        if not store.start_write(operation_id, owner, target, note_id, title, command):
            raise HTTPException(409, detail="WRITE_REVIEW_REQUIRED")
        started = False
        try:
            plan = read_nas(request, response, lambda url, login:
                            nas.preflight_library_action(url, login, command))
            # read_nas alone may reauthenticate: never replay the mutation through
            # it, and never retain the preflight's possibly expired SID.
            active_base, active, active_owner, active_csrf, _, _ = nas_access(request, response)
            csrf_guard(request, active_csrf)
            if active_base != base or plan.base != base or active_owner != owner:
                raise HTTPException(409, detail="REMOTE_CHANGED")
            started = True
            nas.apply_library_action(active_base, active, plan)
            store.finish_write(operation_id, uncertain=False)
        except Exception as exc:
            try:
                store.finish_write(operation_id, uncertain=started)
            except Exception as store_exc:
                # A failed status update leaves the original durable pending
                # reservation in place. It must not mask post-send uncertainty.
                if started:
                    raise NasError("WRITE_UNCERTAIN") from store_exc
                raise
            if started:
                raise NasError("WRITE_UNCERTAIN") from exc
            if isinstance(exc, LibraryPreflightError):
                raise HTTPException(exc.status_code, detail=exc.code) from exc
            raise
        return {"ok": True}
