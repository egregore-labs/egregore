#!/usr/bin/env python3
"""Timing budgets: a contract on a developer machine, a reading on a shared runner.

A wall-clock assertion that holds on a laptop fails on a loaded CI runner for
reasons that have nothing to do with the change under test; on 20 October
2026 four such assertions turned shards red on unrelated pull requests. The
rule here keeps the budget as the number people read and reason about, and
widens the failing line only where the runner is shared: under GitHub
Actions a measurement fails only past CEILING_FACTOR times the budget, so a
real regression still stops the merge while runner load does not.

    from budget import limit, note
    assert elapsed_ms <= limit(150), note(elapsed_ms, 150)

    python3 bin/lib/budget.py 150        # prints the effective limit, 150 or 750

`EGREGORE_BUDGET_FACTOR` overrides the factor: 1 makes every budget a contract
again (a quiet self-hosted runner), 0 or a blank keeps the default.
"""
import os
import sys

CEILING_FACTOR = 5


def factor():
    raw = os.environ.get("EGREGORE_BUDGET_FACTOR", "").strip()
    if raw:
        try:
            value = float(raw)
            if value > 0:
                return value
        except ValueError:
            pass
    return CEILING_FACTOR if os.environ.get("GITHUB_ACTIONS") else 1


def limit(budget):
    """The number a measurement must stay within: the budget itself, or its ceiling on a shared runner."""
    return budget * factor()


def note(measured, budget, unit="ms"):
    """One phrase for a pass or fail line: the reading, the budget, and the ceiling when it differs."""
    effective = limit(budget)
    text = f"{measured:.1f} {unit}; budget {budget:g} {unit}"
    if effective != budget:
        text += f", ceiling {effective:g} {unit} on a shared runner"
    return text


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    try:
        budget = float(argv[1])
    except ValueError:
        print("budget.py takes a number", file=sys.stderr)
        return 2
    value = limit(budget)
    print(int(value) if value == int(value) else value)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
