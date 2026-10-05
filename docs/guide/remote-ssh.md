# Remote agents over SSH

Keep Warden in your Mac's menu bar while Claude Code or Codex runs on Ubuntu or another Linux server. Warden opens its own SSH connection, so closing your interactive SSH terminal does not stop monitoring. Agents must themselves survive that terminal closing, for example inside tmux.

## Connect a host

1. Connect to the server in Terminal with your usual `ssh cluster` or `ssh user@server` command. Accept its host key and make sure key authentication works through your SSH agent or macOS Keychain.
2. Confirm that `python3 --version` on the server reports Python 3.8 or newer.
3. In **Warden Settings → SSH**, enter the same SSH destination and an optional display name, then choose **Add Host**.
4. Start Claude Code or Codex on that host. Its sessions appear beside your local sessions, labeled with the host. Quota rows include both the host and provider.

Warden uses the existing OpenSSH configuration, including aliases, identity selection and `ProxyJump`. It does not edit `~/.ssh/config`, accept unknown host keys, read private keys, or ask for passwords. Monitoring uses noninteractive authentication. If it fails, **Open SSH** lets you check the same destination in Terminal; **Retry** restarts monitoring.

For a cluster, configure the destination where the agents actually run. Monitoring a login node cannot see agents running on a separate compute node. Use an existing alias that reaches the compute node through the login node. Scheduler allocation and job submission remain outside Warden.

## Return to the right terminal

Run an agent inside tmux when you want it to survive SSH disconnects:

```sh
ssh cluster
tmux new -s coding
claude
# Or: codex
```

Detach with **Ctrl-B, D**. Clicking that session in Warden opens Terminal and attaches another client to its existing tmux session, selecting the identified window and pane. It does not launch another agent or resume a duplicate conversation. Normal tmux permissions still apply.

Without tmux, Warden can focus a uniquely matching SSH tab in Terminal or iTerm. Several SSH tabs to the same destination are ambiguous; Warden asks you to return to the existing terminal yourself. Sessions in screen and remote editor terminals are monitored through their logs, but exact terminal selection currently targets tmux and Terminal/iTerm SSH tabs.

## What is observed

The bundled Python collector runs over SSH stdin, with no installation, extra Python packages, or provider hook changes on the server. It reads bounded portions of recent Claude and Codex logs and current-user Linux process metadata. Claude's supported `agents --json` view adds live waiting states when available. Provider usage reads use the installed remote CLI without sending a model prompt.

Only allowlisted session metadata crosses SSH: IDs, titles, project paths, model names, timestamps, state signals, tmux identifiers, token counters and quota readings. Prompt text, model replies, tool arguments/results, images and credentials are excluded. Questions become a generic **Question awaiting your answer** indicator; answer in the original remote terminal. Remote approval buttons and phone answers are not supported.

Claude context remains unavailable without an exact provider reading. Codex context is estimated from logged input counts and capacity. A final question is detected by the same punctuation heuristic as local sessions. Codex permission waits that do not appear in its logs remain unavailable; a quiet running process alone cannot establish whether it is blocked on approval.

Provider quotas are polled at most every ten minutes and kept distinct by host/account. The account usage switches in **Settings → General** also control remote CLI usage reads; states and counters from logs remain available when those reads are off. Two hosts signed into one account can show the same shared quota; these are separate observations, not extra quota or values to add together. Remote session counters are not backfilled into the Mac's token history or quota attribution. Activity spans include a host-qualified project path. train-guard controls continue to govern jobs on the Mac.

## Disconnects and removal

Warden reconnects automatically after an SSH failure. While disconnected, retained sessions show an unknown state, not a completed turn. Last quota readings keep their original observation time. Missing heartbeats expire after 45 seconds.

Monitoring pauses while the Mac sleeps or Warden is closed. Keeping an SSH terminal open is unnecessary while Warden runs, but the Mac still needs network access to the server. **Keep Awake** can prevent idle sleep during observed work; an unresolved disconnect is not treated as all work being done.

Turn a host off to pause monitoring, or choose **Remove** to forget it. Both close only Warden's SSH connection. They do not stop remote agents or remove their logs. Host configuration is stored locally in `remote-hosts.json`; it contains destinations and display names, without credentials.
