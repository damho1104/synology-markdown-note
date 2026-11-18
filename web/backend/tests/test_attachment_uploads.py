import base64
import hashlib
import uuid
from concurrent.futures import ThreadPoolExecutor

import pytest

from synonote_web.store import Store


@pytest.fixture
def storage(tmp_path):
    from synonote_web.attachment_uploads import Uploads

    store = Store(tmp_path)
    return store, Uploads(store)


def ids():
    return str(uuid.uuid4()), str(uuid.uuid4())


def receive(uploads, keys, content=b"attachment bytes", *, owner="owner",
            target="note", name="sample.bin"):
    receipt = uploads.reserve(owner, *keys, target, "book", name, len(content))
    midpoint = len(content) // 2
    for chunk in (content[:midpoint], content[midpoint:]):
        uploads.append(receipt, chunk)
    return uploads.publish(receipt)


def assert_error(code, func, *args, **kwargs):
    from synonote_web.attachment_uploads import UploadError

    with pytest.raises(UploadError) as raised:
        func(*args, **kwargs)
    assert raised.value.code == code
    assert 400 <= raised.value.status < 600


def test_bytes_and_receipt_survive_restart_without_plaintext(storage):
    from synonote_web.attachment_uploads import Uploads

    store, uploads = storage
    keys = ids()
    content = b"private attachment marker not to be written as plaintext"
    metadata = receive(uploads, keys, content)
    assert metadata == dict(draft_id=keys[0], upload_id=keys[1], target="note",
                           notebook_id="book", name="sample.bin", size=len(content),
                           sha256=hashlib.sha256(content).hexdigest(),
                           mime="application/octet-stream", image=False, status="ready")
    for path in store.dir.iterdir():
        assert content not in path.read_bytes()
    restarted = Uploads(Store(store.dir))
    assert restarted.get("owner", *keys) == metadata
    assert b"".join(restarted.iter_content("owner", *keys)) == content
    assert_error("UPLOAD_NOT_FOUND", restarted.get, "another owner", *keys)
    assert_error("UPLOAD_NOT_FOUND", restarted.delete, "owner", ids()[0], keys[1])


def test_stream_can_resume_on_another_worker_thread(storage):
    _, uploads = storage
    keys = ids()
    receive(uploads, keys, b"abcd")
    chunks = uploads.iter_content("owner", *keys)
    with ThreadPoolExecutor(max_workers=1) as first, ThreadPoolExecutor(max_workers=1) as second:
        assert first.submit(next, chunks).result() == b"ab"
        assert second.submit(next, chunks).result() == b"cd"
        assert second.submit(next, chunks, None).result() is None


def test_retries_compare_content_and_do_not_replace_published_file(storage):
    _, uploads = storage
    keys = ids()
    metadata = receive(uploads, keys, b"1234")
    assert receive(uploads, keys, b"1234") == metadata
    assert_error("UPLOAD_ID_REUSED", receive, uploads, keys, b"4321")
    assert b"".join(uploads.iter_content("owner", *keys)) == b"1234"


def test_size_caps_and_abort(storage):
    from synonote_web.attachment_uploads import MAX_UPLOAD_SIZE

    _, uploads = storage
    assert MAX_UPLOAD_SIZE == 50_000_000
    keys = ids()
    assert_error("ATTACHMENT_TOO_LARGE", uploads.reserve,
                 "owner", *keys, "note", "book", "file", MAX_UPLOAD_SIZE + 1)
    receipt = uploads.reserve("owner", *keys, "note", "book", "file", MAX_UPLOAD_SIZE)
    assert uploads.get("owner", *keys)["status"] == "receiving"
    uploads.abort(receipt)
    receipt = uploads.reserve("owner", *keys, "note", "book", "file", 4)
    uploads.abort(receipt)
    replacement = uploads.reserve("owner", *keys, "note", "book", "file", 4)
    assert_error("UPLOAD_NOT_FOUND", uploads.append, receipt, b"1234")
    assert_error("UPLOAD_SIZE_MISMATCH", uploads.append, replacement, b"12345")
    uploads.abort(replacement)
    assert_error("UPLOAD_NOT_FOUND", uploads.get, "owner", *keys)


