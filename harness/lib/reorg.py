#!/usr/bin/env python3
"""Normalize raw run outputs into the canonical harness result layout.

Read-only of its inputs (it copies, never moves) and LLM-free.

Usage:
    python3 reorg.py <raw-dir> <iteration-dir>

Input contract — `<raw-dir>` holds one directory per run, each containing a `meta.json`:

    <raw-dir>/
      <anything>/
        meta.json        # {"eval_id": "...", "configuration": "with_skill"|"without_skill", "run_number": N}
        grading.json     # optional — placed at the run root
        timing.json      # optional — placed at the run root
        AGENTS.md ...    # any other file or dir — placed under outputs/

As a fallback when there is no meta.json, the run directory name may encode the fields as
    eval-<id>__<config>__run-<N>     (e.g. eval-fresh-wired__with_skill__run-1)

Unparseable directories are skipped with a printed `skip ...` line rather than aborting the
batch, so one bad run never costs you the others.

Output (canonical) per run:
    <iteration-dir>/eval-<id>/<config>/run-<N>/
        ├── grading.json
        ├── timing.json
        └── outputs/        # everything else

Self-test (synthesizes a raw dir and checks the canonical tree):
    python3 reorg.py --selftest
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

CONFIGS = ("with_skill", "without_skill")
ROOT_FILES = ("grading.json", "timing.json")
_NAME_RE = re.compile(r"^eval-(?P<eval_id>.+?)__(?P<config>with_skill|without_skill)__run-(?P<run>\d+)$")


def _resolve_meta(run_dir: Path) -> dict | None:
    meta_file = run_dir / "meta.json"
    if meta_file.is_file():
        meta = json.loads(meta_file.read_text(encoding="utf-8"))
        if {"eval_id", "configuration", "run_number"} <= meta.keys():
            return meta
    m = _NAME_RE.match(run_dir.name)
    if m:
        return {"eval_id": m["eval_id"], "configuration": m["config"],
                "run_number": int(m["run"])}
    return None


def reorg(raw_dir: Path, iteration_dir: Path) -> list[Path]:
    raw_dir, iteration_dir = Path(raw_dir), Path(iteration_dir)
    written: list[Path] = []
    for run_dir in sorted(p for p in raw_dir.iterdir() if p.is_dir()):
        meta = _resolve_meta(run_dir)
        if meta is None:
            print(f"  skip {run_dir.name}: no meta.json and name not parseable")
            continue
        if meta["configuration"] not in CONFIGS:
            print(f"  skip {run_dir.name}: bad configuration {meta['configuration']!r}")
            continue
        dest = (iteration_dir / f"eval-{meta['eval_id']}" /
                meta["configuration"] / f"run-{meta['run_number']}")
        (dest / "outputs").mkdir(parents=True, exist_ok=True)
        for item in run_dir.iterdir():
            if item.name == "meta.json":
                continue
            if item.name in ROOT_FILES and item.is_file():
                shutil.copy2(item, dest / item.name)
            elif item.is_file():
                shutil.copy2(item, dest / "outputs" / item.name)
            elif item.is_dir():
                shutil.copytree(item, dest / "outputs" / item.name, dirs_exist_ok=True)
        written.append(dest)
    return written


def _selftest() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "raw"
        # one run via meta.json, one via the name-pattern fallback, one unparseable
        r1 = raw / "anything"
        (r1 / "src").mkdir(parents=True)
        (r1 / "meta.json").write_text(json.dumps(
            {"eval_id": "fresh-wired", "configuration": "with_skill", "run_number": 1}))
        (r1 / "grading.json").write_text("{}")
        (r1 / "AGENTS.md").write_text("# AGENTS")
        (r1 / "src" / "index.ts").write_text("export const x = 1;")
        r2 = raw / "eval-fresh-wired__without_skill__run-1"
        r2.mkdir()
        (r2 / "timing.json").write_text("{}")
        (raw / "junk-dir").mkdir()

        it = Path(tmp) / "iteration-1"
        written = reorg(raw, it)
        assert len(written) == 2, written
        run1 = it / "eval-fresh-wired" / "with_skill" / "run-1"
        assert (run1 / "grading.json").is_file(), "grading.json belongs at the run root"
        assert (run1 / "outputs" / "AGENTS.md").is_file(), "other files belong under outputs/"
        assert (run1 / "outputs" / "src" / "index.ts").is_file(), "dirs are copied recursively"
        assert not (run1 / "meta.json").exists(), "meta.json is consumed, not copied"
        assert (it / "eval-fresh-wired" / "without_skill" / "run-1" / "timing.json").is_file()
        print("reorg selftest OK — normalized", len(written), "runs")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return _selftest()
    if len(argv) < 2:
        print(__doc__)
        return 2
    raw_dir, iteration_dir = Path(argv[0]), Path(argv[1])
    if not raw_dir.is_dir():
        print(f"no such raw dir: {raw_dir}")
        return 1
    written = reorg(raw_dir, iteration_dir)
    for d in written:
        print(f"  -> {d}")
    print(f"normalized {len(written)} run(s) into {iteration_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
