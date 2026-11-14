import base64
import json
from pathlib import Path

import pytest

from synonote_cli.errors import CLIError
from synonote_cli.markdown import render
from synonote_cli.source_envelope import SourceEnvelope

FIXTURES = Path(__file__).resolve().parents[2] / "contracts/source-envelope/fixtures.json"


@pytest.fixture(scope="module")
def fixtures():
    return json.loads(FIXTURES.read_text(encoding="utf-8"))


def test_swift_python_envelopes_match_exact_bytes(fixtures):
    for name, row in fixtures["envelopes"].items():
        raw = base64.b64decode(row["encoded_base64"])
        source = SourceEnvelope.decode(raw)
        assert source.markdown == row["markdown"], name
        assert source.matches(row["html"]), name
        assert source.encode() == raw, name


def test_swift_python_html_exact(fixtures):
    for index, sample in enumerate(fixtures["render"]):
        assert render(sample["markdown"]) == sample["html"], index


def test_swift_python_preserved_block_html_exact(fixtures):
    for sample in fixtures["render_blocks"]:
        assert render(sample["markdown"], blocks=sample["blocks"]) == sample["html"]


def test_tamper_detected(fixtures):
    raw = base64.b64decode(fixtures["envelopes"]["v1"]["encoded_base64"])
    with pytest.raises(CLIError) as error:
        SourceEnvelope.decode(raw + b"oops")
    assert error.value.code == "INVALID_SOURCE"


def test_staging_is_never_verified():
    source = SourceEnvelope.make("# 임시", "<h1>임시</h1>", is_staging=True)
    assert not SourceEnvelope.decode(source.encode()).matches("<h1>임시</h1>")
