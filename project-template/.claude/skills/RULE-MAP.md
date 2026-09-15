# Rule map

Every rule this repo's agents follow, one line each, mapped to the skill file
that carries it. A rule with no skill is a rule nobody follows.

A skill name in the Skill column is a name, not a path. It resolves in the
company pack (`$COMPANY_SKILLS_DIR`) first, then this repo's
`.claude/skills/`, then any extra pack the agent's conf names.

Add a row when a rule is agreed. Change the row when the rule moves. Write
DROP with a reason instead of deleting, so the next reader knows the rule was
considered and rejected rather than forgotten.

| # | Rule | Source | Skill |
|---|---|---|---|
