#!/usr/bin/env python3
"""Generate AUDIT/ledger.md from AUDIT/ledger.json.

ledger.json is the machine-readable source of truth (audit brief §8/§9); this
script renders the human-readable twin so the two cannot drift. Run it after any
edit to ledger.json:  python3 AUDIT/gen-ledger.py
"""

from __future__ import annotations

import collections
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
SEV_ORDER = {"S0": 0, "S1": 1, "S2": 2, "S3": 3}
TERMINAL = {"DONE", "BLOCKED", "SWEPT", "CLOSED"}

GATES = (
    "Status gates (a status may not advance without the artefact): "
    "START = reproduced/statically proven + expected behaviour written down; "
    "PROGRESS = the diff; TEST = a check that fails before and passes after, "
    "full suite green, no new warnings; AUDIT = cold re-read + lint/analyzer/scanners "
    "re-run + no baseline regression; DONE = committed atomically to the audit branch."
)


def cell(value: str) -> str:
    """A Markdown table cell cannot carry a raw pipe or newline."""
    return (value or "").replace("|", "\\|").replace("\n", " ")


def detail(task: dict) -> str:
    out = [f"### {task['id']}", ""]
    lines = [
        f"- **Severity / category / module:** {task['severity']} / {task['category']} / {task['project']}",
        f"- **Location:** `{task['file_line']}`",
        f"- **Title:** {task['title']}",
        f"- **Status:** {task['status']}",
    ]
    for label, key in [
        ("Evidence (before)", "evidence_before"),
        ("Fix", "fix_summary"),
        ("Evidence (after)", "evidence_after"),
    ]:
        if task.get(key):
            lines.append(f"- **{label}:** {task[key]}")
    if task.get("commit"):
        lines.append(f"- **Commit:** `{task['commit']}`")
    if task.get("blocked_reason"):
        lines.append(f"- **Blocked reason:** {task['blocked_reason']}")
    if task.get("notes"):
        lines.append(f"- **Notes:** {task['notes']}")
    out.extend(lines)
    out.append("")
    return "\n".join(out)


def render(data: dict) -> str:
    audit = data["audit"]
    tasks = data["tasks"]
    ordered = sorted(tasks, key=lambda t: (SEV_ORDER.get(t["severity"], 9), t["id"]))
    status = collections.Counter(t["status"] for t in tasks)
    severity = collections.Counter(t["severity"] for t in tasks)
    open_count = sum(1 for t in tasks if t["status"] not in TERMINAL)

    head = [
        "# Audit ledger",
        "",
        (
            "Machine-readable twin: [`ledger.json`](ledger.json) (it wins on conflict). "
            "Environment: [`environment.md`](environment.md). "
            "Scope: [`inventory.md`](inventory.md). Baseline: [`baseline.md`](baseline.md)."
        ),
        "",
        (
            f"Branch `{audit['branch']}`, base `{audit['base_commit']}`. "
            f"Standard: {audit['standard']['swift']}; {audit['standard']['sh']}."
        ),
        "",
        (
            f"**Open: {open_count} | done: {status['DONE']} | blocked: {status['BLOCKED']} | "
            f"total: {len(tasks)}** (S0 {severity['S0']}, S1 {severity['S1']}, "
            f"S2 {severity['S2']}, S3 {severity['S3']})"
        ),
        "",
        GATES,
        "",
        "| id | sev | module | file:line | title | category | status | host | discovered by |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for t in ordered:
        head.append(
            f"| [{t['id']}](#{t['id']}) | {t['severity']} | {cell(t['project'])} | "
            f"`{t['file_line']}` | {cell(t['title'])} | {t['category']} | "
            f"**{t['status']}** | {t['host_used']} | {cell(t['discovered_by'])} |"
        )
    head += ["", "## Task detail", ""]

    body = "\n".join(detail(t) for t in ordered)

    tail = [
        "## Destructive or system-changing operations (command + rollback, logged before running)",
        "",
        "| Date | Command | Why | Rollback |",
        "|---|---|---|---|",
    ]
    for op in audit.get("destructive_operations", []):
        tail.append(
            f"| {cell(op['date'])} | {cell(op['command'])} | {cell(op['why'])} | "
            f"{cell(op['rollback'])} |"
        )
    tail.append("")
    return "\n".join(head) + "\n" + body + "\n" + "\n".join(tail) + "\n"


def main() -> None:
    data = json.loads((ROOT / "ledger.json").read_text())
    (ROOT / "ledger.md").write_text(render(data))


if __name__ == "__main__":
    main()
