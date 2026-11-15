"""Exercise durable reservations independently of NAS availability."""
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from synonote_web.store import Store


def test_multiple_connections_reserve_only_once_and_encrypt_intent(tmp_path):
    stores = [Store(tmp_path), Store(tmp_path)]
    barrier = threading.Barrier(8)
    def reserve(i):
        barrier.wait()
        return stores[i % 2].start_write(str(i), 'owner', 'note', 'note', 'title', {'html': 'private-body'})
    with ThreadPoolExecutor(8) as pool:
        assert sum(pool.map(reserve, range(8))) == 1
    rows = stores[0].pending_writes('owner')
    assert len(rows) == 1
    assert not stores[0].acknowledge_write('owner', rows[0]['operation_id'])
    stores[0].finish_write(rows[0]['operation_id'], uncertain=True)
    assert not Store(tmp_path).start_write('next', 'owner', 'note', 'note', 'title', {})
    with sqlite3.connect(tmp_path / 'web.sqlite3') as db:
        encrypted = db.execute('SELECT intent FROM write_operations').fetchone()[0]
    assert b'private-body' not in encrypted
    assert b'private-body' in stores[0].cipher.decrypt(encrypted)
    assert not stores[0].acknowledge_write('other-owner', rows[0]['operation_id'])
    assert stores[0].acknowledge_write('owner', rows[0]['operation_id'])
    assert stores[1].start_write('next', 'owner', 'note', 'note', 'title', {})


def test_migration_keeps_duplicate_legacy_intents_until_all_acknowledged(tmp_path):
    store = Store(tmp_path)
    assert store.start_write('a', 'owner', 'note', 'note', 'title', {})
    with store.connect() as db:
        db.execute('DROP TABLE write_target_locks')
        db.execute("INSERT INTO write_operations SELECT 'b',owner,target,note_id,title,intent,status,created FROM write_operations")
        db.execute('UPDATE write_operations SET created=?', (time.time() - 3601,))
    migrated = Store(tmp_path)
    assert len(migrated.pending_writes('owner')) == 2
    assert migrated.acknowledge_write('owner', 'a')
    assert not migrated.start_write('c', 'owner', 'note', 'note', 'title', {})
    assert migrated.acknowledge_write('owner', 'b')
    assert migrated.start_write('c', 'owner', 'note', 'note', 'title', {})


def test_concurrent_acknowledgements_have_single_winner(tmp_path):
    store = Store(tmp_path)
    store.start_write('a', 'owner', 'note', 'note', 'title', {})
    store.finish_write('a', uncertain=True)
    barrier = threading.Barrier(8)
    def ack(_):
        barrier.wait()
        return store.acknowledge_write('owner', 'a')
    with ThreadPoolExecutor(8) as pool:
        assert sum(pool.map(ack, range(8))) == 1
    assert store.start_write('b', 'owner', 'note', 'note', 'title', {})
