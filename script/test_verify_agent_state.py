#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import verify_agent_state


class VerifyAgentStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="fewer-agent-state-")
        self.root = Path(self.temporary.name)
        for document in verify_agent_state.WORKFLOW_DOCUMENTS:
            path = self.root / document
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# workflow\n", encoding="utf-8")
        (self.root / ".agents/skills/project-workflow").mkdir(parents=True, exist_ok=True)
        (self.root / ".agents/skills/project-workflow/SKILL.md").write_text(
            "---\nname: project-workflow\ndescription: workflow\n---\n",
            encoding="utf-8",
        )
        (self.root / ".agent/tasks/active").mkdir(parents=True)
        (self.root / ".agent/tasks/archive/2026-08").mkdir(parents=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_task(
        self,
        location: str,
        identifier: str,
        status: str,
        dependencies: str = "无",
        evidence: str = "",
    ) -> None:
        path = self.root / ".agent/tasks" / location / f"{identifier}.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"# {identifier}: task\n\n"
            "## Metadata\n"
            "- Priority: P1\n"
            f"- Status: {status}\n"
            f"- Dependencies: {dependencies}\n\n"
            "## Goal\nresult\n\n"
            "## Scope\nscope\n\n"
            "## Acceptance Criteria\n- pass\n\n"
            "## Validation\n- test\n\n"
            f"## Evidence\n{evidence}\n",
            encoding="utf-8",
        )

    def write_project(self, body: str = "") -> None:
        (self.root / ".agent/PROJECT.md").write_text(
            "# Project\n\n"
            "## Objective\nobjective\n\n"
            "## Constraints\nconstraints\n\n"
            f"## Blockers\n{body}\n\n"
            "## Next Action\nnext\n\n"
            "## Last Reconciled\n2026-08-31\n",
            encoding="utf-8",
        )

    def errors(self) -> list[str]:
        return verify_agent_state.validate(self.root)

    def test_valid_state_passes(self) -> None:
        self.write_task("archive/2026-08", "T001", "DONE")
        self.write_task("active", "T002", "PENDING", "T001")
        self.write_project("T001")
        self.assertEqual(self.errors(), [])

    def test_active_and_archive_statuses_are_restricted(self) -> None:
        self.write_task("active", "T001", "DONE")
        self.write_task("archive/2026-08", "T002", "PENDING")
        self.write_project()
        errors = "\n".join(self.errors())
        self.assertIn("active status 'DONE' is invalid", errors)
        self.assertIn("archive status 'PENDING' is invalid", errors)

    def test_active_task_sections_and_archive_month_are_required(self) -> None:
        (self.root / ".agent/tasks/active/T001.md").write_text(
            "# T001: task\n\n- Status: PENDING\n- Dependencies: 无\n",
            encoding="utf-8",
        )
        self.write_task("archive", "T002", "DONE")
        self.write_project()
        errors = "\n".join(self.errors())
        self.assertIn("missing active task section Goal", errors)
        self.assertIn("active task priority None is invalid", errors)
        self.assertIn("archived task must be under YYYY-MM", errors)

    def test_task_filename_must_match_heading(self) -> None:
        path = self.root / ".agent/tasks/active/T001.md"
        path.write_text(
            "# T002: task\n\n## Metadata\n- Priority: P1\n- Status: PENDING\n"
            "- Dependencies: 无\n\n## Goal\nresult\n\n## Scope\nscope\n\n"
            "## Acceptance Criteria\n- pass\n\n## Validation\n- test\n\n## Evidence\n",
            encoding="utf-8",
        )
        self.write_project("T002")
        self.assertIn("filename does not match task ID T002", "\n".join(self.errors()))

    def test_duplicate_task_id_fails(self) -> None:
        self.write_task("active", "T001", "PENDING")
        self.write_task("archive/2026-08", "T001", "DONE")
        self.write_project()
        self.assertIn("duplicate task ID T001", "\n".join(self.errors()))

    def test_missing_self_and_cyclic_dependencies_fail(self) -> None:
        self.write_task("active", "T001", "PENDING", "T999")
        self.write_task("active", "T002", "PENDING", "T002")
        self.write_task("active", "T003", "PENDING", "T004")
        self.write_task("active", "T004", "PENDING", "T003")
        self.write_project()
        errors = "\n".join(self.errors())
        self.assertIn("missing dependency T999", errors)
        self.assertIn("cannot depend on itself", errors)
        self.assertIn("dependency cycle", errors)

    def test_blocked_task_requires_evidence_and_unblock_condition(self) -> None:
        self.write_task("active", "T001", "BLOCKED")
        self.write_task("active", "T002", "BLOCKED", evidence="observed failure")
        self.write_project()
        errors = "\n".join(self.errors())
        self.assertIn("T001.md: BLOCKED task needs evidence", errors)
        self.assertIn("T002.md: BLOCKED task needs an unblock condition", errors)

    def test_project_reference_to_missing_task_fails(self) -> None:
        self.write_task("active", "T001", "PENDING")
        self.write_project("T999")
        self.assertIn("references missing task T999", "\n".join(self.errors()))

    def test_project_requires_hot_state_sections_and_reconciled_date(self) -> None:
        self.write_task("active", "T001", "PENDING")
        (self.root / ".agent/PROJECT.md").write_text(
            "# Project\n\n## Objective\nobjective\n\n## Last Reconciled\ntoday\n",
            encoding="utf-8",
        )
        errors = "\n".join(self.errors())
        self.assertIn("missing project section Constraints", errors)
        self.assertIn("Last Reconciled must contain YYYY-MM-DD", errors)

    def test_retired_workflow_references_fail(self) -> None:
        self.write_task("active", "T001", "PENDING")
        self.write_project()
        for pattern in (".agent/CURRENT.md", "tasks/review", "executor_terra"):
            with self.subTest(pattern=pattern):
                (self.root / "AGENTS.md").write_text(pattern, encoding="utf-8")
                self.assertIn("retired workflow reference", "\n".join(self.errors()))
                (self.root / "AGENTS.md").write_text("# workflow\n", encoding="utf-8")

        extra_skill = self.root / ".agents/skills/extra/SKILL.md"
        extra_skill.parent.mkdir(parents=True)
        extra_skill.write_text("executor_luna", encoding="utf-8")
        self.assertIn("retired workflow reference", "\n".join(self.errors()))

    def test_pending_execution_requires_archived_done_dependencies(self) -> None:
        archive = verify_agent_state.Task("T001", "DONE", (), Path("archive"), True)
        active = verify_agent_state.Task("T002", "PENDING", ("T001",), Path("active"), False)
        self.assertEqual(verify_agent_state.can_execute(active, {"T001": archive, "T002": active}), (True, ()))
        unfinished = verify_agent_state.Task("T001", "PENDING", (), Path("active"), False)
        self.assertEqual(
            verify_agent_state.can_execute(active, {"T001": unfinished, "T002": active}),
            (False, ("T001",)),
        )


if __name__ == "__main__":
    unittest.main()
