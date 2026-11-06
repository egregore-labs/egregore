# Picking up an addressed handoff

Use when the startup context lists handoffs addressed to the user
(`addressed_to_user`) and the user picks one up. Run these steps after the task
branch or worktree exists.

1. Create the IMPLEMENTS link:

   ```bash
   bash bin/graph-op.sh claim-handoff "$SESSION_ID" "$HANDOFF_SESSION_ID" 2>/dev/null &
   ```

2. Check out the handoff's repo branches. When its `addressed_rich` entry
   carries a non-empty `repoState`, check out each entry's branch in that
   managed repo:

   ```bash
   PARENT_DIR="$(cd .. && pwd)"
   # For each entry in repoState:
   REPO_DIR="$PARENT_DIR/$REPO_NAME"
   if [ -d "$REPO_DIR/.git" ] || [ -f "$REPO_DIR/.git" ]; then
     git -C "$REPO_DIR" fetch origin "$BRANCH" --quiet 2>/dev/null
     git -C "$REPO_DIR" checkout "$BRANCH" 2>/dev/null || \
       git -C "$REPO_DIR" checkout -b "$BRANCH" "origin/$BRANCH" 2>/dev/null
   fi
   ```

   Report `✓ Checked out {branch} in {repo1}, {repo2}`. If a branch no longer
   exists because its PR merged: `◐ {repo}: PR #{N} merged — on {base}`. This
   is plain Git and works in Local and Connected modes.

   If `repoState` is absent or empty (older handoffs), skip this step silently.
