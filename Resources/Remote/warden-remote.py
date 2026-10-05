#!/usr/bin/env python3
"""Read-only Linux telemetry, streamed over the user's SSH connection.

Only allowlisted metadata leaves this process. Never send message text, tool
arguments/results, environment variables, credentials, or complete log lines.
No packages, hooks, or configuration changes are needed on the remote host.
"""
import json
import os
import pathlib
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

INTERVAL = 8
FRAME_LIMIT = 2 * 1024 * 1024
QUESTION = "Question awaiting your answer?"
ERRORS = {"other", "rate_limit", "rate_limit_error", "api_error", "authentication_failed", "billing_error", "invalid_request",
          "usageLimitExceeded", "rateLimitExceeded", "contextWindowExceeded", "serverOverloaded", "responseStreamDisconnected", "network_error"}


def compact(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True)


def fields(value, names):
    """Copy scalar metadata only, with bounded strings."""
    if not isinstance(value, dict):
        return {}
    return {key: (item[:4096] if isinstance(item, str) else item)
            for key in names if isinstance((item := value.get(key)), (str, int, float, bool))}


def question(text):
    if not isinstance(text, str):
        return ""
    trimmed = text.rstrip(" \t\r\n*_`\"')»”")
    return QUESTION if trimmed.endswith(("?", "？")) and sum(trimmed[-700:].count(c) for c in "?？") <= 3 else ""


def rate_window(value, camel=False):
    return fields(value, ("usedPercent", "windowDurationMins", "resetsAt") if camel
                  else ("used_percent", "window_minutes", "resets_at"))


def codex_limits(value, camel=False):
    out = fields(value, ("limitId", "limitName", "planType") if camel else ("limit_id", "limit_name", "plan_type"))
    if isinstance(value, dict):
        for key in ("primary", "secondary"):
            if isinstance(value.get(key), dict):
                out[key] = rate_window(value[key], camel)
    return out


