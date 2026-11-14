import pytest

from synonote_cli.build_version import build_version, checked_build_version, release_version


@pytest.mark.parametrize("tag", ["1.2.17", "v1.2.17"])
def test_release_build_has_no_commit_suffix(monkeypatch, tmp_path, tag):
    monkeypatch.setenv("SYNOLOGY_NOTE_RELEASE_TAG", tag)
    # Release version resolution works without Git or a stamped distribution.
    assert build_version("1.2.17", tmp_path) == "1.2.17"


@pytest.mark.parametrize("tag", ["v1.2.17-abcdef0", "1.2.17-abcdef0", "v1.2.18", "v01.2.17", "v1.2", "", "v1.2.17\n"])
def test_invalid_or_mismatched_tag_stops_release(tag):
    with pytest.raises(ValueError):
        release_version(tag, "1.2.17")


def test_development_build_retains_source_revision(monkeypatch, tmp_path):
    monkeypatch.delenv("SYNOLOGY_NOTE_RELEASE_TAG", raising=False)
    monkeypatch.setenv("SYNOLOGY_NOTE_GIT_COMMIT", "abcdef0")
    (tmp_path / ".git").mkdir()
    assert build_version("1.2.17", tmp_path) == "1.2.17-abcdef0"


@pytest.mark.parametrize("value", ["1.2.17", "1.2.17-abcdef0"])
def test_archive_build_retains_embedded_version(monkeypatch, tmp_path, value):
    monkeypatch.delenv("SYNOLOGY_NOTE_RELEASE_TAG", raising=False)
    stamp = tmp_path / "version.txt"
    stamp.write_text(value)
    assert build_version("1.2.17", tmp_path, stamp) == value


def test_stale_archive_version_is_rejected():
    with pytest.raises(ValueError):
        checked_build_version("1.2.16", "1.2.17")
