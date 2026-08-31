#!/usr/bin/env python3
"""Validate the file-backed project workflow state without third-party packages."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys


ACTIVE_STATUSES = {"PENDING", "IN_PROGRESS", "BLOCKED"}
ARCHIVE_STATUSES = {"DONE", "CANCELLED"}
OLD_WORKFLOW_PATTERNS = (
    r"\.agent/(?:CURRENT|PLAN)\.md",
    r"tasks/review",
    r"\b(?:planner|reviewer|executor_terra|executor_luna)\b",
)
WORKFLOW_DOCUMENTS = (
    Path("AGENTS.md"),
    Path(".agent/README.md"),
    Path(".agent/PROJECT.md"),
)
REQUIRED_ACTIVE_SECTIONS = ("Metadata", "Goal", "Scope", "Acceptance Criteria", "Validation", "Evidence")
REQUIRED_PROJECT_SECTIONS = ("Objective", "Constraints", "Blockers", "Next Action", "Last Reconciled")


@dataclass(frozen=True)
class Task:
    identifier: str
    status: str
    dependencies: tuple[str, ...]
    path: Path
    is_archive: bool


def metadata_value(content: str, names: tuple[str, ...]) -> str | None:
    alternatives = "|".join(re.escape(name) for name in names)
    match = re.search(rf"(?m)^-\s*(?:{alternatives})\s*[：:]\s*([^\r\n]+)$", content)
    return match.group(1).strip() if match else None


def task_from_file(path: Path, is_archive: bool) -> tuple[Task | None, list[str]]:
    content = path.read_text(encoding="utf-8")
    errors: list[str] = []
    identifier_match = re.search(r"(?m)^#\s*(T\d{3}):", content)
    if not identifier_match:
        return None, [f"{path}: missing task ID heading"]

    identifier = identifier_match.group(1)
    if path.stem != identifier:
        errors.append(f"{path}: filename does not match task ID {identifier}")
    if not is_archive:
        for section in REQUIRED_ACTIVE_SECTIONS:
            if not re.search(rf"(?m)^##\s+{re.escape(section)}\s*$", content):
                errors.append(f"{path}: missing active task section {section}")
        priority = metadata_value(content, ("Priority", "优先级"))
        if priority not in {"P0", "P1", "P2"}:
            errors.append(f"{path}: active task priority {priority!r} is invalid")
    status = metadata_value(content, ("Status", "状态"))
    dependencies_value = metadata_value(content, ("Dependencies", "依赖"))
    if dependencies_value is None:
        dependencies_heading = re.search(
            r"(?ms)^##\s+(?:Dependencies|依赖)\s*$\n(.*?)(?=^##\s|\Z)", content
        )
        if dependencies_heading:
            dependencies_value = dependencies_heading.group(1).strip()
    if not status:
        errors.append(f"{path}: missing status")
    if dependencies_value is None:
        errors.append(f"{path}: missing dependencies")

    dependencies = tuple(re.findall(r"T\d{3}", dependencies_value or ""))
    if status == "BLOCKED":
        evidence_match = re.search(r"(?ms)^##\s+(?:Evidence|证据)\s*$\n(.*?)(?=^##\s|\Z)", content)
        evidence = evidence_match.group(1).strip() if evidence_match else ""
        if not evidence:
            errors.append(f"{path}: BLOCKED task needs evidence")
        elif not re.search(r"解除条件|unblock(?:ing)? condition|resolution", evidence, re.IGNORECASE):
            errors.append(f"{path}: BLOCKED task needs an unblock condition")

    if not status:
        return None, errors
    return Task(identifier, status, dependencies, path, is_archive), errors


def can_execute(task: Task, tasks: dict[str, Task]) -> tuple[bool, tuple[str, ...]]:
    incomplete = tuple(
        dependency
        for dependency in task.dependencies
        if dependency not in tasks
        or not tasks[dependency].is_archive
        or tasks[dependency].status != "DONE"
    )
    return not incomplete, incomplete


def find_dependency_cycle(tasks: dict[str, Task]) -> tuple[str, ...] | None:
    visited: set[str] = set()
    visiting: list[str] = []

    def visit(identifier: str) -> tuple[str, ...] | None:
        if identifier in visiting:
            return tuple(visiting[visiting.index(identifier) :] + [identifier])
        if identifier in visited:
            return None
        visited.add(identifier)
        visiting.append(identifier)
        for dependency in tasks[identifier].dependencies:
            if dependency in tasks:
                cycle = visit(dependency)
                if cycle:
                    return cycle
        visiting.pop()
        return None

    for identifier in tasks:
        cycle = visit(identifier)
        if cycle:
            return cycle
    return None


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    tasks: dict[str, Task] = {}
    for relative_directory, is_archive in ((Path(".agent/tasks/active"), False), (Path(".agent/tasks/archive"), True)):
        directory = root / relative_directory
        if not directory.exists():
            errors.append(f"missing task directory: {relative_directory}")
            continue
        for path in sorted(directory.rglob("*.md")):
            if is_archive and not re.fullmatch(r"\d{4}-\d{2}", path.parent.name):
                errors.append(f"{path}: archived task must be under YYYY-MM")
            task, task_errors = task_from_file(path, is_archive)
            errors.extend(task_errors)
            if task is None:
                continue
            allowed = ARCHIVE_STATUSES if task.is_archive else ACTIVE_STATUSES
            if task.status not in allowed:
                location = "archive" if task.is_archive else "active"
                errors.append(f"{path}: {location} status {task.status!r} is invalid")
            if task.identifier in tasks:
                errors.append(f"duplicate task ID {task.identifier}: {tasks[task.identifier].path} and {path}")
            else:
                tasks[task.identifier] = task

    for task in tasks.values():
        for dependency in task.dependencies:
            if dependency not in tasks:
                errors.append(f"{task.path}: missing dependency {dependency}")
            elif dependency == task.identifier:
                errors.append(f"{task.path}: task cannot depend on itself")

    cycle = find_dependency_cycle(tasks)
    if cycle:
        errors.append(f"dependency cycle: {' -> '.join(cycle)}")

    project = root / ".agent/PROJECT.md"
    if not project.exists():
        errors.append("missing .agent/PROJECT.md")
    else:
        project_content = project.read_text(encoding="utf-8")
        for section in REQUIRED_PROJECT_SECTIONS:
            if not re.search(rf"(?m)^##\s+{re.escape(section)}\s*$", project_content):
                errors.append(f"{project}: missing project section {section}")
        reconciled = re.search(
            r"(?ms)^##\s+Last Reconciled\s*$\n\s*(\d{4}-\d{2}-\d{2})\s*(?=^##\s|\Z)",
            project_content,
        )
        if not reconciled:
            errors.append(f"{project}: Last Reconciled must contain YYYY-MM-DD")
        for identifier in set(re.findall(r"\bT\d{3}\b", project_content)):
            if identifier not in tasks:
                errors.append(f"{project}: references missing task {identifier}")

    workflow_documents = list(WORKFLOW_DOCUMENTS)
    skills_directory = root / ".agents/skills"
    if not skills_directory.exists():
        errors.append("missing workflow skill directory: .agents/skills")
    else:
        workflow_documents.extend(
            path.relative_to(root) for path in sorted(skills_directory.glob("*/SKILL.md"))
        )

    for relative_path in workflow_documents:
        path = root / relative_path
        if not path.exists():
            errors.append(f"missing workflow document: {relative_path}")
            continue
        content = path.read_text(encoding="utf-8")
        for pattern in OLD_WORKFLOW_PATTERNS:
            if re.search(pattern, content, re.IGNORECASE):
                errors.append(f"{path}: contains retired workflow reference matching {pattern}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Fewer .agent workflow state")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    arguments = parser.parse_args()
    errors = validate(arguments.root.resolve())
    if errors:
        print("Agent state validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("Agent state validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
