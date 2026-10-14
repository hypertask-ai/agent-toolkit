# {{project}} working rules

Repo: `{{repo}}`; base branch: `{{base_branch}}`; board: `{{board}}`.
Config: `.claude/setup-agents/project.yaml`; each pane loads its own identity.

- Start work with `/ship`; read `/unlazy` and write acceptance gates first.
- Test: `{{test_command}}`.
- PR: `gh pr create --repo {{repo}} --base {{base_branch}}`; title rule: {{title_rule}}.
- Deploy: {{deploy_rule}}.
- Live check: `{{live_command}}`; proof: {{proof_type}}.
- Columns: {{columns}}. Done allowed: {{done_allowed}}.
- Development model rule: {{dev_model_rule}}.
- Never replace a human assignee, use another identity or expose a token.
- Runners put links on tickets instead of opening the owner's browser.
- The lead reads the board every five minutes, follows up on existing work,
  restarts only dead sessions and asks the owner only for real decisions.
