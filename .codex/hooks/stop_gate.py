#!/usr/bin/env python3
"""Baseline-aware Codex Stop gate for the Fewer repository."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Callable, Dict, Optional, Tuple


GATE_VERSION = 1
MAX_REASON_CHARS = 4_000


def git_root(cwd: Optional[Path] = None) -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return Path(os.fsdecode(result.stdout).strip()).resolve()


def git_bytes(root: Path, *args: str, allow_failure: bool = False) -> bytes:
    result = subprocess.run(
        ["git", *args],
        cwd=str(root),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0 and not allow_failure:
        raise RuntimeError(os.fsdecode(result.stderr).strip() or "git command failed")
    return result.stdout if result.returncode == 0 else b""


def hash_regular_file(path: Path) -> bytes:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.digest()


def update_untracked_hash(digest: "hashlib._Hash", root: Path) -> None:
    raw_paths = git_bytes(root, "ls-files", "--others", "--exclude-standard", "-z")
    for raw_path in sorted(path for path in raw_paths.split(b"\0") if path):
        relative = os.fsdecode(raw_path)
        full_path = root / relative
        try:
            metadata = full_path.lstat()
        except FileNotFoundError:
            continue

        digest.update(b"untracked\0")
        digest.update(raw_path)
        digest.update(b"\0")
        digest.update(str(stat.S_IMODE(metadata.st_mode)).encode("ascii"))
        digest.update(b"\0")

        if stat.S_ISLNK(metadata.st_mode):
            digest.update(b"symlink\0")
            digest.update(os.fsencode(os.readlink(str(full_path))))
        elif stat.S_ISREG(metadata.st_mode):
            digest.update(b"file\0")
            digest.update(hash_regular_file(full_path))
        else:
            digest.update(b"other\0")
            digest.update(str(metadata.st_mode).encode("ascii"))
        digest.update(b"\0")


def worktree_fingerprint(root: Path) -> str:
    """Hash HEAD, index, tracked worktree changes, and untracked contents."""
    digest = hashlib.sha256()
    head = git_bytes(root, "rev-parse", "--verify", "HEAD", allow_failure=True)
    digest.update(b"head\0")
    digest.update(head or b"NO_HEAD")
    digest.update(b"\0cached\0")
    digest.update(
        git_bytes(root, "diff", "--cached", "--binary", "--full-index", "--no-ext-diff")
    )
    digest.update(b"\0worktree\0")
    digest.update(git_bytes(root, "diff", "--binary", "--full-index", "--no-ext-diff"))
    digest.update(b"\0")
    update_untracked_hash(digest, root)
    return digest.hexdigest()


def gate_directory(root: Path) -> Path:
    return root / ".build" / "codex-gate"


def session_key(session_id: str) -> str:
    return hashlib.sha256(session_id.encode("utf-8", errors="replace")).hexdigest()[:20]


def session_directory(root: Path, session_id: str) -> Path:
    return gate_directory(root) / "sessions" / session_key(session_id)


def state_path(root: Path, session_id: str) -> Path:
    return session_directory(root, session_id) / "state.json"


def receipt_path(root: Path) -> Path:
    return gate_directory(root) / "last-success.json"


def write_json(path: Path, value: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: Optional[str] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=str(path.parent),
            prefix=path.name + ".",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(
                json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
            )
        os.replace(temporary_name, str(path))
    finally:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def read_json(path: Path) -> Optional[Dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    return value if isinstance(value, dict) else None


def clear_state(root: Path, session_id: str) -> None:
    try:
        state_path(root, session_id).unlink()
    except FileNotFoundError:
        pass


def record_success(root: Path, fingerprint: str) -> str:
    if len(fingerprint) != 64 or any(character not in "0123456789abcdef" for character in fingerprint):
        raise ValueError("invalid verification fingerprint")
    current = worktree_fingerprint(root)
    if current != fingerprint:
        raise RuntimeError("worktree changed before the verification receipt was recorded")
    write_json(
        receipt_path(root),
        {
            "version": GATE_VERSION,
            "fingerprint": fingerprint,
            "verified_at": int(time.time()),
        },
    )
    return fingerprint


def receipt_matches(root: Path, fingerprint: str) -> bool:
    receipt = read_json(receipt_path(root))
    return bool(
        receipt
        and receipt.get("version") == GATE_VERSION
        and receipt.get("fingerprint") == fingerprint
    )


def capture_baseline(event: Dict[str, Any], root: Path) -> None:
    session_id = str(event.get("session_id") or "unknown-session")
    existing = read_json(state_path(root, session_id))
    if existing and existing.get("version") == GATE_VERSION and existing.get("baseline"):
        return
    write_json(
        state_path(root, session_id),
        {
            "version": GATE_VERSION,
            "turn_id": str(event.get("turn_id") or "unknown-turn"),
            "baseline": worktree_fingerprint(root),
            "awaiting_retry": False,
        },
    )


def verification_log_path(root: Path, session_id: str) -> Path:
    return session_directory(root, session_id) / "verify.log"


def run_verification(root: Path, session_id: str) -> Tuple[int, Path]:
    log_path = verification_log_path(root, session_id)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment["CODEX_STOP_GATE_RUNNING"] = "1"
    try:
        with log_path.open("wb") as log:
            result = subprocess.run(
                [str(root / "script" / "verify.sh")],
                cwd=str(root),
                stdout=log,
                stderr=subprocess.STDOUT,
                env=environment,
                timeout=840,
            )
        return result.returncode, log_path
    except subprocess.TimeoutExpired:
        with log_path.open("ab") as log:
            log.write(b"\nStop gate timed out after 840 seconds.\n")
        return 124, log_path
    except OSError as error:
        with log_path.open("ab") as log:
            log.write(("\nUnable to run verification: %s\n" % error).encode("utf-8"))
        return 127, log_path


def tail_text(path: Path, limit: int = MAX_REASON_CHARS) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return "（无法读取验证日志）"
    return text[-limit:]


def append_log(path: Path, message: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as log:
        log.write(message)


def validate_agent_config(
    root: Path,
    filename: str,
    expected_name: str,
    expected_model: str,
    expected_reasoning_effort: str,
) -> None:
    """Validate one deliberately small custom-agent TOML schema on Python 3.9."""
    path = root / ".codex" / "agents" / filename
    lines = path.read_text(encoding="utf-8").splitlines()
    expected_keys = ["name", "description", "model", "model_reasoning_effort", "sandbox_mode"]
    values: Dict[str, str] = {}
    index = 0

    for key in expected_keys:
        if index >= len(lines) or not lines[index].startswith(key + " = "):
            raise ValueError("%s 缺少或错序字段：%s" % (filename, key))
        raw_value = lines[index].split(" = ", 1)[1]
        value = json.loads(raw_value)
        if not isinstance(value, str) or not value:
            raise ValueError("%s 字段必须是非空字符串：%s" % (filename, key))
        values[key] = value
        index += 1

    if index >= len(lines) or lines[index] != "":
        raise ValueError("%s 顶层字段后需要一个空行" % filename)
    index += 1
    if index >= len(lines) or lines[index] != 'developer_instructions = """':
        raise ValueError("%s 缺少 developer_instructions" % filename)
    index += 1
    try:
        closing = lines.index('"""', index)
    except ValueError as error:
        raise ValueError("%s 的 developer_instructions 未闭合" % filename) from error
    if closing == index or any(line.strip() for line in lines[closing + 1 :]):
        raise ValueError("%s 的 developer_instructions 为空或存在多余内容" % filename)
    if any('"""' in line for line in lines[index:closing]):
        raise ValueError("%s 的 developer_instructions 含非法分隔符" % filename)
    if values["name"] != expected_name:
        raise ValueError("%s 的 name 必须是 %s" % (filename, expected_name))
    if values["model"] != expected_model:
        raise ValueError("%s 必须使用 %s" % (filename, expected_model))
    if values["model_reasoning_effort"] != expected_reasoning_effort:
        raise ValueError(
            "%s 必须使用 %s reasoning" % (filename, expected_reasoning_effort)
        )
    if values["sandbox_mode"] != "workspace-write":
        raise ValueError("%s 必须使用 workspace-write" % filename)


