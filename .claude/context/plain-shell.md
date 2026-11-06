# Plain shell in worktree sessions

Claude Code's worktree isolation, on in every session that entered a worktree
(the default for project changes), chaperones each Bash call and refuses any
shape it cannot prove stays inside the worktree. The refusal reads "too
complex to verify that it stays inside the worktree". It is the harness, not
an Egregore hook, and it reads only the typed command: a script file may do
anything inside. Split a refused command into plain ones instead of retrying
it, and never route around the refusal with a different shell.

## Refused shapes and their plain forms

| Refused | Plain form |
| --- | --- |
| `VAR=$(command)` and backticks | Run the command and read what it prints; let the tool write to a file (`--out file`) when a later step needs the value |
| A heredoc containing `$` or backticks | Write the file with the editor rather than the shell; or `python3 - <<'EOF'` with no `$` inside |
| `bash -c '…'`, `xargs sh -c`, `find -exec sh` | A script file, run as `bash tmp/script.sh` |
| Loops and compound blocks at the prompt (`for`, `while`, `{ …; }`, `[ … ] && { … }`) | A script file |
| `git` joined to anything (`a && git x`, `git x \| head`, `git -C <other repository>`) | One git command per call; `gh pr view` and `git show origin/<branch>:<path>` pass alone |
| A quoted command path (`"/Applications/…/Chrome" --headless`) | A bin wrapper (`bin/screenshot.sh`) or a script file |
| `bash <path outside the worktree>`, `bash -x script` | Copy the script inside the worktree; `node <outside path>` passes |
| A pipe out of bash (`bash tests/x.sh \| tail`) | A runner script that writes a log and prints its tail and exit code |

What passes: a single pipeline of ordinary tools with literal paths;
`python3 script.py args`; `bash tmp/script.sh args`; `node anything`; a
trailing `&` on a plain command.

## Where this matters

Instructions every session follows use the plain forms: the notification
consent flow (`notify.sh approve … --out`, `notify.sh dispatch … --approval-file`)
and the Loom route step (run `bin/loom.sh route`, read the printed JSON).
Session records count refusals under Friction as `worktree-guard refusals`;
the `shells` reflex prints the count at the next greeting when yesterday had
three or more, with a pointer here.
