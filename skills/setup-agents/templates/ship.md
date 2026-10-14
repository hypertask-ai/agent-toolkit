---
name: ship
description: Work a project board ticket through tested pull request and verified handoff using the project's rules and your own identity.
---

# Ship a ticket

Read `.claude/CLAUDE.md` and `$KIT_CONFIG` for the project's repo, board,
columns, tests, title rule, deployment and live checks. Resolve identity with
`"$KIT_HOME/bin/kit-identity"`; stop if it fails. Use that same command with
`--board` for every board operation. Never borrow another login or project's
rules. The lead follows up on work; it does not grant permission to merge.

1. Read the ticket and all comments before starting. Without a ticket, read
   the configured board with `--board tasks list --project "$KIT_BOARD_ID" --json`.
   Follow the project's claim protocol and re-read ownership before coding.
   Never steal an active claim or replace a human assignee. If no safe claim
   protocol is documented, ask the owner rather than invent one.
2. Load `/unlazy`; write ticket-specific acceptance gates under
   `.unlazy/<ticket>/GATES.md`, starting from `.claude/setup-agents/GATES.md`.
   Inspect and approve checks before executing them. Keep machine evidence
   current; never handwrite passing evidence for runnable gates.
3. Work in a new worktree off the configured base branch. Follow the project's
   development model rule, make the smallest complete change and run its tests.
   Never stash or overwrite somebody else's work.
4. Check the PR title with `"$KIT_HOME/bin/kit-check" title "<title>"`, create
   the PR against the configured repo/base and bind it with
   `"$KIT_HOME/bin/kit-check" pr <ticket> <number>`. Fix CI and review findings;
   never bypass checks. Merge only with owner authorization and passing checks.
5. Prove merge with `"$KIT_HOME/bin/kit-check" merged <ticket>`, then follow the
   project's deployment authority. For published GitHub releases,
   `"$KIT_HOME/bin/kit-check" deployed <ticket>` verifies that a release contains
   the merge. Other deployment types require the project's own verification.
   A PR or green build alone does not prove deployment.
6. Run real live checks and exercise the changed path. Write evidence to
   `~/.config/agent-kit/evidence/<project>/<ticket>/proof.md` with the merge SHA
   (`merge_sha`, or `release_sha` for Windows) and nonempty `screenshots` paths.
   Windows evidence also needs `execution_host`, `gui_interaction` and
   `changed_paths`, matching the configured test host. Check it with
   `"$KIT_HOME/bin/kit-check" proof <ticket>` and reverify every acceptance gate.
   Report failures honestly; the default `false` live check must not be skipped.
7. Check `"$KIT_HOME/bin/kit-check" done-allowed`. Close only when allowed and
   deployment plus live proof pass; otherwise hand off in the configured column
   with evidence and a plain-language verdict. Clean up only your own worktree
   when no longer needed, never unpushed work.

Runners put links and decisions on tickets rather than control the owner's
browser. Never widen rollout, erase data or treat a blocker as permission.
