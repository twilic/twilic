#!/usr/bin/env python3
"""Emit spec/twilic/core/coverage_boost_spec.lua from twilic-go coverage_boost_test.go."""

from __future__ import annotations

import re
from pathlib import Path

GO = Path(__file__).resolve().parents[2] / "go" / "internal" / "core" / "coverage_boost_test.go"
OUT = Path(__file__).resolve().parents[1] / "spec" / "twilic" / "core" / "coverage_boost_spec.lua"

HEADER = r'''local tw = require("twilic")
local model = require("twilic.core.model")
local wire = require("twilic.core.wire")
local codec_mod = require("twilic.core.codec")
local byte_buffer = require("twilic.core.byte_buffer")
local protocol = require("twilic.core.protocol")
local session = require("twilic.core.session")
local dictionary = require("twilic.core.dictionary")
local H = require("spec.test_helpers")

local I64_CODECS = {
  model.VECTOR_CODEC_PLAIN,
  model.VECTOR_CODEC_DIRECT_BITPACK,
  model.VECTOR_CODEC_DELTA_BITPACK,
  model.VECTOR_CODEC_FOR_BITPACK,
  model.VECTOR_CODEC_DELTA_FOR_BITPACK,
  model.VECTOR_CODEC_DELTA_DELTA_BITPACK,
  model.VECTOR_CODEC_RLE,
  model.VECTOR_CODEC_PATCHED_FOR,
  model.VECTOR_CODEC_SIMPLE8B,
}

describe("coverage boost", function()
'''

FOOTER = "\nend)\n"

# Hand-maintained bodies keyed by Go test suffix (after TestCoverageBoost_)
BODIES: dict[str, str] = {
    "ModelFromByteAndDisplayBranches": '''  it("model from_byte branches", function()
    local _, ok = model.message_kind_from_byte(0x0D)
    assert.is_true(ok)
    _, ok = model.message_kind_from_byte(0xFE)
    assert.is_false(ok)
    _, ok = model.string_mode_from_byte(4)
    assert.is_true(ok)
    _, ok = model.string_mode_from_byte(9)
    assert.is_false(ok)
    _, ok = model.element_type_from_byte(6)
    assert.is_true(ok)
    _, ok = model.element_type_from_byte(9)
    assert.is_false(ok)
    _, ok = model.vector_codec_from_byte(12)
    assert.is_true(ok)
    _, ok = model.vector_codec_from_byte(99)
    assert.is_false(ok)
    _, ok = model.control_opcode_from_byte(5)
    assert.is_true(ok)
    _, ok = model.control_opcode_from_byte(7)
    assert.is_false(ok)
    _, ok = model.patch_opcode_from_byte(8)
    assert.is_true(ok)
    _, ok = model.patch_opcode_from_byte(42)
    assert.is_false(ok)
    _, ok = model.control_stream_codec_from_byte(4)
    assert.is_true(ok)
    _, ok = model.control_stream_codec_from_byte(7)
    assert.is_false(ok)
  end)
''',
}

def main() -> None:
    text = GO.read_text()
    names = re.findall(r"func TestCoverageBoost_(\w+)\(t \*testing\.T\)", text)
    if not names:
        raise SystemExit("no tests found in go file")
    parts = [HEADER]
    for name in names:
        if name in BODIES:
            parts.append(BODIES[name])
        else:
            parts.append(
                f'  pending("{name} — port from go/ruby coverage_boost_test")\n'
            )
    parts.append(FOOTER)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("".join(parts))
    print(f"wrote {OUT} ({len(names)} tests, {sum(1 for n in names if n in BODIES)} implemented)")


if __name__ == "__main__":
    main()
