import importlib.util
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_release_source", ROOT / "script/check_release_source.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


@pytest.fixture
def repository(tmp_path):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=tmp_path, text=True).strip()

    git("init", "--initial-branch=main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.invalid")
    git("commit", "--allow-empty", "-m", "released")
    released = git("rev-parse", "HEAD")
    git("update-ref", "refs/remotes/origin/main", released)
    git("checkout", "-b", "develop")
    git("commit", "--allow-empty", "-m", "unreleased")
    return tmp_path, git, released


def test_unmerged_develop_tag_is_rejected(repository):
    path, _, _ = repository
    with pytest.raises(ValueError, match="not included in origin/main"):
        policy.validate(path, "push", "tag", "v1.2.18")


def test_main_commit_can_be_released_after_main_advances(repository):
    path, git, released = repository
    git("update-ref", "refs/remotes/origin/main", git("rev-parse", "HEAD"))
    git("checkout", "--detach", released)
    policy.validate(path, "push", "tag", "v1.2.17")


@pytest.mark.parametrize("ref_type,ref_name", [
    ("branch", "develop"), ("branch", "main"), ("tag", "v1.2.17"), ("branch", "feature/test"),
])
def test_manual_release_is_always_rejected(tmp_path, ref_type, ref_name):
    with pytest.raises(ValueError, match="version tag pushed from main"):
        policy.validate(tmp_path, "workflow_dispatch", ref_type, ref_name)


def test_branch_push_cannot_start_a_release(tmp_path):
    with pytest.raises(ValueError, match="version tag pushed from main"):
        policy.validate(tmp_path, "push", "branch", "main")