def sanitize_usage(provider, value):
    if not isinstance(value, dict):
        return {}
    if provider == "Codex":
        out = {}
        if isinstance(value.get("rateLimits"), dict):
            out["rateLimits"] = codex_limits(value["rateLimits"], True)
        if isinstance(value.get("rateLimitsByLimitId"), dict):
            out["rateLimitsByLimitId"] = {key[:128]: codex_limits(item, True)
                                          for key, item in list(value["rateLimitsByLimitId"].items())[:16]}
        return out
    limits = value.get("rate_limits", {})
    if not isinstance(limits, dict):
        return {}
    out = {key: fields(limits.get(key), ("utilization", "resets_at", "is_enabled"))
           for key in ("five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "extra_usage")
           if isinstance(limits.get(key), dict)}
    out["model_scoped"] = [fields(entry, ("display_name", "utilization", "resets_at"))
                           for entry in limits.get("model_scoped", [])[:16] if isinstance(entry, dict)]
    return {"rate_limits": out}


def sanitize_codex(value):
    kind, payload = value.get("type"), value.get("payload")
    if not isinstance(payload, dict):
        return None
    out = fields(value, ("timestamp", "type"))
    if kind == "session_meta":
        clean = fields(payload, ("id", "session_id", "cwd", "originator", "thread_source"))
        if isinstance(payload.get("source"), str):
            clean["source"] = payload["source"][:128]
        elif isinstance(payload.get("source"), dict):
            spawn = payload["source"].get("subagent", {}).get("thread_spawn", {})
            clean["source"] = {"subagent": {"thread_spawn": fields(spawn, ("parent_thread_id",))}}
    elif kind == "turn_context":
        clean = fields(payload, ("cwd", "model"))
    elif kind == "event_msg":
        event = payload.get("type")
        if event not in ("task_started", "task_complete", "turn_aborted", "token_count"):
            return None
        clean = fields(payload, ("type", "started_at"))
        if event == "task_complete":
            clean["last_agent_message"] = question(payload.get("last_agent_message"))
            if isinstance(payload.get("error"), dict):
                info = payload["error"].get("codex_error_info", "other")
                key = info if isinstance(info, str) else next(iter(info), "other") if isinstance(info, dict) else "other"
                clean["error"] = {"codex_error_info": key if key in ERRORS else "other"}
        if event == "token_count":
            info = payload.get("info") or {}
            clean["info"] = fields(info, ("model_context_window",))
            for key in ("last_token_usage", "total_token_usage"):
                clean["info"][key] = fields(info.get(key), ("input_tokens", "output_tokens", "cached_input_tokens", "total_tokens"))
            if isinstance(payload.get("rate_limits"), dict):
                clean["rate_limits"] = codex_limits(payload["rate_limits"])
    elif kind == "response_item":
        item = payload.get("type")
        clean = fields(payload, ("type", "role"))
        if item == "message" and payload.get("role") in ("user", "assistant"):
            text = "\n".join(block.get("text", "") for block in payload.get("content", []) if isinstance(block, dict) and isinstance(block.get("text"), str))
            clean["content"] = [{"type": "output_text", "text": question(text) if payload["role"] == "assistant" else ""}]
        elif item == "function_call" and payload.get("name", "").split(".")[-1] in ("request_user_input", "request_user_input_async"):
            clean.update(fields(payload, ("call_id",)))
            clean["name"] = payload["name"].split(".")[-1]
            clean["arguments"] = compact({"questions": [{"title": QUESTION}]})
        elif item == "function_call_output":
            clean.update(fields(payload, ("call_id",)))
        else:
            return None
    else:
        return None
    out["payload"] = clean
    return out


def sanitize_claude(value):
    kind = value.get("type")
    if kind not in ("user", "assistant", "system", "ai-title", "cost-state"):
        return None
    out = fields(value, ("type", "timestamp", "sessionId", "cwd", "entrypoint", "promptId", "isMeta", "interruptedMessageId"))
    if kind == "ai-title":
        out.update(fields(value, ("aiTitle",)))
    if kind == "system":
        out.update(fields(value, ("subtype", "retryAttempt", "maxRetries")))
        out["error"] = fields(value.get("error"), ("isNetworkDown",))
        if "continuing automatically" in str(value.get("content", "")):
            out["content"] = "continuing automatically"
    if kind not in ("user", "assistant"):
        return out
    message = value.get("message") or {}
    content = message.get("content", [])
    blocks = content if isinstance(content, list) else [{"type": "text", "text": str(content)}]
    text = "\n".join(block.get("text", "") for block in blocks if isinstance(block, dict) and isinstance(block.get("text"), str))
    clean = fields(message, ("model", "stop_reason"))
    if kind == "user":
        if text.startswith("[Request interrupted by user"):
            clean["content"] = "[Request interrupted by user]"
        elif text.startswith(("<command-name>", "<command-message>", "<local-command-")):
            clean["content"] = "<command-name>"
        else:
            clean["content"] = [{"type": "tool_result"}] if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in blocks) else ""
    else:
        clean["content"] = [{"type": "text", "text": question(text)}]
        for block in blocks:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tool = fields(block, ("type", "name"))
                if block.get("name") == "AskUserQuestion":
                    tool["input"] = {"questions": [{"question": QUESTION}]}
                clean["content"].append(tool)
        usage = message.get("usage") or {}
        clean["usage"] = fields(usage, ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
        clean["usage"]["cache_creation"] = fields(usage.get("cache_creation"), ("ephemeral_1h_input_tokens", "ephemeral_5m_input_tokens"))
        out.update(fields(value, ("isApiErrorMessage",)))
        if value.get("isApiErrorMessage"):
            out["error"] = value.get("error") if value.get("error") in ERRORS else "other"
        out["quotaLimits"] = fields(value.get("quotaLimits"), ("status", "resetsAt"))
    out["message"] = clean
    return out


def events(data, provider):
    sanitize = sanitize_codex if provider == "Codex" else sanitize_claude
    result = []
    for line in data.splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                clean = sanitize(value)
                if clean is not None:
                    result.append(clean)
        except (ValueError, TypeError, AttributeError):
            continue  # Partial, oversized, or unrelated records do not leave the host.
    return result


def read_file(path, provider, account, folder):
    try:
        stat = path.stat()
        with path.open("rb") as stream:
            head = stream.read(64 * 1024)
            width = 1024 * 1024 if provider == "Codex" else 512 * 1024
            stream.seek(max(0, stat.st_size - width))
            tail = stream.read(width)
            # A tool result or image can consume the whole tail. Widen once, still bounded.
            parsed = events(tail if stat.st_size <= width else tail.partition(b"\n")[2], provider)
            has_state = any(e.get("type") in ("user", "assistant") or e.get("payload", {}).get("type") in ("task_started", "task_complete", "token_count", "turn_aborted") for e in parsed)
            if not has_state and stat.st_size > width:
                stream.seek(max(0, stat.st_size - 8 * 1024 * 1024))
                tail = stream.read(8 * 1024 * 1024)
                parsed = events(tail if stat.st_size <= len(tail) else tail.partition(b"\n")[2], provider)
        first = events(head, provider)
        if not first and not parsed:
            return None
        # Keep the latest state, quota and counters, plus a turn start when a long tool run follows it.
        selected = parsed[-120:]
        context = next((event for event in reversed(parsed or first) if event.get("type") == "turn_context"), None)
        if context and context not in selected:
            selected.insert(0, context)
        started = next((event for event in reversed(parsed) if event.get("payload", {}).get("type") == "task_started"), None)
        if started and started not in selected:
            selected.insert(0, started)
        pending = set()
        for event in parsed:
            payload = event.get("payload", {})
            if payload.get("type") in ("task_started", "task_complete", "turn_aborted") or payload.get("role") == "user":
                pending.clear()
            if payload.get("type") == "function_call" and payload.get("name") == "request_user_input":
                pending.add(payload.get("call_id"))
            if payload.get("type") == "function_call_output":
                pending.discard(payload.get("call_id"))
        result = {"provider": provider, "filename": path.name, "account": account, "accountFolder": str(folder),
                  "modifiedAt": stat.st_mtime, "head": compact(first[0]) + "\n" if first else "",
                  "tail": "\n" + "\n".join(map(compact, selected)), "inputPending": bool(pending)}
        if provider == "Claude" and path.parent.name == "subagents":
            result["parentID"] = path.parent.parent.name
        return result
    except OSError:
        return None


def accounts(home):
    found = []
    for provider, base, variable in (("Claude", ".claude", "CLAUDE_CONFIG_DIR"), ("Codex", ".codex", "CODEX_HOME")):
        default = pathlib.Path(os.environ.get(variable) or home / base).expanduser()
        candidates = [default] + sorted(home.glob(base + "*"))
        for folder in candidates:
            if any(item[2] == folder for item in found):
                continue
            name = None if folder == default else folder.name.lstrip(".")[len(base) - 1:].lstrip("-_.") or folder.name
            found.append((provider, name, folder))
    return found


def codex_titles(folder):
    try:
        with (folder / "session_index.jsonl").open("rb") as stream:
            size = stream.seek(0, os.SEEK_END)
            stream.seek(max(0, size - 262144))
            data = stream.read(262144)
        titles = {}
        for line in (data if size <= len(data) else data.partition(b"\n")[2]).splitlines():
            try:
                value = json.loads(line)
                if isinstance(value.get("id"), str) and isinstance(value.get("thread_name"), str):
                    titles[value["id"]] = value["thread_name"][:200]
            except (ValueError, AttributeError):
                continue
        return titles
    except OSError:
        return {}


def linux_processes():
    result, parents = [], {}
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            if entry.stat().st_uid != os.getuid():
                continue
            stat = (entry / "stat").read_text()
            parents[int(entry.name)] = int(stat[stat.rfind(")") + 2:].split()[1])
            raw = (entry / "cmdline").open("rb").read(8192)
            argv = raw.decode("utf-8", "replace").strip("\0").split("\0")
            names = [os.path.basename(arg) for arg in argv[:3]]
            provider = "Codex" if "codex" in names or "codex.js" in names else "Claude" if "claude" in names or any("@anthropic-ai/claude-code" in arg for arg in argv[:2]) else None
            if not provider or (provider == "Codex" and any(arg in ("app-server", "sandbox", "--managed-daemon", "pid-update-loop") for arg in argv[1:])):
                continue
            if provider == "Claude" and ("agents" in argv[1:] or "--no-session-persistence" in argv):
                continue
            result.append({"pid": int(entry.name), "provider": provider, "cwd": os.readlink(entry / "cwd"), "argv": argv})
        except (OSError, ValueError, IndexError):
            continue
    return result, parents


def tmux_targets(processes, parents):
    targets = {}
    if not shutil.which("tmux"):
        return targets
    try:
        output = subprocess.run(["tmux", "list-panes", "-a", "-F", "#{pane_pid}\t#{session_id}\t#{window_id}\t#{pane_id}"],
                                capture_output=True, timeout=2).stdout.decode()
        panes = {}
        for line in output.splitlines():
            pid, session, window, pane = line.split("\t")
            panes[int(pid)] = {"session": session, "window": window, "pane": pane}
        for process in processes:
            pid = process["pid"]
            for _ in range(32):
                if pid in panes:
                    targets[process["pid"]] = panes[pid]
                    break
                pid = parents.get(pid, 0)
                if pid <= 1:
                    break
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return targets


def executable(name):
    for candidate in (pathlib.Path.home() / ".local/bin" / name, pathlib.Path.home() / ".npm-global/bin" / name,
                      pathlib.Path.home() / ".bun/bin" / name):
        if os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which(name)


def exchange(command, env, first, handler, timeout=8):
    """A prompt-free provider read. Bound output and always stop our own CLI process group."""
    with tempfile.TemporaryDirectory(prefix="warden-usage-") as cwd:
        task = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=env, cwd=cwd, start_new_session=True)
        try:
            task.stdin.write((compact(first) + "\n").encode())
            task.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(task.stdout, selectors.EVENT_READ)
                buffer, deadline, total = b"", time.monotonic() + timeout, 0
                while time.monotonic() < deadline and total <= FRAME_LIMIT:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        break
                    chunk = os.read(task.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    total += len(chunk)
                    buffer += chunk
                    while b"\n" in buffer:
                        line, _, buffer = buffer.partition(b"\n")
                        try:
                            response = json.loads(line)
                        except ValueError:
                            continue
                        done, messages = handler(response)
                        if done is not None:
                            return done
                        for message in messages:
                            task.stdin.write((compact(message) + "\n").encode())
                        task.stdin.flush()
        finally:
            if task.poll() is None:
                os.killpg(task.pid, signal.SIGTERM)
            try:
                task.wait(timeout=1)
            except subprocess.TimeoutExpired:
                os.killpg(task.pid, signal.SIGKILL)
                task.wait()
            task.stdin.close()
            task.stdout.close()
    return None


def provider_usage(provider, folder):
    cli = executable("codex" if provider == "Codex" else "claude")
    if not cli:
        return None
    env = dict(os.environ, **{("CODEX_HOME" if provider == "Codex" else "CLAUDE_CONFIG_DIR"): str(folder)})
    if provider == "Codex":
        def handle(message):
            if message.get("id") == 1:
                return None, [{"method": "initialized"}, {"id": 2, "method": "account/rateLimits/read", "params": {"excludeResetCreditDetails": True}}]
            return (message.get("result"), []) if message.get("id") == 2 else (None, [])
        result = exchange([cli, "app-server"], env, {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "warden", "title": "Warden", "version": "0.4"}}}, handle)
    else:
        def control(identifier, request):
            return {"type": "control_request", "request_id": identifier, "request": request}
        def handle(message):
            reply = message.get("response", {}) if message.get("type") == "control_response" else {}
            if reply.get("request_id") == "1":
                return None, [control("2", {"subtype": "get_usage", "skip_behaviors": True})]
            return (reply.get("response"), []) if reply.get("request_id") == "2" else (None, [])
        result = exchange([cli, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--safe-mode", "--no-session-persistence"], env, control("1", {"subtype": "initialize"}), handle)
    return sanitize_usage(provider, result) if result else None


class Collector:
    def __init__(self, home=None, usage_providers=None):
        self.home = pathlib.Path(home) if home else pathlib.Path.home()
        self.usage_providers = set(("Claude", "Codex") if usage_providers is None else usage_providers)
        self.cache = {}
        self.usage = {}
        self.views = {}
        self.lock = threading.Lock()
        self.next_usage = 0
        self.next_views = 0
        self.reading = False

    def refresh_providers(self, discovered, now):
        usage_due = now >= self.next_usage
        if self.reading or (not usage_due and now < self.next_views):
            return
        self.reading = True
        self.next_views = now + 30
        if usage_due:
            self.next_usage = now + 600
        def read():
            try:
                for provider, account, folder in discovered:
                    if not folder.is_dir():
                        continue
                    if provider == "Claude" and (cli := executable("claude")):
                        try:
                            env = dict(os.environ, CLAUDE_CONFIG_DIR=str(folder))
                            task = subprocess.Popen([cli, "agents", "--json"], env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                            try:
                                output, _ = task.communicate(timeout=3)
                            except subprocess.TimeoutExpired:
                                task.kill(); task.communicate(); output = b""
                            entries = json.loads(output) if len(output) < FRAME_LIMIT else []
                            if isinstance(entries, list):
                                safe = [fields(entry, ("sessionId", "id", "pid", "kind", "status", "waitingFor", "state", "name", "cwd")) for entry in entries[:84]]
                                with self.lock:
                                    self.views[str(folder)] = {"account": account, "observedAt": time.time(), "entries": compact(safe)}
                        except (OSError, ValueError):
                            pass
                    if usage_due and provider in self.usage_providers:
                        try:
                            result = provider_usage(provider, folder)
                            if result:
                                with self.lock:
                                    self.usage[str(folder)] = {"provider": provider, "account": account, "observedAt": time.time(), "result": compact(result)}
                        except (OSError, ValueError, BrokenPipeError):
                            pass
            finally:
                self.reading = False
        threading.Thread(target=read, daemon=True).start()

    def snapshot(self):
        now = time.time()
        discovered = accounts(self.home)
        self.refresh_providers(discovered, now)
        processes, parents = linux_processes()
        targets = tmux_targets(processes, parents)
        with self.lock:
            active_ids = {entry.get("sessionId") for view in self.views.values() if now - view["observedAt"] < 45
                          for entry in json.loads(view["entries"]) if entry.get("status") in ("busy", "waiting") or entry.get("state") in ("working", "blocked")}
        active_ids.update(arg for process in processes for arg in process["argv"] if len(arg) == 36 and arg.count("-") == 4)
        files, paths = [], set()
        for provider, account, folder in discovered:
            titles = codex_titles(folder) if provider == "Codex" else {}
            root = folder / ("sessions" if provider == "Codex" else "projects")
            candidates = []
            visited = 0
            for directory, directories, names in os.walk(root):
                directories.sort(reverse=True)
                for name in names:
                    visited += 1
                    if visited > 20000:
                        break
                    if not name.endswith(".jsonl"):
                        continue
                    path = pathlib.Path(directory) / name
                    try:
                        stat = path.stat()
                    except OSError:
                        continue
                    cached = self.cache.get(str(path))
                    metadata = json.loads(cached[2]["head"]) if cached and cached[2] and cached[2]["head"].strip() else {}
                    payload = metadata.get("payload", {}) if provider == "Codex" else metadata
                    still_running = any(p["provider"] == provider and p["cwd"] == payload.get("cwd") for p in processes)
                    if stat.st_mtime >= now - 6 * 3600 or still_running or any(identity and identity in path.stem for identity in active_ids):
                        candidates.append((stat.st_mtime, path, stat.st_size))
                        if provider == "Claude" and path.parent.name == "subagents" and stat.st_mtime >= now - 1800:
                            parent = path.parent.parent.parent / (path.parent.parent.name + ".jsonl")
                            try:
                                parent_stat = parent.stat()
                                candidates.append((parent_stat.st_mtime, parent, parent_stat.st_size))
                            except OSError:
                                pass
                if visited > 20000:
                    break
            unique = {item[1]: item for item in candidates}.values()
            primary = sorted((item for item in unique if item[1].parent.name != "subagents"), reverse=True)[:56 if provider == "Codex" else 28]
            workers = sorted((item for item in unique if item[1].parent.name == "subagents"), reverse=True)[:28]
            for modified, path, size in primary + workers:
                key = str(path)
                paths.add(key)
                old = self.cache.get(key)
                if not old or old[:2] != (modified, size):
                    self.cache[key] = (modified, size, read_file(path, provider, account, folder))
                if self.cache[key][2]:
                    file = dict(self.cache[key][2])
                    if provider == "Codex":
                        metadata = json.loads(file["head"]) if file["head"].strip() else {}
                        identity = metadata.get("payload", {}).get("id")
                        if identity in titles:
                            file["title"] = titles[identity]
                    files.append(file)
        self.cache = {key: value for key, value in self.cache.items() if key in paths}
        # Claim a process once. Attach navigation only with an exact id or one live process in a folder.
        claimed = set()
        pairs, folder_counts = [], {}
        for file in files:
            metadata = json.loads(file["head"]) if file["head"].strip() else {}
            payload = metadata.get("payload", {}) if file["provider"] == "Codex" else metadata
            if file.get("parentID") or isinstance(payload.get("source"), dict) or payload.get("thread_source") in ("subagent", "guardian_review"):
                continue
            identity = payload.get("id") or payload.get("session_id") or payload.get("sessionId") or pathlib.Path(file["filename"]).stem
            pairs.append((file, payload, identity))
            key = (file["provider"], payload.get("cwd"))
            folder_counts[key] = folder_counts.get(key, 0) + 1
        with self.lock:
            agent_pids = {}
            for view in self.views.values():
                if now - view["observedAt"] < 45:
                    for entry in json.loads(view["entries"]):
                        if entry.get("sessionId") and entry.get("pid"):
                            agent_pids[entry["sessionId"]] = entry["pid"]
        reserved = {process["pid"] for process in processes if any(file["provider"] == process["provider"] and
            (identity in process["argv"] or process["pid"] == agent_pids.get(identity)) for file, _, identity in pairs)}
        for file, payload, identity in sorted(pairs, key=lambda pair: pair[0]["modifiedAt"], reverse=True):
            cwd = payload.get("cwd")
            matches = [p for p in processes if p["provider"] == file["provider"] and p["pid"] not in claimed]
            exact = [p for p in matches if identity in p["argv"] or p["pid"] == agent_pids.get(identity)]
            same_folder = [p for p in matches if p["cwd"] == cwd and p["pid"] not in reserved]
            match = exact[0] if len(exact) == 1 else same_folder[0] if len(same_folder) == 1 else None
            if match:
                claimed.add(match["pid"])
                file["pid"] = match["pid"]
                # A cwd fallback helps liveness but cannot pick a pane among several recent conversations.
                if match["pid"] in targets and (len(exact) == 1 or folder_counts.get((file["provider"], cwd)) == 1):
                    file["tmux"] = targets[match["pid"]]
        with self.lock:
            usage, views = list(self.usage.values()), list(self.views.values())
        result = {"version": 1, "observedAt": now, "files": sorted(files, key=lambda f: (not bool(f.get("parentID")), f["modifiedAt"]), reverse=True)[:84],
                  "processes": [fields(p, ("pid", "provider", "cwd")) for p in processes[:256]], "usage": usage, "agentViews": views}
        while result["files"] and len(compact(result).encode()) > FRAME_LIMIT:
            result["files"].pop()
        return result


def main():
    if sys.platform != "linux" or not pathlib.Path("/proc").is_dir():
        sys.stderr.write("Warden remote monitoring requires Linux and Python 3.8 or newer.\n")
        return 1
    collector = Collector(usage_providers=globals().get("WARDEN_USAGE_PROVIDERS"))
    try:
        while True:
            print(compact(collector.snapshot()), flush=True)
            time.sleep(INTERVAL)
    except (BrokenPipeError, KeyboardInterrupt):
        return 0


if __name__ == "__main__":
    sys.exit(main())