def test_quota_counts_reservations_across_store_instances(storage, monkeypatch):
    import synonote_web.attachment_uploads as module

    assert module.DRAFT_QUOTA == 150_000_000
    monkeypatch.setattr(module, "DRAFT_QUOTA", 10)

    store, uploads = storage
    other = module.Uploads(Store(store.dir))
    draft, _ = ids()
    receive(uploads, (draft, ids()[1]), b"ready")
    reservation = uploads.reserve("owner", draft, ids()[1], "note", "book", "partial", 5)
    uploads.append(reservation, b"x")
    assert_error("UPLOAD_QUOTA_EXCEEDED", other.reserve,
                 "owner", draft, ids()[1], "note", "book", "one more", 1)
    uploads.abort(reservation)
    other.reserve("owner", draft, ids()[1], "note", "book", "now fits", 5)


def test_lease_expiry_and_stale_receipt(storage, monkeypatch):
    import synonote_web.attachment_uploads as module

    store, uploads = storage
    now = 1000
    monkeypatch.setattr(module.time, "time", lambda: now)
    keys = ids()
    old = uploads.reserve("owner", *keys, "note", "book", "file", 4)
    uploads.append(old, b"old")
    assert_error("UPLOAD_RECEIVING", uploads.reserve,
                 "owner", *keys, "note", "book", "file", 4)
    now += 631
    restarted = module.Uploads(Store(store.dir))
    new = restarted.reserve("owner", *keys, "note", "book", "file", 4)
    uploads.abort(old)
    restarted.append(new, b"new!")
    assert restarted.publish(new)["status"] == "ready"
    assert b"".join(restarted.iter_content("owner", *keys)) == b"new!"
    now += 7 * 86400 + 1
    assert_error("UPLOAD_NOT_FOUND", restarted.get, "owner", *keys)


def test_pin_is_atomic_and_confirmed_write_reclaims_content(storage):
    store, uploads = storage
    keys = ids()
    metadata = receive(uploads, keys)
    manifest = (*keys, "note", "book", metadata["sha256"])

    with pytest.raises(Exception) as raised:
        store.start_write("invalid", "owner", "note", "note", "Title",
                          {"notebook_id": "book"}, upload_keys=[manifest, (*ids(), *manifest[2:])])
    assert getattr(raised.value, "code", None) == "UPLOAD_NOT_FOUND"
    assert store.pending_writes("owner") == []
    assert uploads.get("owner", *keys)["status"] == "ready"
    assert store.start_write("valid", "owner", "note", "note", "Title",
                             {"notebook_id": "book"}, upload_keys=[manifest])
    assert uploads.get("owner", *keys)["status"] == "pinned"
    assert_error("UPLOAD_PINNED", uploads.delete, "owner", *keys)
    store.finish_write("valid", uncertain=False, result={"id": "note"})
    assert uploads.get("owner", *keys)["status"] == "committed"
    assert receive(uploads, keys)["status"] == "committed"
    assert_error("UPLOAD_NOT_FOUND", lambda: list(uploads.iter_content("owner", *keys)))


def test_preflight_release_and_uncertain_ack_retains_bytes(storage, monkeypatch):
    import synonote_web.attachment_uploads as module

    store, uploads = storage
    now = 1000
    monkeypatch.setattr(module.time, "time", lambda: now)
    keys = ids()
    client_id = ids()[0]
    target = "draft-create:" + client_id
    metadata = receive(uploads, keys, target=target)
    manifest = [(*keys, target, "book", metadata["sha256"])]
    intent = {"notebook_id": "book"}

    assert store.start_write("preflight", "owner", "new:lock", None, "Title", intent,
                             client_request_id=client_id, request_hash="hash", upload_keys=manifest)
    store.finish_write("preflight", uncertain=False)
    assert uploads.get("owner", *keys)["status"] == "ready"
    assert store.start_write("unknown", "owner", "new:lock", None, "Title", intent,
                             client_request_id=client_id, request_hash="hash", upload_keys=manifest)
    store.finish_write("unknown", uncertain=True)
    assert_error("UPLOAD_PINNED", uploads.delete, "owner", *keys)
    assert store.acknowledge_write("owner", "unknown")
    store.finish_write("unknown", uncertain=False)
    store.finish_write("unknown", uncertain=False, result={"id": "late-result"})
    assert uploads.get("owner", *keys)["status"] == "reviewed"
    assert b"".join(uploads.iter_content("owner", *keys)) == b"attachment bytes"
    assert store.create_receipt("owner", client_id)["status"] == "reviewed"
    assert_error("UPLOAD_NOT_READY", store.start_write, "retry", "owner", target, target, "Title",
                 intent, upload_keys=manifest)

    monkeypatch.setattr(module, "OWNER_QUOTA", len(b"attachment bytes"))
    assert_error("UPLOAD_QUOTA_EXCEEDED", receive, uploads, ids())
    now += 8 * 86400
    assert receive(uploads, ids())["status"] == "ready"
    assert_error("UPLOAD_NOT_FOUND", uploads.get, "owner", *keys)
    assert_error("UPLOAD_ID_REUSED", receive, uploads, keys, target=target)


