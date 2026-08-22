#!/usr/bin/env python3

import concurrent.futures
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import stop_gate


def run_git(root: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=str(root),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )


def write_valid_codex_config(root: Path) -> None:
    agents = root / ".codex" / "agents"
    agents.mkdir(parents=True, exist_ok=True)
    for filename, name, model, effort in (
        ("implementer.toml", "implementer", "gpt-5.6-terra", "high"),
        ("batch_worker.toml", "batch_worker", "gpt-5.6-luna", "medium"),
    ):
        (agents / filename).write_text(
            'name = "%s"\n' % name
            + 'description = "Scoped custom agent"\n'
            + 'model = "%s"\n' % model
            + 'model_reasoning_effort = "%s"\n' % effort
            + 'sandbox_mode = "workspace-write"\n'
            + "\n"
            + 'developer_instructions = """\n'
            + "Follow the assigned scope.\n"
            + '"""\n',
            encoding="utf-8",
        )

    (root / ".codex" / "config.toml").write_text(
        "[agents]\n"
        "enabled = true\n"
        "max_concurrent_threads_per_session = 2\n",
        encoding="utf-8",
    )

    skill = root / ".agents" / "skills" / "ship-code" / "SKILL.md"
    skill.parent.mkdir(parents=True, exist_ok=True)
    skill.write_text(
        "---\n"
        "name: ship-code\n"
        "description: Run the complete Fewer delivery workflow.\n"
        "---\n"
        "\n"
        "# Ship Code\n",
        encoding="utf-8",
    )
    interface = skill.parent / "agents" / "openai.yaml"
    interface.parent.mkdir(parents=True, exist_ok=True)
    interface.write_text(
        'interface:\n'
        '  display_name: "Ship Code"\n'
        '  short_description: "Run the verified Fewer delivery workflow"\n'
        '  default_prompt: "Use $ship-code to implement this change."\n',
        encoding="utf-8",
    )


class StopGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="fewer-stop-gate-")
        self.root = Path(self.temporary.name)
        run_git(self.root, "init", "-q")
        run_git(self.root, "config", "user.email", "test@example.com")
        run_git(self.root, "config", "user.name", "Stop Gate Test")
        (self.root / ".gitignore").write_text(".build/\n", encoding="utf-8")
        (self.root / "tracked.txt").write_text("initial\n", encoding="utf-8")
        run_git(self.root, "add", ".gitignore", "tracked.txt")
        run_git(self.root, "commit", "-q", "-m", "initial")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def event(self, name: str, **overrides):
        value = {
            "session_id": "session-1",
            "turn_id": "turn-1",
            "cwd": str(self.root),
            "hook_event_name": name,
            "permission_mode": "default",
            "stop_hook_active": False,
        }
        value.update(overrides)
        return value

    def test_unchanged_dirty_baseline_does_not_verify(self) -> None:
        (self.root / "tracked.txt").write_text("already dirty\n", encoding="utf-8")
        stop_gate.capture_baseline(self.event("UserPromptSubmit"), self.root)
        called = []

        result = stop_gate.handle_stop(
            self.event("Stop"), self.root, lambda root, session: called.append(True)
        )

        self.assertIsNone(result)
        self.assertEqual(called, [])

    def test_second_prompt_preserves_original_baseline(self) -> None:
        stop_gate.capture_baseline(self.event("UserPromptSubmit"), self.root)
        original = stop_gate.read_json(stop_gate.state_path(self.root, "session-1"))["baseline"]
        (self.root / "tracked.txt").write_text("changed before steer\n", encoding="utf-8")

        stop_gate.capture_baseline(
            self.event("UserPromptSubmit", turn_id="turn-2"), self.root
        )

        state = stop_gate.read_json(stop_gate.state_path(self.root, "session-1"))
        self.assertEqual(state["baseline"], original)
        self.assertNotEqual(state["baseline"], stop_gate.worktree_fingerprint(self.root))

    def test_dirty_cached_and_untracked_baseline_remains_stable(self) -> None:
        (self.root / "tracked.txt").write_text("staged baseline\n", encoding="utf-8")
        run_git(self.root, "add", "tracked.txt")
        (self.root / "untracked.txt").write_text("untracked baseline\n", encoding="utf-8")
        stop_gate.capture_baseline(self.event("UserPromptSubmit"), self.root)
        called = []

        result = stop_gate.handle_stop(
            self.event("Stop"), self.root, lambda root, session: called.append(True)
        )

        self.assertIsNone(result)
        self.assertEqual(called, [])

    def test_editing_existing_dirty_tracked_file_changes_fingerprint(self) -> None:
        (self.root / "tracked.txt").write_text("dirty one\n", encoding="utf-8")
        before = stop_gate.worktree_fingerprint(self.root)
        (self.root / "tracked.txt").write_text("dirty two\n", encoding="utf-8")
        self.assertNotEqual(before, stop_gate.worktree_fingerprint(self.root))

    def test_editing_existing_untracked_file_changes_fingerprint(self) -> None:
        untracked = self.root / "new.txt"
        untracked.write_text("one\n", encoding="utf-8")
        before = stop_gate.worktree_fingerprint(self.root)
        untracked.write_text("two\n", encoding="utf-8")
        self.assertNotEqual(before, stop_gate.worktree_fingerprint(self.root))

    def test_add_delete_and_rename_change_fingerprint(self) -> None:
        clean = stop_gate.worktree_fingerprint(self.root)
        added = self.root / "added.txt"
        added.write_text("added\n", encoding="utf-8")
        added_fingerprint = stop_gate.worktree_fingerprint(self.root)
        self.assertNotEqual(clean, added_fingerprint)
        added.rename(self.root / "renamed.txt")
        self.assertNotEqual(added_fingerprint, stop_gate.worktree_fingerprint(self.root))
        os.unlink(self.root / "tracked.txt")
        self.assertNotEqual(clean, stop_gate.worktree_fingerprint(self.root))

    def test_staged_only_change_changes_fingerprint(self) -> None:
        clean = stop_gate.worktree_fingerprint(self.root)
        (self.root / "tracked.txt").write_text("staged\n", encoding="utf-8")
        run_git(self.root, "add", "tracked.txt")
        self.assertNotEqual(clean, stop_gate.worktree_fingerprint(self.root))

    def test_head_only_change_changes_fingerprint(self) -> None:
        clean = stop_gate.worktree_fingerprint(self.root)
        run_git(self.root, "commit", "--allow-empty", "-q", "-m", "head only")
        self.assertNotEqual(clean, stop_gate.worktree_fingerprint(self.root))

    def test_ignored_build_change_does_not_change_fingerprint(self) -> None:
        before = stop_gate.worktree_fingerprint(self.root)
        ignored = self.root / ".build" / "artifact"
        ignored.parent.mkdir(parents=True)
        ignored.write_text("ignored\n", encoding="utf-8")
        self.assertEqual(before, stop_gate.worktree_fingerprint(self.root))

    def test_concurrent_json_writers_use_independent_temporary_files(self) -> None:
        destination = self.root / ".build" / "codex-gate" / "last-success.json"
        barrier = threading.Barrier(2)
        real_replace = os.replace

        def synchronized_replace(source, target):
            barrier.wait(timeout=3)
            real_replace(source, target)

        with mock.patch.object(stop_gate.os, "replace", side_effect=synchronized_replace):
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                futures = [
                    executor.submit(stop_gate.write_json, destination, {"writer": writer})
                    for writer in (1, 2)
                ]
                for future in futures:
                    future.result(timeout=5)

        self.assertIn(stop_gate.read_json(destination), ({"writer": 1}, {"writer": 2}))
        self.assertEqual(list(destination.parent.glob("last-success.json.*.tmp")), [])

    def test_untracked_whitespace_check_detects_errors(self) -> None:
        untracked = self.root / "untracked.txt"
        untracked.write_text("clean\n", encoding="utf-8")
        stop_gate.check_untracked_whitespace(self.root)
        untracked.write_text("trailing space \n", encoding="utf-8")
        with self.assertRaises(RuntimeError):
            stop_gate.check_untracked_whitespace(self.root)

    def test_valid_codex_config_passes(self) -> None:
        write_valid_codex_config(self.root)
        stop_gate.validate_codex_config(self.root)

    def test_agent_required_fields_cannot_be_empty(self) -> None:
        write_valid_codex_config(self.root)
        implementer = self.root / ".codex" / "agents" / "implementer.toml"
        implementer.write_text(
            implementer.read_text(encoding="utf-8").replace(
                'description = "Scoped custom agent"', 'description = ""'
            ),
            encoding="utf-8",
        )
        with self.assertRaises(ValueError):
            stop_gate.validate_codex_config(self.root)

    def test_agent_model_reasoning_and_sandbox_are_enforced(self) -> None:
        for filename, original, replacement in (
            ("implementer.toml", 'model = "gpt-5.6-terra"', 'model = "gpt-5.6-luna"'),
            ("implementer.toml", 'model_reasoning_effort = "high"', 'model_reasoning_effort = "low"'),
            ("batch_worker.toml", 'model_reasoning_effort = "medium"', 'model_reasoning_effort = "low"'),
            ("batch_worker.toml", 'sandbox_mode = "workspace-write"', 'sandbox_mode = "read-only"'),
        ):
            with self.subTest(replacement=replacement):
                write_valid_codex_config(self.root)
                agent = self.root / ".codex" / "agents" / filename
                agent.write_text(
                    agent.read_text(encoding="utf-8").replace(original, replacement),
                    encoding="utf-8",
                )
                with self.assertRaises(ValueError):
                    stop_gate.validate_codex_config(self.root)

    def test_only_two_custom_agents_are_allowed(self) -> None:
        write_valid_codex_config(self.root)
        extra = self.root / ".codex" / "agents" / "reviewer.toml"
        extra.write_text('name = "reviewer"\n', encoding="utf-8")
        with self.assertRaises(ValueError):
            stop_gate.validate_codex_config(self.root)

    def test_agent_concurrency_must_not_exceed_two(self) -> None:
        write_valid_codex_config(self.root)
        config = self.root / ".codex" / "config.toml"
        config.write_text(
            config.read_text(encoding="utf-8").replace(
                "max_concurrent_threads_per_session = 2",
                "max_concurrent_threads_per_session = 3",
            ),
            encoding="utf-8",
        )
        with self.assertRaises(ValueError):
            stop_gate.validate_codex_config(self.root)

    def test_skill_frontmatter_and_default_prompt_are_enforced(self) -> None:
        write_valid_codex_config(self.root)
        skill = self.root / ".agents" / "skills" / "ship-code" / "SKILL.md"
        skill.write_text(skill.read_text(encoding="utf-8").replace("---\n", "", 1), encoding="utf-8")
        with self.assertRaises(ValueError):
            stop_gate.validate_codex_config(self.root)

        write_valid_codex_config(self.root)
        interface = skill.parent / "agents" / "openai.yaml"
        interface.write_text(
            interface.read_text(encoding="utf-8").replace("$ship-code", "ship-code"),
            encoding="utf-8",
        )
        with self.assertRaises(ValueError):
            stop_gate.validate_codex_config(self.root)

    def test_success_receipt_skips_verification(self) -> None:
        stop_gate.capture_baseline(self.event("UserPromptSubmit"), self.root)
        (self.root / "tracked.txt").write_text("changed\n", encoding="utf-8")
        stop_gate.record_success(self.root, stop_gate.worktree_fingerprint(self.root))
        called = []

        result = stop_gate.handle_stop(
            self.event("Stop"), self.root, lambda root, session: called.append(True)
        )

        self.assertIsNone(result)
        self.assertEqual(called, [])

    def test_change_after_receipt_requires_verification(self) -> None:
        stop_gate.capture_baseline(self.event("UserPromptSubmit"), self.root)
        (self.root / "tracked.txt").write_text("verified state\n", encoding="utf-8")
        stop_gate.record_success(self.root, stop_gate.worktree_fingerprint(self.root))
        (self.root / "tracked.txt").write_text("changed after receipt\n", encoding="utf-8")
        log = self.root / ".build" / "receipt-miss.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("failed\n", encoding="utf-8")
        called = []

        def fail(root, session):
            called.append(True)
            return 1, log

        result = stop_gate.handle_stop(self.event("Stop"), self.root, fail)
        self.assertEqual(result["decision"], "block")
        self.assertEqual(called, [True])

    def test_missing_baseline_runs_verification_instead_of_failing_open(self) -> None:
        log = self.root / ".build" / "missing-baseline.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("failed\n", encoding="utf-8")
        called = []

        def fail(root, session):
            called.append(True)
            return 1, log

        result = stop_gate.handle_stop(self.event("Stop"), self.root, fail)

        self.assertEqual(result["decision"], "block")
        self.assertEqual(called, [True])
        state = stop_gate.read_json(stop_gate.state_path(self.root, "session-1"))
        self.assertTrue(state["baseline_missing"])

    def test_missing_baseline_with_current_receipt_skips_verification(self) -> None:
        stop_gate.record_success(self.root, stop_gate.worktree_fingerprint(self.root))
        called = []

        result = stop_gate.handle_stop(
            self.event("Stop"), self.root, lambda root, session: called.append(True)
        )

        self.assertIsNone(result)
        self.assertEqual(called, [])

    def test_success_without_matching_receipt_is_blocked(self) -> None:
        stop_gate.capture_baseline(self.event("UserPromptSubmit"), self.root)
        (self.root / "tracked.txt").write_text("changed\n", encoding="utf-8")
        log = self.root / ".build" / "missing-receipt.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("verify returned zero\n", encoding="utf-8")

        result = stop_gate.handle_stop(
            self.event("Stop"), self.root, lambda root, session: (0, log)
        )

        self.assertEqual(result["decision"], "block")
        self.assertIn("receipt", log.read_text(encoding="utf-8"))

    def test_post_verify_change_cannot_receive_success_receipt(self) -> None:
        stop_gate.capture_baseline(self.event("UserPromptSubmit"), self.root)
        (self.root / "tracked.txt").write_text("changed\n", encoding="utf-8")
        log = self.root / ".build" / "concurrent-change.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("verify returned zero\n", encoding="utf-8")

        def race(root, session):
            checked = stop_gate.worktree_fingerprint(root)
            stop_gate.record_success(root, checked)
            (root / "tracked.txt").write_text("changed after verify\n", encoding="utf-8")
            return 0, log

        result = stop_gate.handle_stop(self.event("Stop"), self.root, race)
        self.assertEqual(result["decision"], "block")

    def test_first_failure_blocks_second_failure_warns(self) -> None:
        stop_gate.capture_baseline(self.event("UserPromptSubmit"), self.root)
        (self.root / "tracked.txt").write_text("changed\n", encoding="utf-8")
        log = self.root / ".build" / "failure.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("verification failed\n", encoding="utf-8")

        def fail(root, session):
            return 1, log

        first = stop_gate.handle_stop(self.event("Stop"), self.root, fail)
        self.assertEqual(first["decision"], "block")

        stop_gate.capture_baseline(self.event("UserPromptSubmit", turn_id="turn-2"), self.root)
        state = stop_gate.read_json(stop_gate.state_path(self.root, "session-1"))
        self.assertTrue(state["awaiting_retry"])

        second = stop_gate.handle_stop(
            self.event("Stop", stop_hook_active=True, turn_id="turn-2"), self.root, fail
        )
        self.assertTrue(second["continue"])
        self.assertNotIn("decision", second)

    def test_plan_mode_skips_verification(self) -> None:
        stop_gate.capture_baseline(self.event("UserPromptSubmit"), self.root)
        (self.root / "tracked.txt").write_text("changed\n", encoding="utf-8")
        called = []

        result = stop_gate.handle_stop(
            self.event("Stop", permission_mode="plan"),
            self.root,
            lambda root, session: called.append(True),
        )

        self.assertIsNone(result)
        self.assertEqual(called, [])


if __name__ == "__main__":
    unittest.main()
