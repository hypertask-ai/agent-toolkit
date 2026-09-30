#!/usr/bin/env python3
"""Model settings checks use temporary homes and stub CLIs, never live models."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/migrate-provider-policy.py"
spec = importlib.util.spec_from_file_location("policy", SCRIPT)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

OLD = '''# keep this setting
BOARD_ADAPTER="hypertask"
BOARD_ID="15"
AGENT_KIND="qa"
MODEL_CLI="hax --provider=codex --model=gpt-6.1-sol --effort=high -p"
LADDER="hax --model=gpt-6.1-sol -p|claude -p --model opus --effort high"
LADDER="claude -p --model claude-opus-5-5"
PROVIDER_ORDER="codex,claude,cursor"
PROVIDER_CLAUDE_CLI="claude -p --model opus"
PROVIDER_CURSOR_CLI="cursor-agent -p --model cursor-grok-4.6-high-fast"
RESEARCH_CLI="hax --model=gpt-6.1-sol --effort=xhigh --raw -p"
CHAT_CLI="claude -p --model sonnet"
TRIAGE_MODEL_CLI="codex --model gpt-5"
OWNER_COMMENT_CLASSIFIER_CLI="claude -p --model opus"
COMMENT_REWRITE_CLI="claude -p --model sonnet"
SECOND_OPINION_CLI="claude -p --model opus"
WATCH_SECTIONS="AI Review,QA"
'''
CURSOR = 'cursor-agent -p --output-format text --model cursor-grok-4.7-high -f --trust'


class SolModelPolicy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        runtime = self.home / "runtime"
        runtime.mkdir(mode=0o700)
        self.env = dict(os.environ, HOME=str(self.home), XDG_RUNTIME_DIR=str(runtime),
                        PYTHONDONTWRITEBYTECODE="1")

    def run_policy(self, *args):
        return subprocess.run(
            ["python3", str(SCRIPT), "--version", "test-sol", *map(str, args)],
            env=self.env, check=True, capture_output=True, text=True,
        ).stdout

    def assert_sol(self, path):
        text = path.read_text()
        values = policy.read_conf(path)
        self.assertEqual(values["PROVIDER_ORDER"], "codex")
        self.assertNotRegex(text, r"opus|sonnet|gpt-5|grok|xhigh")
        self.assertEqual(len([line for line in text.splitlines() if line.startswith("LADDER=")]), 1)
        for key, value in values.items():
            if key == "LADDER" or (key.endswith("_CLI") and key != "BOARD_CLI"):
                for command in value.split("|"):
                    self.assertIn(str(self.home / ".local/bin/hax"), command)
                    self.assertIn("--provider=codex --model=gpt-6.1-sol --effort=high", command)
        self.assertIn("--raw -p", values["RESEARCH_CLI"])
        self.assertEqual(values["WATCH_SECTIONS"], "AI Review,QA")

    def test_installed_and_staged_replacement_is_idempotent(self):
        for directory in ("installed/Hypertask Product", "staged/Hypertask Product"):
            path = self.home / directory / "qa-1.conf"
            path.parent.mkdir(parents=True)
            path.write_text(OLD)
            original = path.read_bytes()
            self.run_policy("--dry-run", path.parent.parent)
            self.assertEqual(path.read_bytes(), original)
            self.assertFalse(path.with_name(path.name + ".bak-test-sol").exists())
            self.run_policy(path.parent.parent)
            self.assert_sol(path)
            self.assertEqual(path.with_name(path.name + ".bak-test-sol").read_bytes(), original)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            current = path.read_bytes()
            self.run_policy(path.parent.parent)
            self.assertEqual(path.read_bytes(), current)

    def test_shadowed_ladder_and_missing_primary_are_repaired(self):
        path = self.home / "qa-1.conf"
        path.write_text(OLD)
        self.run_policy("--file", path)
        current = path.read_text()
        path.write_text('LADDER="claude -p --model opus"\n' + current)
        self.run_policy("--file", path)
        self.assert_sol(path)
        path.write_text('BOARD_ADAPTER="hypertask"\nBOARD_ID="15"\nWATCH_SECTIONS="AI Review,QA"\n')
        self.run_policy("--file", path)
        self.assert_sol(path)

    def test_scope_and_approved_cursor_workers(self):
        cases = {
            "legacy": OLD.replace('BOARD_ADAPTER="hypertask"\n', ""),
            "foreign": OLD.replace('BOARD_ADAPTER="hypertask"', 'BOARD_ADAPTER="none"'),
            "other": OLD.replace('BOARD_ID="15"', 'BOARD_ID="115"'),
            "extra": OLD.replace('MODEL_CLI="hax --provider=codex --model=gpt-6.1-sol --effort=high -p"', f'MODEL_CLI="{CURSOR}"'),
        }
        for name, text in cases.items():
            path = self.home / f"{name}.conf"
            path.write_text(text)
            self.run_policy("--board15-only", "--file", path)
            self.assertEqual(path.read_text(), text)
        legacy = self.home / "legacy.conf"
        self.run_policy("--file", legacy)
        self.assertEqual(legacy.read_text(), cases["legacy"])
        multi = self.home / "multi.conf"
        multi.write_text(OLD.replace('BOARD_ID="15"', 'BOARD_ID="20, 15"'))
        self.run_policy("--file", multi)
        self.assert_sol(multi)

    def test_installer_migrates_effective_settings_without_live_units(self):
        source = self.home / "template"
        shutil.copytree(ROOT, source, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        (source / "repos.allow").write_text("# empty fixture allowlist\n")
        config = self.home / "config"
        config.mkdir()
        (config / "qa-1.conf").write_text(OLD)
        extra = config / "extra.conf"
        extra.write_text('BOARD_ADAPTER="hypertask"\nBOARD_ID="15"\nMODEL_CLI="' + CURSOR + '"\n')
        original_extra = extra.read_bytes()
        env = dict(self.env, AGENT_CONFIG_DIR=str(config), XDG_STATE_HOME=str(self.home / "state"),
                   AGENT_SYSTEMD_DIR="", SKIP_TEMPLATE_EVALS="yes", SKIP_COMPANY_SKILLS="yes")
        result = subprocess.run(
            ["bash", str(source / "install.sh"), "--dest", str(self.home / "installed"),
             "--bin", str(self.home / "installed-bin"), "--no-host-notes"],
            env=env, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("units: skipped", result.stdout)
        self.assert_sol(config / "Hypertask Product/qa-1.conf")
        self.assertEqual(extra.read_bytes(), original_extra)

    def test_creation_and_resume_cannot_restore_obsolete_choices(self):
        bin_dir = self.home / "bin"
        bin_dir.mkdir()
        for name, script in {
            "hypertask": '''#!/usr/bin/env bash
case " $* " in
  *' project show '*) echo '{"project":{"title":"Hypertask Product"}}' ;;
  *' agents list '*) echo '{"agents":[{"id":"qa-test","display_name":"QA 1"}]}' ;;
  *) exit 1 ;;
esac
''',
            "gh": "#!/usr/bin/env bash\nif [[ \" $* \" = *' api '* ]]; then echo false; fi\n",
            "systemctl": "#!/usr/bin/env bash\nexit 99\n",
        }.items():
            path = bin_dir / name
            path.write_text(script)
            path.chmod(0o755)
        repo = self.home / "repo"
        repo.mkdir()
        index = self.home / "INDEX.md"
        index.write_text("# QA skills\n")
        config = self.home / "config"
        self.env.update(AGENT_CONFIG_DIR=str(config), AGENT_BIN_DIR=str(bin_dir),
                        AGENT_SYSTEMD_DIR=str(self.home / "units"), COMPANY_SKILLS_INDEX="",
                        PATH=f"{bin_dir}:{os.environ['PATH']}")
        command = [str(ROOT / "scripts/create-agent.sh"), "--name", "QA 1", "--kind", "qa",
                   "--board", "hypertask", "--project", "15", "--wiring", "none", "--chat-page", "no",
                   "--repo", str(repo), "--pr-repo", "example/qa", "--skills-index", str(index), "--yes", "--resume"]
        result = subprocess.run(command, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        conf = config / "Hypertask Product/qa-1.conf"
        self.assert_sol(conf)
        conf.write_text(OLD + 'AGENT_REPO="' + str(repo) + '"\nPR_REPO="example/qa"\n')
        subprocess.run(command + ["--resume", "--model-cli", "claude -p --model opus"],
                       env=self.env, check=True, capture_output=True, text=True)
        self.assert_sol(conf)


if __name__ == "__main__":
    unittest.main()
