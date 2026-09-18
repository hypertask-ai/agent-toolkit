---
name: learned-rules
description: Always, before starting any ticket in this repo, and whenever a human corrects this bot's work here.
version: 1.0.0
---

# learned-rules: corrections that outlive the conversation

A correction a human makes once should not have to be made twice. This skill
is how a correction turns into a rule this repo's agents load before every
later ticket, and how that rule earns or loses trust over time instead of
sitting there forever at face value.

This is not one skill among many whose trigger has to match the ticket. Read
`RULES.jsonl` in this folder before picking up any ticket, the same way you
read `AGENTS.md`. It holds this repo's own history of "we told the bot this
once already."

## Reading the rules before a ticket

1. Run `agent-rules list --file .claude/skills/learned-rules/RULES.jsonl --status active`
   (the script ships at `scripts/agent-rules` in the agent template; if this
   checkout has no copy, read `RULES.jsonl` directly, one JSON object per
   line, and ignore blank lines and lines starting with `#`).
2. Treat every row it prints as a constraint for this ticket, highest
   confidence first. A rule with a `source` link is not a suggestion, it is
   something a human already corrected once.
3. If a rule directly conflicts with the ticket's own instructions, follow
   the ticket and say so in your plan; do not silently drop the rule.

## When a human corrects you

Whether they edit your comment, fail QA, reject your pull request, or say
plainly that something is wrong:

1. File it the normal way first: `agent-template feedback --kind bug --what
   "<one sentence>" --got "<the bad output>" --expected "<what should have
   happened>"`, per `CORRECTIONS.md`.
2. If the correction is a standing rule for this repo (would it still be true
   next quarter, for different code? yes means rule, no means fact), also
   propose it here:
   ```
   agent-rules add --file .claude/skills/learned-rules/RULES.jsonl \
     --text "<the rule, one sentence>" \
     --source "<full https URL of the ticket the correction came from>"
   ```
   `add` writes it as `proposed`, never `active`. A proposed rule is not yet
   load-bearing.
3. Open the proposal as a pull request to this repo (the "skills repo" for
   this rule) that changes `RULES.jsonl`. Do not call `agent-rules promote`
   yourself in the same run. A human reviewing and merging that pull request,
   inside the existing four-hour feedback cycle, is the veto point. Only
   after it merges does the next run treat the rule as active — a maintainer
   or `agent-template-feedback` runs `agent-rules promote --file
   .claude/skills/learned-rules/RULES.jsonl --id <id>` as part of landing it.

## Scoring, so a rule earns its keep

- **A run follows an active rule and its pull request passes on the first
  try:** run `agent-rules confirm --file .claude/skills/learned-rules/RULES.jsonl
  --id <id>`. Confidence rises, and an archived rule that gets confirmed again
  comes back to active — it turned out to still matter.
- **Nobody has confirmed a rule in 30 days:** `agent-rules decay --file
  .claude/skills/learned-rules/RULES.jsonl` (run this once as part of the
  existing four-hour feedback pass, alongside `agent-template feedback`'s
  other maintenance) lowers its confidence. Below the floor, the rule is
  archived automatically.
- **Archived rules are never deleted**, only marked. `agent-rules list --file
  .claude/skills/learned-rules/RULES.jsonl --status archived` still shows
  them, so a rule that stopped mattering stays visible instead of vanishing.
- A rule you believe is simply wrong, not just unused, gets `agent-rules
  archive --file .claude/skills/learned-rules/RULES.jsonl --id <id> --why
  "<reason>"` with a real reason, same as any other correction: edit the
  record, do not just stop following it silently.

## Check before hand-off

- Every active rule you relied on this run either held (leave it) or proved
  wrong (correct it per "when a human corrects you" above, and say which rule
  changed in the hand-off).
- A rule you added or confirmed this run is named in the pull request or
  ticket comment, so a reviewer sees which file changed, per `CORRECTIONS.md`.
- You never deleted a row from `RULES.jsonl`; archived is the only terminal
  state.
