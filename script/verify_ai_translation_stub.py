#!/usr/bin/env python3
"""本机 OpenAI-compatible 截图翻译验收桩服务。

示例：
  python3 script/verify_ai_translation_stub.py --mode success
  python3 script/verify_ai_translation_stub.py --mode 401 --once

服务只监听 127.0.0.1。标准输出不会记录 OCR 文本、请求正文或 Authorization 值。
"""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import threading
import time
from typing import Callable


CHAT_COMPLETIONS_PATH = "/v1/chat/completions"
MODES = ("success", "401", "429", "500", "invalid-json", "timeout")
MAX_REQUEST_BYTES = 1_048_576


class AITranslationStubServer(ThreadingHTTPServer):
    allow_reuse_address = True

    def __init__(
        self,
        address: tuple[str, int],
        mode: str,
        timeout_seconds: float,
        request_limit: int | None,
        logger: Callable[[str], None] = print,
    ) -> None:
        super().__init__(address, AITranslationStubRequestHandler)
        self.mode = mode
        self.timeout_seconds = timeout_seconds
        self.request_limit = request_limit
        self.request_count = 0
        self.request_lock = threading.Lock()
        self.safe_logger = logger

    def log_metadata(self, method: str, path: str, payload: object) -> None:
        payload_dict = payload if isinstance(payload, dict) else {}
        messages = payload_dict.get("messages")
        user_content = ""
        if isinstance(messages, list):
            for message in messages:
                if isinstance(message, dict) and message.get("role") == "user":
                    content = message.get("content")
                    if isinstance(content, str):
                        user_content = content
                    break

        model = payload_dict.get("model")
        safe_model = json.dumps(model if isinstance(model, str) else "<missing>")
        has_image = contains_structural_key(payload_dict, "image")
        has_coordinates = contains_structural_key(payload_dict, "coordinates")
        self.safe_logger(
            "request "
            f"method={method} path={path} model={safe_model} "
            f"source_language_present={str('Source language:' in user_content).lower()} "
            f"target_language_present={str('Target language:' in user_content).lower()} "
            f"image={str(has_image).lower()} coordinates={str(has_coordinates).lower()}"
        )

    def complete_request(self) -> None:
        with self.request_lock:
            self.request_count += 1
            should_stop = self.request_limit is not None and self.request_count >= self.request_limit
        if should_stop:
            threading.Thread(target=self.shutdown, daemon=True).start()


class AITranslationStubRequestHandler(BaseHTTPRequestHandler):
    server: AITranslationStubServer

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = self.path.split("?", 1)[0]
        if path != CHAT_COMPLETIONS_PATH:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.server.complete_request()
            return

        content_length = parse_content_length(self.headers.get("Content-Length"))
        if content_length is None or content_length > MAX_REQUEST_BYTES:
            self.send_response(413)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.server.complete_request()
            return

        try:
            payload = json.loads(self.rfile.read(content_length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = None
        self.server.log_metadata("POST", path, payload)

        if not isinstance(payload, dict):
            self.send_response(400)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.server.complete_request()
            return

        try:
            self.respond_for_mode()
        finally:
            self.server.complete_request()

    def respond_for_mode(self) -> None:
        mode = self.server.mode
        if mode == "timeout":
            time.sleep(self.server.timeout_seconds)
            self.send_json(200, chat_completion_response())
            return
        if mode == "invalid-json":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b"not-json")))
            self.end_headers()
            self.wfile.write(b"not-json")
            return
        if mode in {"401", "429", "500"}:
            self.send_json(int(mode), {"error": {"message": "stub failure"}})
            return
        self.send_json(200, chat_completion_response())

    def send_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def log_message(self, format: str, *args: object) -> None:
        # 禁用默认日志，避免意外输出请求细节。
        return


def chat_completion_response() -> dict[str, object]:
    return {"choices": [{"message": {"content": "桩服务译文"}}]}


def contains_structural_key(value: object, target: str) -> bool:
    if isinstance(value, dict):
        return any(
            key.lower() == target or contains_structural_key(child, target)
            for key, child in value.items()
            if isinstance(key, str)
        )
    if isinstance(value, list):
        return any(contains_structural_key(item, target) for item in value)
    return False


def parse_content_length(value: str | None) -> int | None:
    try:
        length = int(value or "")
    except ValueError:
        return None
    return length if length >= 0 else None


def parser() -> argparse.ArgumentParser:
    argument_parser = argparse.ArgumentParser(description=__doc__)
    argument_parser.add_argument(
        "--mode",
        choices=MODES,
        default=os.environ.get("FEWER_AI_STUB_MODE", "success"),
        help="响应模式（默认：success；也可通过 FEWER_AI_STUB_MODE 设置）。",
    )
    argument_parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("FEWER_AI_STUB_PORT", "0")),
        help="监听端口；0 表示随机可用端口（默认：0）。",
    )
    argument_parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=float(os.environ.get("FEWER_AI_STUB_TIMEOUT_SECONDS", "31")),
        help="timeout 模式的响应延迟秒数（默认：31，超过应用 30 秒请求超时）。",
    )
    argument_parser.add_argument(
        "--once",
        action="store_true",
        help="处理一个请求后自动关闭服务，适合单次连接测试。",
    )
    return argument_parser


def main() -> int:
    arguments = parser().parse_args()
    if not 0 <= arguments.port <= 65_535:
        parser().error("--port 必须在 0 到 65535 之间")
    if arguments.timeout_seconds < 0:
        parser().error("--timeout-seconds 不能为负数")

    server = AITranslationStubServer(
        ("127.0.0.1", arguments.port),
        arguments.mode,
        arguments.timeout_seconds,
        1 if arguments.once else None,
    )
    host, port = server.server_address
    print(f"ENDPOINT=http://{host}:{port}{CHAT_COMPLETIONS_PATH}", flush=True)
    print(f"MODE={arguments.mode}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
