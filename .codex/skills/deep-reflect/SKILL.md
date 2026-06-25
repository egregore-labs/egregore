---
name: deep-reflect
description: Cross-reference an insight against the Egregore knowledge base using Codex-native staged analysis when the user invokes /deep-reflect or $deep-reflect.
---

# Egregore Deep Reflect

Native Codex Egregore skill. Use this for evidence-based analysis of how a new
insight relates to the existing knowledge base.

## Modes

- empty request: deep mode.
- `focused ...`: focused topic mode.
- `quick ...` or `category: content`: quick mode.

Detect directed questions when the user asks how, why, what something means, or
about a relationship. Preserve the user's lens while still surfacing important
signals outside the lens.

## Flow

1. Check `egregore.json` mode first. In local mode, do a lightweight reflection
   from memory files and do not call graph, batch graph, or notification
   scripts.
2. In connected mode, gather graph context with `bin/graph.sh` and suppress raw
   JSON. Query recent sessions, active quests, recent artifacts, decisions,
   the topic landscape, and the full artifact landscape.
3. If the graph is unavailable or has fewer than about ten artifacts, fall back
   to lightweight reflection and say why in one line.
4. Select candidate artifacts. Prefer title, type, topics, quest, author, and
   date metadata first; fetch file contents only for the selected subset.
5. Use Codex multi-agent or subagent tooling only if it is available in the
   current session. If not, run a single-model staged analysis:
   - candidate selection summary
   - evidence extraction summary
   - signal analysis
   - final synthesis
6. Classify signals as tension, convergence, gap, dependency, phase shift,
   redundancy, emergence, reinforcement, or a named custom type.
7. Write a markdown artifact under `memory/knowledge/deep-reflect/` with
   frontmatter for run id, mode, lens, author, created time, and selected
   evidence paths.
8. In connected mode, write best-effort graph edges with `bin/graph.sh` or
   `bin/graph-batch.sh`. Use `TENSION_WITH` for conflict signals and
   `RELATES_TO` for other signals.
9. Save memory and repo changes with `bin/agent.sh save --message "Deep reflect: $TOPIC" --topic "$TOPIC"`.

## Output

Lead with the strongest finding, then list primary signals, evidence paths, and
recommended next action. Keep secondary and ambient signals short.

Structured UX parity is required. Then render the Egregore deep-reflect
confirmation TUI:

- Use a 72-column outer box with standard top/separator/content/bottom lines.
- Header: `DEEP REFLECT`, author, and date.
- Body: lens/topic, strongest finding, signal counts by type, selected evidence
  count, artifact path, and recommended next action.
- Footer: saved/pushed state. In connected mode include graph-link state when
  available; in local mode omit graph language.
- Do not show raw graph JSON or replace the confirmation box with plain prose.

## Rules

- Never show raw graph JSON.
- Do not claim evidence you did not inspect.
- Keep intermediate summaries explicit so the user can audit the reasoning.
- Do not use Claude Code commands.
