# Working in this repo, as an agent

The conventions every agent follows here. They are the same in every repo the
agent template syncs, so an agent that has worked one repo can work this one.
Anything specific to this repo's code belongs in `.claude/skills/`, not here.

## Read before you act

1. `$COMPANY_SKILLS_DIR/INDEX.md`, the company pack. How to work a ticket, how
   to talk to people, how to look a fact up. `$COMPANY_SKILLS_DIR` is exported
   by the runner and points at the installed `company-skills` plugin, or the
   `~/projects/company-skills` clone.
2. `.claude/skills/INDEX.md`, this repo's own skills.
3. The skill whose trigger matches the ticket. If none matches, say so and
   stop. Do not improvise a workflow.

## One ticket at a time

An agent owns one ticket from start to hand-off. Do not pick up a second while
the first is open. A ticket somebody else has claimed is theirs: a claim
comment plus the in-progress column means in flight, do not touch.

## Three comments, maximum

Per ticket, per day: a claim, a question if you genuinely need one, and a
hand-off. That is the cap unless a human writes in between. A run that wants a
fourth comment is a run that is narrating instead of working. Say the thing
once.

A reminder or status line is posted once and then edited in place with
`hypertask comment update <id>`, never re-posted. Post at most one reminder
comment per ticket per day. A due-date countdown is one edited comment.

Every comment is HTML block tags: `<p>`, `<ul><li>`, `<strong>`. Never bare
text and never a run of `<br>` tags. Bare text renders in the wrong font and
the whole comment reads as broken. The first `<p>` states the outcome or the
ask in one sentence.

## Never write as the owner

Board writes go through the agent's own identity, never through a person's
token. Never assign a person to a ticket; only they do that. A ticket a person
assigned to themselves or moved by hand is a manual override: leave the
assignees and the column exactly as they are.

## The repo is the memory

Every output, report, script and note lands in a repo as a pull request.
Nothing important lives only in a chat transcript or a local file. A correction
becomes a commit to the skill file it came from, in the same PR where possible,
so the next run reads the corrected rule.

## Shared checkouts are read-only

A shared clone stays on its default branch, because other agents read it live.
Any edit happens in a git worktree on a branch and lands as a PR. Never run
`git stash` in a shared checkout: the stash is shared across every worktree of
that repo, and another agent's work disappears.

## What a PR description looks like

Start with `## Summary for non-engineers`, written for someone who does not
read code:

1. The first line is the one action the reader takes. Merge this. Say go. Look
   at X.
2. **What went wrong** — what people were experiencing, in everyday words.
3. **What changes** — a numbered list, one idea per sentence.
4. **What you will see** — what is visibly different after it ships.
5. **Watch out for** — risks, and what to check.

Plain words. Explain any unavoidable technical term in parentheses the first
time. No em dashes. The technical detail goes after that section, not inside
it.

## Feedback to the template

<!-- agent-template:begin -->
Agent template version: __TEMPLATE_VERSION__
Feedback command: `agent-template feedback --kind bug|change|idea --what "<summary>" --got "<current behavior or context>" --expected "<desired behavior>"`
Feedback board: https://app.hypertask.ai/detail/project-5500
Updates: run `agent-template update` to get the latest.
<!-- agent-template:end -->

This posts to the Agent Template Inbox as the bot's own identity, never in the
owner's name. The board uses project 5500 and prefix AGTE. A correction that
lives only in one run's log is gone when that process exits, so file it in the
same run.

This route is for the setup itself: the runner, the skills layout, this file,
and the checks. A fact about the product goes in a doc or on the ticket. A rule
about how to work a ticket goes in the skill it belongs to.
