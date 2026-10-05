#!/usr/bin/env python3
"""Exercise the production collector and Swift transport against an isolated Ubuntu SSH server.

Run under train-guard. Requires Docker. --keep leaves the test host available
for native WardenPreview QA; --cleanup removes only this script's test host.
No owner SSH configuration, keys, or known-hosts files are read or modified.
"""
import argparse
import json
import os
import pathlib
import selectors
import shlex
import socket
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
QA = ROOT / "build/remote-ssh-qa"
DOCKER = "/usr/local/bin/docker"
CODEX_ID = "97d66436-6ead-4aab-8888-097d81e4de11"
CLAUDE_ID = "5aa6c736-08b1-4f57-9999-997d81e4de22"
SECRET = "PRIVATE_REMOTE_PROMPT_AND_TOOL_OUTPUT_8c39"


def run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


FAKE_CLI = r'''#!/usr/bin/python3
import json, os, pathlib, sys, time
provider = pathlib.Path(sys.argv[0]).name
def send(value):
    print(json.dumps(value), flush=True)
if provider == "codex" and "app-server" in sys.argv:
    for line in sys.stdin:
        value = json.loads(line)
        if value.get("id") == 1: send({"id": 1, "result": {}})
        if value.get("id") == 2: send({"id": 2, "result": {"rateLimits": {"primary": {"usedPercent": 24, "windowDurationMins": 300, "resetsAt": time.time()+7200}, "secret": "PRIVATE_REMOTE_PROMPT_AND_TOOL_OUTPUT_8c39"}}})
elif provider == "claude" and "agents" in sys.argv:
    send([])
elif provider == "claude" and "--no-session-persistence" in sys.argv:
    for line in sys.stdin:
        value = json.loads(line)
        identifier = value.get("request_id")
        reply = {"rate_limits": {"five_hour": {"utilization": 35, "resets_at": time.time()+7200}}, "email": "PRIVATE_REMOTE_PROMPT_AND_TOOL_OUTPUT_8c39"} if identifier == "2" else {}
        send({"type": "control_response", "response": {"request_id": identifier, "response": reply}})
else:
    while True: time.sleep(1)
'''


def prepare():
    QA.mkdir(parents=True, exist_ok=True)
    context = QA / "context"
    context.mkdir(exist_ok=True)
    (context / "fake-cli").write_text(FAKE_CLI)
    (context / "Dockerfile").write_text("""FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server python3 tmux && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /run/sshd /root/.ssh /root/.local/bin /project && chmod 700 /root/.ssh
COPY fake-cli /root/.local/bin/codex
RUN chmod +x /root/.local/bin/codex && cp /root/.local/bin/codex /root/.local/bin/claude && ssh-keygen -A
CMD ["/usr/sbin/sshd", "-D", "-e", "-o", "PermitRootLogin=prohibit-password", "-o", "PasswordAuthentication=no"]
""")
    print("Building isolated Ubuntu SSH fixture", flush=True)
    run([DOCKER, "build", "-t", "warden-ssh-qa:local", str(context)])
    key = QA / "test-key"
    if not key.exists():
        run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)])
    container = "warden-ssh-qa-" + uuid.uuid4().hex[:8]
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = str(reservation.getsockname()[1])
    run([DOCKER, "run", "-d", "--name", container, "-p", f"127.0.0.1:{port}:22", "warden-ssh-qa:local"], stdout=subprocess.DEVNULL)
    run([DOCKER, "cp", str(key.with_suffix(".pub")), container + ":/root/.ssh/authorized_keys"])
    run([DOCKER, "exec", container, "chown", "root:root", "/root/.ssh/authorized_keys"])
    run([DOCKER, "exec", container, "chmod", "600", "/root/.ssh/authorized_keys"])
    port = run([DOCKER, "inspect", "--format", '{{(index (index .NetworkSettings.Ports "22/tcp") 0).HostPort}}', container], capture_output=True, text=True).stdout.strip()
    host_key = run([DOCKER, "exec", container, "cat", "/etc/ssh/ssh_host_ed25519_key.pub"], capture_output=True, text=True).stdout.strip()
    (QA / "known-hosts").write_text("[127.0.0.1]:" + port + " " + host_key + "\n")
    config = QA / "ssh-config"
    config.write_text(f"Host warden-qa\n  HostName 127.0.0.1\n  Port {port}\n  User root\n  IdentityFile {key}\n  IdentitiesOnly yes\n  UserKnownHostsFile {QA / 'known-hosts'}\n  StrictHostKeyChecking yes\n")
    env = {"WARDEN_SSH_TEST_CONFIG": str(config), "WARDEN_SSH_TEST_CONTAINER": container}
    (QA / "environment.json").write_text(json.dumps(env, indent=2) + "\n")
    fixture = f'''import pathlib,json,time
now=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())
root=pathlib.Path("/root")
codex=root/".codex/sessions/2026/10/05/{CODEX_ID}.jsonl"
claude=root/".claude/projects/project/{CLAUDE_ID}.jsonl"
for path in (codex,claude):path.parent.mkdir(parents=True,exist_ok=True)
entries=[{{"type":"session_meta","payload":{{"id":"{CODEX_ID}","cwd":"/project","originator":"codex-tui"}}}},{{"timestamp":now,"type":"event_msg","payload":{{"type":"task_started"}}}},{{"type":"response_item","payload":{{"type":"function_call","name":"request_user_input","call_id":"q1","arguments":"{SECRET}"}}}}]
codex.write_text("\\n".join(map(json.dumps,entries))+"\\n")
entries=[{{"timestamp":now,"type":"user","sessionId":"{CLAUDE_ID}","cwd":"/project","message":{{"content":"{SECRET}"}}}},{{"timestamp":now,"type":"assistant","sessionId":"{CLAUDE_ID}","cwd":"/project","message":{{"model":"claude-sonnet-4-5","stop_reason":"tool_use","usage":{{"input_tokens":4500}},"content":[{{"type":"tool_use","name":"Bash","input":{{"command":"{SECRET}"}}}}]}}}}]
claude.write_text("\\n".join(map(json.dumps,entries))+"\\n")
'''
    run([DOCKER, "exec", "-i", container, "python3", "-"], input=fixture, text=True)
    start_agents(container)
    return env