def validate_agent_configs(root: Path) -> None:
    agents_dir = root / ".codex" / "agents"
    expected_files = {"implementer.toml", "batch_worker.toml"}
    actual_files = {path.name for path in agents_dir.glob("*.toml")}
    if actual_files != expected_files:
        raise ValueError(
            ".codex/agents 必须且只能包含：%s" % ", ".join(sorted(expected_files))
        )
    validate_agent_config(root, "implementer.toml", "implementer", "gpt-5.6-terra", "high")
    validate_agent_config(
        root, "batch_worker.toml", "batch_worker", "gpt-5.6-luna", "medium"
    )


def validate_agent_runtime_config(root: Path) -> None:
    path = root / ".codex" / "config.toml"
    lines = path.read_text(encoding="utf-8").splitlines()
    try:
        index = lines.index("[agents]") + 1
    except ValueError as error:
        raise ValueError(".codex/config.toml 缺少 [agents]") from error

    values: Dict[str, object] = {}
    while index < len(lines) and not lines[index].startswith("["):
        line = lines[index].strip()
        if line and not line.startswith("#"):
            if " = " not in line:
                raise ValueError(".codex/config.toml 的 [agents] 含无效配置")
            key, raw_value = line.split(" = ", 1)
            values[key] = json.loads(raw_value)
        index += 1

    if values.get("enabled") is not True:
        raise ValueError(".codex/config.toml 必须启用 agents")
    max_threads = values.get("max_concurrent_threads_per_session")
    if isinstance(max_threads, bool) or not isinstance(max_threads, int) or not 1 <= max_threads <= 2:
        raise ValueError("agents.max_concurrent_threads_per_session 必须在 1 到 2 之间")


