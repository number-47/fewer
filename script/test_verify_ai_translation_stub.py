#!/usr/bin/env python3

from __future__ import annotations

import http.client
import json
from pathlib import Path
import sys
import threading
import time
import unittest


sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import verify_ai_translation_stub


class AITranslationStubTests(unittest.TestCase):
    def setUp(self) -> None:
        self.logs: list[str] = []
        self.server = verify_ai_translation_stub.AITranslationStubServer(
            ("127.0.0.1", 0),
            "success",
            0.01,
            None,
            self.logs.append,
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def testSuccessReturnsChatCompletionAndSafeMetadataOnly(self) -> None:
        status, body = self.post({
            "model": "local-model",
            "messages": [
                {"role": "system", "content": "instruction"},
                {
                    "role": "user",
                    "content": "Source language: en\nTarget language: zh-Hans\nOCR text:\nprivate OCR text",
                },
            ],
        })

        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["choices"][0]["message"]["content"], "桩服务译文")
        self.assertEqual(len(self.logs), 1)
        self.assertIn("method=POST path=/v1/chat/completions model=\"local-model\"", self.logs[0])
        self.assertIn("source_language_present=true target_language_present=true", self.logs[0])
        self.assertIn("image=false coordinates=false", self.logs[0])
        self.assertNotIn("private OCR text", self.logs[0])
        self.assertNotIn("secret-key", self.logs[0])

    def testModesReturnExpectedStatusOrInvalidJSON(self) -> None:
        for mode, expected_status in [("401", 401), ("429", 429), ("500", 500)]:
            with self.subTest(mode=mode):
                self.server.mode = mode
                status, _ = self.post({"model": "test", "messages": []})
                self.assertEqual(status, expected_status)

        self.server.mode = "invalid-json"
        status, body = self.post({"model": "test", "messages": []})
        self.assertEqual(status, 200)
        self.assertEqual(body, "not-json")

    def testTimeoutModeDelaysResponse(self) -> None:
        self.server.mode = "timeout"
        started = time.monotonic()
        status, _ = self.post({"model": "test", "messages": []})

        self.assertEqual(status, 200)
        self.assertGreaterEqual(time.monotonic() - started, 0.01)

    def testOnlyLoopbackAddressIsBound(self) -> None:
        self.assertEqual(self.server.server_address[0], "127.0.0.1")

    def post(self, payload: dict[str, object]) -> tuple[int, str]:
        host, port = self.server.server_address
        connection = http.client.HTTPConnection(host, port, timeout=2)
        try:
            connection.request(
                "POST",
                verify_ai_translation_stub.CHAT_COMPLETIONS_PATH,
                body=json.dumps(payload),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": "Bearer secret-key",
                },
            )
            response = connection.getresponse()
            return response.status, response.read().decode("utf-8")
        finally:
            connection.close()


if __name__ == "__main__":
    unittest.main()