def test_legacy_acknowledged_upload_is_discardable_without_affecting_active_upload(storage):
    from synonote_web.attachment_uploads import Uploads

    store, uploads = storage
    legacy, active = ids(), ids()
    for keys, operation in ((legacy, "legacy"), (active, "active")):
        meta = receive(uploads, keys, target=operation)
        assert store.start_write(operation, "owner", operation, operation, "Title", {},
                                 upload_keys=[(*keys, operation, "book", meta["sha256"])])
    # Simulate an ack produced by a previous installation.
    with store.connect() as db:
        db.execute("DELETE FROM write_operations WHERE operation_id='legacy'")
    uploads = Uploads(Store(store.dir))
    assert uploads.get("owner", *legacy)["status"] == "reviewed"
    assert_error("UPLOAD_NOT_FOUND", uploads.delete, "other", *legacy)
    uploads.delete("owner", *legacy)
    assert_error("UPLOAD_NOT_FOUND", uploads.get, "owner", *legacy)
    assert_error("UPLOAD_ID_REUSED", receive, uploads, legacy, target="legacy")
    assert_error("UPLOAD_PINNED", uploads.delete, "owner", *active)
    with store.connect() as db:
        remaining = db.execute("""SELECT u.upload_id FROM draft_upload_chunks AS c
                                  JOIN draft_uploads AS u USING (upload_key)""").fetchall()
    assert {row["upload_id"] for row in remaining} == {active[1]}


def test_image_requires_valid_server_detected_structure(storage):
    _, uploads = storage
    gif = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
    assert receive(uploads, ids(), gif)["mime"] == "image/gif"
    assert not receive(uploads, ids(), gif[:-1], name="truncated.gif")["image"]
    assert not receive(uploads, ids(), b"<svg></svg>", name="image.png")["image"]


def test_deleted_receipt_cannot_publish(storage):
    _, uploads = storage
    keys = ids()
    receipt = uploads.reserve("owner", *keys, "note", "book", "file", 4)
    uploads.append(receipt, b"data")
    uploads.delete("owner", *keys)
    assert_error("UPLOAD_NOT_FOUND", uploads.publish, receipt)


@pytest.mark.parametrize(("mime", "encoded"), [
    ("image/png",
     "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADAQMAAACDJEzCAAAAA1BMVEX/AAAZ4gk3AAAAC0lEQVQI12NgAAEAAAYAAWb0yWwAAAAASUVORK5CYII="),
    ("image/jpeg",
     "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/"
     "2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/"
     "wAARCAADAAIDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/"
     "xAAVAQEBAAAAAAAAAAAAAAAAAAAHCf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/ADoDFU3/2Q=="),
    ("image/webp",
     "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAMAAgA0JaACdLoB+AADsAD+8MQL/yC5YXXI1/8gP+QH/ID/+PIAAAA="),
])
def test_recognizes_supported_images_across_chunks(storage, mime, encoded):
    _, uploads = storage
    image = base64.b64decode(encoded)
    keys = ids()
    receipt = uploads.reserve("owner", *keys, "note", "book", "wrong.bin", len(image))
    for start in range(0, len(image), 5):
        uploads.append(receipt, image[start:start + 5])
    assert uploads.publish(receipt)["mime"] == mime
    assert not receive(uploads, ids(), image[:-1])["image"]
    assert not receive(uploads, ids(), image + b"<script>")["image"]


