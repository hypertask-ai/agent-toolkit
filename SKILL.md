---
name: create-agent
description: Provision a skills-driven agent identity, a Cursor/Claude/Codex worker that reads a skills index before it does anything, pointed at a repo. Invoke via /create-agent. Dry-run by default; never creates or revokes a real identity without an explicit go-ahead.
version: 1.0.0
---

# /create-agent: provision an agent identity

The person types `/create-agent` and answers in plain words. They never see
a flag. This file is the conversation; `scripts/create-agent.sh` is the
mechanism underneath it.

This is the board-agnostic core: it wires an agent to a skills index and a
repo, with a mission, an env file, a trigger wrapper, and a chat test.
Adding a real board (task assignment, webhooks, a chat UI) is a project on
top of this template, not part of it.

## Example dialogue

```
Person: /create-agent
Claude: Three things, one message:
  1. Name? (e.g. "Cursor Dev 3")
  2. Dev, QA, or a plain worker with no chat identity?
  3. Which repo does it work in?
     (Provider defaults to Cursor: say "use Claude" or "use Codex" to change it.)
Person: Cursor Dev 3, dev, ~/projects/my-app
Claude: Plan:
  1. Mission built for Cursor Dev 3, pointed at the skills index
  2. Env file + trigger wrapper + oneshot systemd unit written, cwd set to
     ~/projects/my-app
  3. Chat test run against the Cursor CLI
  Go?
Person: go
Claude: [runs the script with --yes] ... Chat test passed: Cursor Dev 3 replied
  "I would use fix-bug, reproduce the reported failure, run its checks, and quote
  the test output as evidence."
```

## What the session does

1. **Read whatever free text followed `/create-agent`.** If it already
   answers name / kind / repo / provider, skip straight to the plan. Only
   ask for what's actually missing. If the person supplies a custom
   mission, save it as plain text and pass its path with `--mission-file`.
2. **Ask at most three short questions, one batched question**, for
   whatever is missing:
   - **Name**: plain text.
   - **Kind**: dev (ships fixes), QA (verifies only, never fixes), or a
     plain worker (env-only identity, no chat: for scripts, cron jobs,
     things that show up in logs under their own name).
   - **Repo**: the path it works in. Provider defaults to Cursor; only ask
     if they volunteer Claude or Codex.
   Never show `--kind` or any other flag name to them: map their words to
   flags yourself.
3. **Show a short plan and ask "go?"** before doing anything real. The plan
   names: the mission, what gets created (env file + wrapper + unit), and
   the chat test. If `<skills-repo>/INDEX.md` has no skill matching this
   bot's domain, create one first (or in the same run).
4. **Run the script** with the flags mapped from their answers. Default to
   `--dry-run` for anything not explicitly greenlit; only add `--yes` after
   they say "go" (or the equivalent). If the identity already exists,
   rerun with `--resume`; this preserves every existing env value while
   adding missing keys.
5. **Finish by quoting the chat test reply verbatim.** An agent someone
   can't get a reply from isn't finished: say so plainly if the step
   failed.

If a "kind: plain worker" agent has no repo yet, ask for the path before
running anything: the script requires it.

## What the script actually does

1. Slug from the name (`Cursor Dev 3` -> `cursor-dev-3`).
2. A short mission (~450-700 chars): identity, read
   `<skills-repo>/INDEX.md` first (absolute path, no `~`), name the matched
   skill in the first reply, corrections go into the skill file. QA gets a
   verify-only variant. Pass `--mission-file PATH` to use plain text
   verbatim instead of this template.
3. `<config-dir>/<slug>.env`, written with a no-overwrite helper: an
   existing key is never replaced, only missing keys get added. This is
   what makes `--resume` on an already-provisioned identity safe.
4. `<state-root>/agent-<slug>/`.
5. dev/qa only: a wrapper at `~/.local/bin/<slug>` (`<slug> run "<task>"`,
   cwd = `--repo`) and a generic oneshot systemd unit,
   `agent-worker-<slug>.service`: one process per event, no persistent
   daemon. Trigger it by hand or from a cron/loop.
6. Chat test: the wrapper sends the mission plus a domain question to the
   provider CLI non-interactively and reports the reply as verbatim
   evidence.
7. `--kind cli`: stops after the env file. Name gets a `" CLI"` suffix.
   No worker, no chat: it's an identity for logs and commit trails, not a
   conversation partner.

## Wiring this to a real board

The script has no concept of a board (no identity-existence API, no
webhook, no ticket queue). If the target has one, add a board layer on top
of this core, following the same shape:

- Before any local write, query the board for an existing identity by
  name/slug. If found, exit with instructions to pass `--resume` instead
  of creating a duplicate.
- Put the real "create an identity" call behind its own hard stop,
  independent of `--dry-run` / `--yes`: creating a real account or user is
  a bigger action than writing local files and deserves its own gate.
- Write secrets (tokens, webhook signing secrets) straight to 0600 files
  and reference them by path. Never print a secret to the terminal or into
  a chat reply.
- End with an acceptance test the same shape as the chat test here: the
  identity is not "added" until something (a human or this session) gets a
  reply out of it, not just a "created" status from an API.

## Check before you say done

- a matching domain skill exists before the chat test
- chat test asks a domain question and its reply is quoted verbatim
- every secret/env file for the new identity is 0600
- if a board layer was added on top: its own acceptance test passed too

## Hard rules

- **Dry-run is the default.** The script prints every command it would run
  and changes nothing unless `--yes` is passed.
- **`--resume` never replaces an existing env value.** It only adds missing
  keys, so rerunning the script on an identity that already exists is
  always safe.
- **Never print a secret or token.** Only the file path.
- **A CLI identity cannot chat.** Don't promise a chat test for `--kind
  cli`: there's nothing to test.
- **QA gets its own state**, never a dev identity's or the human's.

## What Anthropic's agent guidance means here

- Every domain bot should ship with a fixture test that its skill runs
  first, before it touches anything real.
- Its operating loop should be a numbered workflow with checkpoints, not
  free-form work.
- Its skill should have an explicit "ask the human only on these" list.
- Chat replies should report concrete evidence (fixture output, source
  links) instead of bare assertions.

## Known issues

- None tracked for this template right now. If a board layer is added on
  top, its own known issues belong in that layer's skill file, not here.

## Reference

- `<skills-repo>/INDEX.md`: the skills the identity reads first.
- `scripts/create-agent.sh`: the script itself; `--help` lists every flag
  it accepts (for the session's own use, not for reciting to the person
  running it).
