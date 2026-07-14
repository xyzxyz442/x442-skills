#!/usr/bin/env python3
"""Aggregate per-run grading.json files into a benchmark.json + benchmark.md.

Reads the canonical result tree under an iteration directory:
    <iteration-dir>/eval-<id>/{with_skill,without_skill}/run-N/grading.json
and writes, into the same iteration directory:
    benchmark.json   # metadata + per-run rows + with/without/delta summary
    benchmark.md     # human-readable summary tables

Read-only and LLM-free: it only post-processes local grading.json files.

Usage:
    python3 aggregate.py <iteration-dir> [--executor-model NAME] [--timestamp ISO8601]

`timestamp`/`executor-model` are passed in, never generated, so re-aggregating a finished
iteration is byte-identical and produces no spurious diff. They fall back to the env vars
EVAL_TIMESTAMP / EVAL_EXECUTOR_MODEL, else null. Do not "helpfully" call datetime.now().

Self-test (synthesizes a tiny iteration in a temp dir and checks the delta math):
    python3 aggregate.py --selftest
"""

from __future__ import annotations

import json
import os
import re
import statistics
import sys
from pathlib import Path

CONFIGS = ("with_skill", "without_skill")
_RUN_RE = re.compile(r"run-(\d+)$")


def _load_runs(iteration_dir: Path) -> list[dict]:
    """Walk eval-<id>/<config>/run-<N>/grading.json into flat run rows."""
    runs: list[dict] = []
    for eval_dir in sorted(iteration_dir.glob("eval-*")):
        if not eval_dir.is_dir():
            continue
        eval_id = eval_dir.name[len("eval-"):]
        for config in CONFIGS:
            cfg_dir = eval_dir / config
            if not cfg_dir.is_dir():
                continue
            for run_dir in sorted(cfg_dir.glob("run-*")):
                grading = run_dir / "grading.json"
                if not grading.is_file():
                    continue
                m = _RUN_RE.search(run_dir.name)
                run_number = int(m.group(1)) if m else 0
                data = json.loads(grading.read_text(encoding="utf-8"))
                pass_rate = data.get("summary", {}).get("pass_rate")
                runs.append({
                    "eval_id": eval_id,
                    "configuration": config,
                    "run_number": run_number,
                    "result": {"pass_rate": pass_rate},
                })
    return runs


def _stats(values: list[float]) -> dict | None:
    """Population stddev (pstdev), not sample — these runs are the whole population."""
    if not values:
        return None
    return {
        "mean": round(statistics.mean(values), 4),
        "stddev": round(statistics.pstdev(values), 4) if len(values) > 1 else 0.0,
        "min": round(min(values), 4),
        "max": round(max(values), 4),
    }


def _rates(runs: list[dict], config: str, eval_id: str | None = None) -> list[float]:
    return [
        r["result"]["pass_rate"]
        for r in runs
        if r["configuration"] == config
        and r["result"]["pass_rate"] is not None
        and (eval_id is None or r["eval_id"] == eval_id)
    ]


def _fmt_delta(with_mean: float | None, without_mean: float | None) -> str | None:
    """None when either configuration is absent — the normal single-config case."""
    if with_mean is None or without_mean is None:
        return None
    return f"{with_mean - without_mean:+.2f}"


def aggregate(iteration_dir: Path, *, executor_model: str | None = None,
              timestamp: str | None = None) -> dict:
    iteration_dir = Path(iteration_dir)
    runs = _load_runs(iteration_dir)

    # Metadata from the workspace's evals.json (iterations/ sits at the workspace root).
    workspace = iteration_dir.parent.parent
    meta_src = workspace / "evals" / "evals.json"
    skill_name = skill_path = None
    if meta_src.is_file():
        ev = json.loads(meta_src.read_text(encoding="utf-8"))
        skill_name = ev.get("skill_name")
        skill_path = ev.get("skill_path")

    evals_run = sorted({r["eval_id"] for r in runs})
    per_config_run_counts = [
        len([r for r in runs if r["configuration"] == c and r["eval_id"] == e])
        for e in evals_run for c in CONFIGS
    ]
    runs_per_configuration = max(per_config_run_counts, default=0)

    with_stats = _stats(_rates(runs, "with_skill"))
    without_stats = _stats(_rates(runs, "without_skill"))
    delta = _fmt_delta(
        with_stats["mean"] if with_stats else None,
        without_stats["mean"] if without_stats else None,
    )

    benchmark = {
        "metadata": {
            "skill_name": skill_name,
            "skill_path": skill_path,
            "executor_model": executor_model or os.environ.get("EVAL_EXECUTOR_MODEL"),
            "timestamp": timestamp or os.environ.get("EVAL_TIMESTAMP"),
            "evals_run": evals_run,
            "runs_per_configuration": runs_per_configuration,
        },
        "runs": runs,
        "run_summary": {
            "with_skill": {"pass_rate": with_stats},
            "without_skill": {"pass_rate": without_stats},
            "delta": {"pass_rate": delta},
        },
    }

    (iteration_dir / "benchmark.json").write_text(
        json.dumps(benchmark, indent=2) + "\n", encoding="utf-8")
    (iteration_dir / "benchmark.md").write_text(
        _render_md(benchmark, runs), encoding="utf-8")
    return benchmark


def _cell(stats: dict | None, key: str) -> str:
    return f"{stats[key]:.2f}" if stats else "—"