def test_owner_and_installation_quotas_cover_other_drafts_and_owners(storage, monkeypatch):
    import synonote_web.attachment_uploads as module

    assert (module.OWNER_QUOTA, module.INSTALLATION_QUOTA) == (300_000_000, 1_000_000_000)
    monkeypatch.setattr(module, "OWNER_QUOTA", 12)
    monkeypatch.setattr(module, "INSTALLATION_QUOTA", 24)
    _, uploads = storage
    for owner in ("a", "b"):
        for _ in range(3):
            receive(uploads, ids(), b"1234", owner=owner)
    assert_error("UPLOAD_QUOTA_EXCEEDED", receive, uploads, ids(), b"1234", owner="a")
    assert_error("UPLOAD_QUOTA_EXCEEDED", receive, uploads, ids(), b"1234", owner="c")


def test_manifest_cannot_pin_another_target_or_hash(storage):
    store, uploads = storage
    keys = ids()
    metadata = receive(uploads, keys)
    for target, notebook, digest in [
        ("note-2", "book", metadata["sha256"]),
        ("note", "other-book", metadata["sha256"]),
        ("note", "book", "0" * 64),
    ]:
        from synonote_web.attachment_uploads import UploadError

        with pytest.raises(UploadError, match="UPLOAD_MANIFEST_MISMATCH"):
            store.start_write("op", "owner", "note", "note", "Title",
                              {"notebook_id": "book"}, upload_keys=[(*keys, target, notebook, digest)])
    assert not store.pending_writes("owner")
    assert uploads.get("owner", *keys)["status"] == "ready"



def test_receiving_limits_include_replays_and_expire_across_instances(storage, monkeypatch):
    from synonote_web import attachment_uploads as module

    store, uploads = storage
    other = module.Uploads(Store(store.dir))
    now = 1000
    monkeypatch.setattr(module.time, "time", lambda: now)

    def reserve(owner, keys):
        return other.reserve(owner, *keys, "note", "book", "sample.bin", 4)

    replay_keys = ids()
    receive(uploads, replay_keys, b"1234", owner="a")
    replay = reserve("a", replay_keys)
    reserve("a", ids())
    assert_error("UPLOAD_RECEIVING_LIMIT", reserve, "a", ids())
    for owner in ("b", "c", "d"):
        reserve(owner, ids())
        reserve(owner, ids())
    assert_error("UPLOAD_RECEIVING_LIMIT", reserve, "e", ids())
    uploads.abort(replay)
    reserve("e", ids())
    now += 601
    assert_error("UPLOAD_RECEIVING_LIMIT", reserve, "f", ids())
    now += 30
    reserve("f", ids())
    assert other.get("a", *replay_keys)["status"] == "ready"



def test_concurrent_receivers_do_not_overbook_installation(storage):
    from synonote_web.attachment_uploads import UploadError

    _, uploads = storage

    def reserve(index):
        try:
            uploads.reserve(f"owner-{index}", *ids(), "note", "book", "file", 4)
        except UploadError as exc:
            return exc.code
        return "reserved"

    with ThreadPoolExecutor(max_workers=12) as workers:
        outcomes = list(workers.map(reserve, range(12)))
    assert outcomes.count("reserved") == 8
    assert outcomes.count("UPLOAD_RECEIVING_LIMIT") == 4


def test_streams_exact_limit_in_bounded_chunks(storage):
    from synonote_web.attachment_uploads import MAX_UPLOAD_SIZE

    _, uploads = storage
    keys = ids()
    receipt = uploads.reserve("owner", *keys, "note", "book", "file", MAX_UPLOAD_SIZE)
    block = b"x" * (256 * 1024)
    expected = hashlib.sha256()
    for offset in range(0, MAX_UPLOAD_SIZE, len(block)):
        chunk = block[:MAX_UPLOAD_SIZE - offset]
        uploads.append(receipt, chunk)
        expected.update(chunk)
    assert_error("ATTACHMENT_TOO_LARGE", uploads.append, receipt, b"x")
    assert uploads.publish(receipt)["sha256"] == expected.hexdigest()
    digest = hashlib.sha256()
    for chunk in uploads.iter_content("owner", *keys):
        assert len(chunk) <= len(block)
        digest.update(chunk)
    assert digest.hexdigest() == expected.hexdigest()


def test_structural_image_validation_has_a_record_budget(storage, monkeypatch):
    import synonote_web.attachment_uploads as module

    monkeypatch.setattr(module, "_MAX_IMAGE_RECORDS", 3, raising=False)
    _, uploads = storage
    gif = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")
    assert not receive(uploads, ids(), gif)["image"]