def start_agents(container):
    run([DOCKER, "exec", container, "tmux", "new-session", "-d", "-s", "agents", "-c", "/project", f"/root/.local/bin/codex {CODEX_ID}"])
    run([DOCKER, "exec", container, "tmux", "split-window", "-h", "-t", "agents", "-c", "/project", f"/root/.local/bin/claude {CLAUDE_ID}"])


def verify(env):
    ssh = ["/usr/bin/ssh", "-F", env["WARDEN_SSH_TEST_CONFIG"], "-o", "BatchMode=yes"]
    monitor = subprocess.Popen(ssh + ["-T", "warden-qa", "python3 -u -"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    monitor.stdin.write((ROOT / "Resources/Remote/warden-remote.py").read_bytes())
    monitor.stdin.close()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(monitor.stdout, selectors.EVENT_READ)
            def frame():
                assert selector.select(20), "No SSH heartbeat"
                line = monitor.stdout.readline()
                assert line, "SSH collector exited before its heartbeat: " + monitor.stderr.read(4096).decode()
                assert SECRET.encode() not in line, "Private content escaped the collector"
                value = json.loads(line)
                assert len(line) < 2 * 1024 * 1024
                return value
            first = frame()
            assert {file["provider"] for file in first["files"]} == {"Claude", "Codex"}
            assert all("tmux" in file for file in first["files"])
            client = subprocess.Popen(ssh + ["-tt", "warden-qa", "TERM=xterm tmux attach-session -t agents"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(1)
            client.terminate(); client.wait(timeout=5)
            second = frame()
            assert second["observedAt"] > first["observedAt"]
            assert len(second["processes"]) == 2
            assert {value["provider"] for value in second["usage"]} == {"Claude", "Codex"}
            (QA / "redacted-snapshot.json").write_text(json.dumps(second, indent=2) + "\n")
            print("SSH snapshots, quota reads, tmux mapping and closed-client independence passed", flush=True)
    finally:
        monitor.terminate(); monitor.wait(timeout=5)


def cleanup(env):
    run([DOCKER, "rm", "-f", env["WARDEN_SSH_TEST_CONTAINER"]], stdout=subprocess.DEVNULL)
    for name in ("test-key", "test-key.pub", "known-hosts", "ssh-config", "environment.json"):
        (QA / name).unlink(missing_ok=True)


def verify_navigation(env):
    target = json.loads((QA / "navigation-command.json").read_text())
    args = shlex.split(target["command"])
    args[1:1] = ["-F", env["WARDEN_SSH_TEST_CONFIG"]]
    args[args.index("-t")] = "-tt"  # The fixture has pipes; Terminal supplies a TTY in normal use.
    client = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=dict(os.environ, TERM="xterm"))
    try:
        time.sleep(1)
        pane = run([DOCKER, "exec", env["WARDEN_SSH_TEST_CONTAINER"], "tmux", "display-message", "-p", "-t", "agents", "#{pane_id}"], capture_output=True, text=True).stdout.strip()
        assert pane == target["pane"], "The production navigation command selected the wrong tmux pane"
        print("Production tmux navigation selected the exact pane", flush=True)
    finally:
        client.terminate(); client.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("--prepare", action="store_true", help="Prepare the host for a separate Swift/native test run")
    parser.add_argument("--reuse", action="store_true", help="Use the fixture left by --keep")
    args = parser.parse_args()
    if args.cleanup:
        cleanup(json.loads((QA / "environment.json").read_text()))
        return
    env = json.loads((QA / "environment.json").read_text()) if args.reuse else prepare()
    try:
        verify(env)
        if not args.prepare:
            env["WARDEN_SSH_TEST_COMMAND"] = str(QA / "navigation-command.json")
            run(["swift", "test", "--filter", "RemoteConnectionTests/testLinuxSSH"], cwd=ROOT, env=dict(os.environ, **env))
            verify_navigation(env)
    finally:
        if not args.keep:
            cleanup(env)


if __name__ == "__main__":
    main()