def _render_md(benchmark: dict, runs: list[dict]) -> str:
    md = benchmark["metadata"]
    rs = benchmark["run_summary"]
    w, wo = rs["with_skill"]["pass_rate"], rs["without_skill"]["pass_rate"]

    lines = [
        f"# Benchmark — {md['skill_name'] or 'unknown skill'}",
        "",
        f"- executor model: `{md['executor_model'] or 'unknown'}`",
        f"- timestamp: {md['timestamp'] or 'unset'}",
        f"- evals: {', '.join(md['evals_run']) or '(none)'}",
        f"- runs per configuration: {md['runs_per_configuration']}",
        "",
        "## Pass rate (across all runs)",
        "",
        "| configuration | mean | stddev | min | max |",
        "| --- | --- | --- | --- | --- |",
        f"| with_skill | {_cell(w, 'mean')} | {_cell(w, 'stddev')} | {_cell(w, 'min')} | {_cell(w, 'max')} |",
        f"| without_skill | {_cell(wo, 'mean')} | {_cell(wo, 'stddev')} | {_cell(wo, 'min')} | {_cell(wo, 'max')} |",
        f"| **delta** | **{rs['delta']['pass_rate'] or '—'}** | | | |",
        "",
        "## Per-eval pass rate (mean)",
        "",
        "| eval | with_skill | without_skill | delta |",
        "| --- | --- | --- | --- |",
    ]
    for e in md["evals_run"]:
        ew = _stats(_rates(runs, "with_skill", e))
        ewo = _stats(_rates(runs, "without_skill", e))
        delta = _fmt_delta(ew["mean"] if ew else None, ewo["mean"] if ewo else None)
        lines.append(
            f"| {e} | {_cell(ew, 'mean')} | {_cell(ewo, 'mean')} | {delta or '—'} |")
    lines.append("")
    return "\n".join(lines)


def _selftest() -> int:
    import tempfile

    def write_grading(path: Path, pass_rate: float) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "expectations": [],
            "summary": {"pass_rate": pass_rate, "passed": 0, "failed": 0, "total": 0},
            "timing": {},
        }), encoding="utf-8")

    with tempfile.TemporaryDirectory() as tmp:
        ws = Path(tmp) / "demo-workspace"
        (ws / "evals").mkdir(parents=True)
        (ws / "evals" / "evals.json").write_text(json.dumps({
            "skill_name": "x442-demo", "skill_path": "skills/demo", "evals": [],
        }), encoding="utf-8")
        it = ws / "iterations" / "iteration-1"
        # with_skill: 1.0, 1.0 ; without_skill: 0.5, 0.5  -> delta +0.50
        write_grading(it / "eval-fresh" / "with_skill" / "run-1" / "grading.json", 1.0)
        write_grading(it / "eval-fresh" / "with_skill" / "run-2" / "grading.json", 1.0)
        write_grading(it / "eval-fresh" / "without_skill" / "run-1" / "grading.json", 0.5)
        write_grading(it / "eval-fresh" / "without_skill" / "run-2" / "grading.json", 0.5)

        b = aggregate(it, executor_model="selftest-model", timestamp="2026-07-14T00:00:00Z")
        assert b["run_summary"]["with_skill"]["pass_rate"]["mean"] == 1.0, b
        assert b["run_summary"]["without_skill"]["pass_rate"]["mean"] == 0.5, b
        assert b["run_summary"]["delta"]["pass_rate"] == "+0.50", b
        assert b["metadata"]["runs_per_configuration"] == 2, b
        assert b["metadata"]["skill_name"] == "x442-demo", b
        assert (it / "benchmark.json").is_file() and (it / "benchmark.md").is_file()

        # Re-aggregating an unchanged iteration must be byte-identical (no datetime.now()).
        before = (it / "benchmark.json").read_bytes()
        aggregate(it, executor_model="selftest-model", timestamp="2026-07-14T00:00:00Z")
        assert (it / "benchmark.json").read_bytes() == before, "rerun must be deterministic"

        # A single-config iteration: delta is null, and both keys still exist.
        it2 = ws / "iterations" / "iteration-2"
        write_grading(it2 / "eval-fresh" / "with_skill" / "run-1" / "grading.json", 1.0)
        b2 = aggregate(it2)
        assert b2["run_summary"]["delta"]["pass_rate"] is None, b2
        assert b2["run_summary"]["without_skill"]["pass_rate"] is None, b2
        assert "—" in (it2 / "benchmark.md").read_text(encoding="utf-8")

        print("aggregate selftest OK — delta", b["run_summary"]["delta"]["pass_rate"])
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return _selftest()
    if not argv:
        print(__doc__)
        return 2
    executor_model = timestamp = None
    if "--executor-model" in argv:
        executor_model = argv[argv.index("--executor-model") + 1]
    if "--timestamp" in argv:
        timestamp = argv[argv.index("--timestamp") + 1]
    iteration_dir = Path(argv[0])
    if not iteration_dir.is_dir():
        print(f"no such iteration dir: {iteration_dir}")
        return 1
    b = aggregate(iteration_dir, executor_model=executor_model, timestamp=timestamp)
    print(json.dumps(b["run_summary"], indent=2))
    print(f"\nwrote {iteration_dir / 'benchmark.json'} and benchmark.md")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
