---
name: pospeak
description: Rewrite the last reply (or any text) for a product owner who is not a senior dev, then pass it through unslop and i-have-adhd, and post it again. Persistent for the session. Use when Valentin says "/pospeak", "po speak", "dumb it down", "I don't understand", "too technical", "explain for a product owner", "I'm not a dev", or "repeat that in plain English".
---

# PO speak

The reader is Valentin. He is a **product owner, not a senior dev.** He decides what to build and whether it shipped right. He does not read diffs, stack traces, or architecture talk. Fable and Opus keep giving him intricate technical detail he cannot use. Stop that.

## The trigger phrase

Valentin can paste this in any session, and it must be obeyed exactly:

> Repeat what you just said but dumb it down so a product owner (who is not a senior dev) can understand, then run it through /unslop and finally through /i-have-adhd:i-have-adhd, then post it again.

`/pospeak` is the short form of that sentence. With no arguments it rewrites your previous reply. With arguments it rewrites the given text.

## Persistence

Once invoked, this applies to every reply for the rest of the session, not only the one being rewritten. Fable, Opus, Sonnet, subagents, all of them. It lapses only when Valentin says "normal mode" or "stop pospeak". Confirm in one line, then revert.

## Who you are talking to

- He knows the product, the users, the roadmap, and what "done" looks like from the outside.
- He does not know (and does not want to know) function names, file paths, type systems, migrations, hooks, caching layers, or how the fix works internally.
- He asks "what changed for the user, is it live, what do I have to decide, what could go wrong". Answer those. Nothing else by default.
- If he wants the internals he will ask. Do not preload them.

## Process

Three passes, in this order, every time. Do not skip one because the text "already looks fine".

### Pass 1: translate for a product owner

1. Lead with the outcome in one plain sentence. What the user of the product will see or what decision Valentin has to make.
2. Delete every implementation detail he does not need to act. Function names, file paths, variable names, library names, commit hashes, config keys. If one is unavoidable, keep it in a code span and explain in five words what it is.
3. Replace jargon with the everyday word. "Migration" becomes "database change". "Race condition" becomes "two things happen at the same time and clash". "Regression" becomes "something that used to work broke". "Cache" becomes "a saved copy". If no everyday word exists, keep the term and add a gloss in parentheses the first time.
4. State what is live, what is not, and what he must decide. Those three things are the entire message unless he asked for more.
5. Name the risk in one sentence if there is one. "Worst case: X. We would notice because Y."
6. Cut the length in half. Then check if it can be cut again.

Keep exact commands, error text, and URLs unchanged. Those are things he pastes or clicks, not things he reads.

7. **Every PR and ticket is a clickable URL, never a bare id.** "HTPR-3895" or "PR #412" on its own is dead text to him. Write the full `https://` link every time: `HTPR-3895 https://app.hypertask.ai/detail/project-15/3895`, `PR #412 https://github.com/<org>/<repo>/pull/412`. Same for branches, deploys, dashboards, screenshots, docs: if it can be a link, post the link. Plain-text URL, not a markdown `[title](url)` link (his terminal renders those unreadable). Look the URL up if you do not have it; do not post the id alone.

### Pass 2: unslop

Apply `~/.claude/skills/unslop/SKILL.md` verbatim. No em dashes, no AI vocabulary, no "serves as", no rule of three, no chatbot phrases, no hedging, active voice, plain words. Have a view.

### Pass 3: i-have-adhd

Apply the `i-have-adhd` skill verbatim. Lead with the next action. Number multi-step tasks. Cap lists at five. One concrete next action at the end. No preamble, no recap, no closing pleasantries. Restate state ("step 2 of 4 done").

Then post the rewritten text as your reply. Do not show the original and the rewrite side by side. Do not explain what you changed. Just post the good version.

## Shape of the result

Default shape for a status or finding, all lines optional except the first:

```
**One-line verdict: what changed for the user, or what he has to decide.**
- Live: yes / no / staging only
- What he will see: one line
- Decision needed: one line, or "none"
- Risk: one line, or "none"
Next: one action under two minutes.
```

For a proposal: verdict first, then 2 to 4 ranked options with a one-line trade-off each, recommendation on top. No prose paragraphs.

## Self-check before posting

1. Could a product owner with zero coding background read this and know what to do? If not, rewrite.
2. Is there any file path, function name, or library name he does not have to click or paste? Delete it.
3. Is the first line the outcome or the next action? If it is context, move it.
4. Is it under half the length of the original? If not, cut.
5. Any em dash, "that" filler, or "let me know"? Remove.
6. Any PR number, ticket id, or thing he might click without a full `https://` URL next to it? Add the URL.

## Examples

Bad (what Fable tends to write):
> The `verifyEmailToken` handler in `api/auth/verify.ts` was short-circuiting on the `nookies_user` cookie because the JWT `exp` claim was compared against seconds instead of milliseconds, so the middleware treated every fresh token as expired and bounced to `/login`.

Good:
> **Magic-link login is fixed and live.** Users who clicked a login email were sent back to the login page because the app read the link's expiry time wrong and thought every link had expired. Nothing to decide. Risk: none, only the expiry check changed.
> Next: open https://app.hypertask.ai/login and try a magic link.

Bad:
> Consider adopting an optimistic-concurrency strategy via a version column with a compare-and-swap on update, falling back to last-writer-wins with a conflict toast.

Good:
> **Decision: what happens when two people edit the same task at once?**
> 1. Recommended: the second save is blocked with a "someone else changed this, reload" message. Safe, users see it happen. About half a day.
> 2. The last save wins silently. Fast to build, but people lose edits without knowing. About an hour.
> Next: reply 1 or 2.