def validate_skill_config(root: Path) -> None:
    skill_path = root / ".agents" / "skills" / "ship-code" / "SKILL.md"
    lines = skill_path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise ValueError("ship-code SKILL.md 缺少 YAML frontmatter")
    try:
        closing = lines.index("---", 1)
    except ValueError as error:
        raise ValueError("ship-code SKILL.md 的 frontmatter 未闭合") from error

    metadata: Dict[str, str] = {}
    for line in lines[1:closing]:
        if ":" not in line:
            raise ValueError("ship-code SKILL.md 含无效 frontmatter 行")
        key, value = line.split(":", 1)
        if key in metadata or key not in {"name", "description"}:
            raise ValueError("ship-code SKILL.md 含重复或不支持的字段：%s" % key)
        metadata[key] = value.strip()
    if metadata.get("name") != "ship-code" or not metadata.get("description"):
        raise ValueError("ship-code SKILL.md 必须提供 name 和 description")
    if not any(line.strip() for line in lines[closing + 1 :]):
        raise ValueError("ship-code SKILL.md 正文不能为空")

    interface_path = skill_path.parent / "agents" / "openai.yaml"
    interface_lines = interface_path.read_text(encoding="utf-8").splitlines()
    if not interface_lines or interface_lines[0] != "interface:":
        raise ValueError("ship-code openai.yaml 缺少 interface")
    expected = ["display_name", "short_description", "default_prompt"]
    interface: Dict[str, str] = {}
    for line, key in zip(interface_lines[1:], expected):
        prefix = "  %s: " % key
        if not line.startswith(prefix):
            raise ValueError("ship-code openai.yaml 缺少或错序字段：%s" % key)
        value = json.loads(line[len(prefix) :])
        if not isinstance(value, str) or not value:
            raise ValueError("ship-code openai.yaml 字段必须是非空字符串：%s" % key)
        interface[key] = value
    if len(interface_lines) != 4:
        raise ValueError("ship-code openai.yaml 含未验证的额外内容")
    if not 25 <= len(interface["short_description"]) <= 64:
        raise ValueError("ship-code short_description 必须为 25 到 64 个字符")
    if "$ship-code" not in interface["default_prompt"]:
        raise ValueError("ship-code default_prompt 必须显式包含 $ship-code")


def validate_codex_config(root: Path) -> None:
    validate_agent_configs(root)
    validate_agent_runtime_config(root)
    validate_skill_config(root)


