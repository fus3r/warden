import importlib.util
import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("warden_remote", ROOT / "Resources/Remote/warden-remote.py")
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)
SECRET = "PRIVATE_PROMPT_TOOL_OUTPUT_TOKEN_89a"


class CollectorTests(unittest.TestCase):
    def test_codex_only_sends_metadata_and_question_flag(self):
        entries = [
            {"type": "session_meta", "payload": {"id": "session", "cwd": "/project", "git": {"token": SECRET}}},
            {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"text": SECRET}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"text": SECRET + "?"}]}},
            {"type": "response_item", "payload": {"type": "function_call", "name": "shell", "arguments": SECRET}},
            {"type": "response_item", "payload": {"type": "function_call_output", "call_id": "c1", "output": SECRET}},
            {"type": "event_msg", "payload": {"type": "task_complete", "last_agent_message": SECRET + "?", "error": {"message": SECRET}}},
        ]
        safe = remote.events("\n".join(map(json.dumps, entries)).encode(), "Codex")
        self.assertNotIn(SECRET, remote.compact(safe))
        self.assertEqual(safe[0]["payload"], {"id": "session", "cwd": "/project"})
        self.assertEqual(safe[-1]["payload"]["last_agent_message"], remote.QUESTION)
        self.assertEqual(len(safe), 5)

    def test_claude_tool_question_and_usage_without_content(self):
        value = {"type": "assistant", "sessionId": "s", "cwd": "/project", "timestamp": "2026-10-05T12:00:00Z",
                 "message": {"model": "claude-sonnet-4-5", "stop_reason": "tool_use", "usage": {"input_tokens": 123, "secret": SECRET},
                             "content": [{"type": "thinking", "thinking": SECRET}, {"type": "text", "text": SECRET},
                                         {"type": "tool_use", "name": "AskUserQuestion", "input": {"questions": [{"question": SECRET + "?", "options": [SECRET]}]}}]}}
        safe = remote.sanitize_claude(value)
        self.assertNotIn(SECRET, remote.compact(safe))
        self.assertEqual(safe["message"]["usage"]["input_tokens"], 123)
        self.assertEqual(safe["message"]["content"][-1]["input"]["questions"][0]["question"], remote.QUESTION)
        value.update(isApiErrorMessage=True, error=SECRET)
        self.assertNotIn(SECRET, remote.compact(remote.sanitize_claude(value)))

    def test_quota_replies_are_allowlisted(self):
        codex = remote.sanitize_usage("Codex", {"rateLimits": {"primary": {"usedPercent": 21, "windowDurationMins": 300, "resetsAt": 1000, "secret": SECRET}, "account": SECRET}, "credentials": SECRET})
        claude = remote.sanitize_usage("Claude", {"rate_limits": {"five_hour": {"utilization": 34, "resets_at": "2026-10-06T00:00:00Z", "extra": SECRET}, "model_scoped": [{"display_name": "Sonnet", "utilization": 12, "secret": SECRET}]}, "email": SECRET})
        self.assertNotIn(SECRET, remote.compact([codex, claude]))
        self.assertEqual(codex["rateLimits"]["primary"]["usedPercent"], 21)
        self.assertEqual(claude["rate_limits"]["five_hour"]["utilization"], 34)

    def test_blocking_input_clears_only_after_its_reply(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "session.jsonl"
            entries = [{"type": "session_meta", "payload": {"id": "session", "cwd": "/project"}},
                       {"type": "response_item", "payload": {"type": "function_call", "name": "functions.request_user_input", "call_id": "c1", "arguments": SECRET}}]
            path.write_text("\n".join(map(json.dumps, entries)) + "\n")
            value = remote.read_file(path, "Codex", None, pathlib.Path(directory))
            self.assertTrue(value["inputPending"])
            self.assertNotIn(SECRET, remote.compact(value))
            with path.open("a") as stream:
                stream.write(json.dumps({"type": "response_item", "payload": {"type": "function_call_output", "call_id": "c1", "output": SECRET}}) + "\n")
            self.assertFalse(remote.read_file(path, "Codex", None, pathlib.Path(directory))["inputPending"])

    def test_large_tool_result_and_partial_line_keep_latest_complete_state(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "session.jsonl"
            meta = {"type": "session_meta", "payload": {"id": "session", "cwd": "/project"}}
            done = {"type": "event_msg", "payload": {"type": "task_complete", "last_agent_message": "Done."}}
            large = {"type": "response_item", "payload": {"type": "function_call_output", "call_id": "large", "output": SECRET * 70000}}
            path.write_text("\n".join(map(json.dumps, [meta, done, large])) + "\n" + '{"type":"event_msg",')
            value = remote.read_file(path, "Codex", None, pathlib.Path(directory))
            self.assertIn('"task_complete"', value["tail"])
            self.assertNotIn(SECRET, remote.compact(value))
            self.assertLess(len(remote.compact(value)), 4096)

    def test_codex_index_keeps_only_titles(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = pathlib.Path(directory)
            (folder / "session_index.jsonl").write_text(json.dumps({"id": "s1", "thread_name": "Study", "last_prompt": SECRET}) + "\n")
            self.assertEqual(remote.codex_titles(folder), {"s1": "Study"})

    def test_several_recent_conversations_do_not_guess_a_tmux_pane(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            folder = home / ".codex/sessions"
            folder.mkdir(parents=True)
            for identity in ("s1", "s2"):
                value = {"type": "session_meta", "payload": {"id": identity, "cwd": "/project"}}
                (folder / (identity + ".jsonl")).write_text(json.dumps(value) + "\n")
            process = {"pid": 123, "provider": "Codex", "cwd": "/project", "argv": ["codex"]}
            pane = {123: {"session": "$0", "window": "@0", "pane": "%1"}}
            with mock.patch.object(remote.Collector, "refresh_providers"), mock.patch.object(remote, "accounts", return_value=[("Codex", None, home / ".codex")]), mock.patch.object(remote, "linux_processes", return_value=([process], {})), mock.patch.object(remote, "tmux_targets", return_value=pane):
                collector = remote.Collector(home)
                self.assertTrue(all("tmux" not in file for file in collector.snapshot()["files"]))
                process["argv"] = ["codex", "resume", "s1"]
                files = collector.snapshot()["files"]
                self.assertEqual(next(file for file in files if file["filename"] == "s1.jsonl").get("tmux"), pane[123])
                self.assertNotIn("tmux", next(file for file in files if file["filename"] == "s2.jsonl"))

    def test_recent_worker_keeps_its_older_parent_available(self):
        with tempfile.TemporaryDirectory() as directory:
            home = pathlib.Path(directory)
            project = home / ".claude/projects/project"
            worker = project / "parent/subagents/agent-worker.jsonl"
            worker.parent.mkdir(parents=True)
            parent = project / "parent.jsonl"
            value = json.dumps({"type": "user", "sessionId": "parent", "cwd": "/project", "message": {"content": SECRET}}) + "\n"
            parent.write_text(value)
            worker.write_text(value)
            os.utime(parent, (0, 0))
            with mock.patch.object(remote.Collector, "refresh_providers"), mock.patch.object(remote, "accounts", return_value=[("Claude", None, home / ".claude")]), mock.patch.object(remote, "linux_processes", return_value=([], {})), mock.patch.object(remote, "tmux_targets", return_value={}):
                snapshot = remote.Collector(home).snapshot()
                self.assertEqual({file["filename"] for file in snapshot["files"]}, {"parent.jsonl", "agent-worker.jsonl"})
                self.assertNotIn(SECRET, remote.compact(snapshot))


if __name__ == "__main__":
    unittest.main()
