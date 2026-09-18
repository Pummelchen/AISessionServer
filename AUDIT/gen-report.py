#!/usr/bin/env python3
"""Generate AUDIT/report.md (the milestone report) from AUDIT/ledger.json."""

from __future__ import annotations

import collections
import datetime
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
TERMINAL = {"DONE", "BLOCKED", "SWEPT", "CLOSED"}


def main() -> None:
    ledger = json.loads((ROOT / "ledger.json").read_text())
    audit = ledger["audit"]
    tasks = ledger["tasks"]
    status = collections.Counter(t["status"] for t in tasks)
    sev = collections.Counter(t["severity"] for t in tasks)
    tier = collections.Counter(t.get("tier", "?") for t in tasks)
    open_tasks = [t for t in tasks if t["status"] not in TERMINAL]
    blocked = [t for t in tasks if t["status"] == "BLOCKED"]

    lines = [
        "# Audit report",
        "",
        f"Generated from [`ledger.json`](ledger.json) on {datetime.date.today().isoformat()} "
        f"(the ledger is the single source of truth; this file is output).",
        "",
        f"Branch `{audit['branch']}`, base `{audit['base_commit']}`.",
        f"Standard: {audit['standard']['swift']}; {audit['standard']['sh']}.",
        "",
        "## Counts",
        "",
        f"- Total tasks: **{len(tasks)}**",
        f"- DONE: **{status['DONE']}**",
        f"- BLOCKED: **{status['BLOCKED']}** (terminal, each with a named owner below)",
        f"- Open: **{len(open_tasks)}**",
        f"- By severity: S0 {sev['S0']}, S1 {sev['S1']}, S2 {sev['S2']}, S3 {sev['S3']}",
        f"- By tier: A {tier['A']}, B {tier['B']}, C {tier['C']}",
        "",
    ]
    if blocked:
        lines += ["## Blocked (owner + reason)", ""]
        for t in blocked:
            lines.append(
                f"- **#{t['id']}** {t['title']} — {t.get('blocked_reason') or 'no reason recorded'}"
            )
        lines.append("")
    if open_tasks:
        lines += ["## Open tasks", ""]
        for t in open_tasks:
            lines.append(
                f"- **#{t['id']}** ({t['severity']}/{t.get('tier')} {t['status']}) {t['title']}"
            )
        lines.append("")

    lines += [
        "## Evidence",
        "",
        "See [`ledger.md`](ledger.md) for every task's before/after evidence and commit, "
        "[`baseline.md`](baseline.md) for the yardstick, [`tool-coverage.md`](tool-coverage.md) "
        "for the language-standard and tool-coverage proofs, and [`waivers.md`](waivers.md) for "
        "the one accepted scanner finding.",
        "",
    ]
    (ROOT / "report.md").write_text("\n".join(lines) + "\n")
    print(f"report.md written; open={len(open_tasks)} blocked={len(blocked)}")
    raise SystemExit(0)


if __name__ == "__main__":
    main()