def check_untracked_whitespace(root: Path) -> None:
    raw_paths = git_bytes(root, "ls-files", "--others", "--exclude-standard", "-z")
    failures = []
    for raw_path in sorted(path for path in raw_paths.split(b"\0") if path):
        full_path = root / os.fsdecode(raw_path)
        try:
            if not full_path.is_file() or full_path.is_symlink():
                continue
        except OSError:
            continue
        result = subprocess.run(
            ["git", "diff", "--no-index", "--check", "--", "/dev/null", str(full_path)],
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        output = os.fsdecode(result.stdout).strip()
        if result.returncode not in (0, 1):
            failures.append(output or "无法检查未跟踪文件：%s" % raw_path)
        elif output:
            failures.append(output)
    if failures:
        raise RuntimeError("\n".join(failures))


VerificationRunner = Callable[[Path, str], Tuple[int, Path]]


def handle_stop(
    event: Dict[str, Any],
    root: Path,
    verify_runner: VerificationRunner = run_verification,
) -> Optional[Dict[str, Any]]:
    session_id = str(event.get("session_id") or "unknown-session")
    if event.get("permission_mode") == "plan":
        clear_state(root, session_id)
        return None

    state = read_json(state_path(root, session_id))
    current = worktree_fingerprint(root)
    if not state or state.get("version") != GATE_VERSION or not state.get("baseline"):
        if receipt_matches(root, current):
            clear_state(root, session_id)
            return None
        state = {
            "version": GATE_VERSION,
            "turn_id": str(event.get("turn_id") or "unknown-turn"),
            "baseline": current,
            "awaiting_retry": False,
            "baseline_missing": True,
        }

    if current == state.get("baseline"):
        if not state.get("baseline_missing"):
            clear_state(root, session_id)
            return None
    if receipt_matches(root, current):
        clear_state(root, session_id)
        return None

    return_code, log_path = verify_runner(root, session_id)
    if return_code == 0:
        verified_current = worktree_fingerprint(root)
        if receipt_matches(root, verified_current):
            clear_state(root, session_id)
            return None
        return_code = 125
        append_log(
            log_path,
            "\n验证命令返回成功，但没有为当前精确工作树生成匹配的 receipt。\n",
        )

    write_json(
        state_path(root, session_id),
        {
            **state,
            "awaiting_retry": True,
            "failed_fingerprint": current,
            "last_exit_code": return_code,
        },
    )
    message = (
        "Fewer Definition of Done 未通过（exit %d）。完整日志：%s\n\n%s"
        % (return_code, log_path, tail_text(log_path))
    )

    if bool(event.get("stop_hook_active")):
        clear_state(root, session_id)
        return {
            "continue": True,
            "systemMessage": message
            + "\n\nStop Gate 已避免再次续跑；最终回复必须明确报告仍未通过的验证。",
        }

    return {
        "decision": "block",
        "reason": message
        + "\n\n修复由本任务引入的失败并重新运行验证；若失败与本任务无关，保留证据并在最终回复中明确报告。",
    }


def emit(value: Optional[Dict[str, Any]]) -> None:
    if value is not None:
        sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")


def event_root(event: Dict[str, Any]) -> Path:
    cwd = event.get("cwd")
    return git_root(Path(str(cwd))) if cwd else git_root()


def run_hook() -> int:
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise ValueError("hook input must be a JSON object")
        root = event_root(event)
        event_name = event.get("hook_event_name")
        if event_name == "UserPromptSubmit":
            capture_baseline(event, root)
        elif event_name == "Stop":
            emit(handle_stop(event, root))
        return 0
    except Exception as error:  # Fail open so a broken gate cannot trap the task.
        emit(
            {
                "continue": True,
                "systemMessage": "Fewer Stop Gate 执行异常，已放行：%s。请显式运行 ./script/verify.sh。"
                % error,
            }
        )
        return 0


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--fingerprint", action="store_true")
    group.add_argument("--record-success", metavar="FINGERPRINT")
    group.add_argument("--validate-config", action="store_true")
    group.add_argument("--check-untracked", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if arguments.fingerprint:
        print(worktree_fingerprint(git_root()))
        return 0
    if arguments.record_success:
        record_success(git_root(), arguments.record_success)
        return 0
    if arguments.validate_config:
        validate_codex_config(git_root())
        return 0
    if arguments.check_untracked:
        check_untracked_whitespace(git_root())
        return 0
    return run_hook()


if __name__ == "__main__":
    raise SystemExit(main())
