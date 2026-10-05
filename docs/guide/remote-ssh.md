# Remote agents over SSH

Keep Warden in your Mac's menu bar while Claude Code or Codex runs on Ubuntu or another Linux server. Warden opens its own SSH connection, so closing your interactive SSH terminal does not stop monitoring. Agents must themselves survive that terminal closing, for example inside tmux.

## Connect a host

1. Connect to the server in Terminal with your usual `ssh cluster` or `ssh user@server` command and accept its host key. Use your usual SSH authentication, whether a key, password, security key, or phone approval.
2. Confirm that `python3 --version` on the server reports Python 3.8 or newer.
3. In **Warden Settings → SSH**, enter the same SSH destination and an optional display name, then choose **Add Host**.
4. For interactive authentication, choose **Authenticate in Terminal** on the saved host and finish sign-in there. Warden resumes monitoring when the approved shared connection is ready.
5. Start Claude Code or Codex on that host. Its sessions appear beside your local sessions, labeled with the host. Quota rows include both the host and provider.

Warden uses the existing OpenSSH configuration, including aliases, identity selection and `ProxyJump`. It does not edit `~/.ssh/config`, accept unknown host keys automatically, read private keys, or capture passwords and authentication codes. Monitoring stays noninteractive. **Retry** restarts monitoring.

For a cluster, configure the destination where the agents actually run. Monitoring a login node cannot see agents running on a separate compute node. Use an existing alias that reaches the compute node through the login node. Scheduler allocation and job submission remain outside Warden.

## Passwords and phone approval

**Authenticate in Terminal** runs ordinary OpenSSH and creates a shared connection for this saved host. Approve Duo, Microsoft Authenticator or another MFA system manually, as your server normally requires. Warden then opens its monitoring channel over that approved connection. It can also reuse a shared connection already configured with `ControlPath` in your SSH configuration.

The authentication method stays managed by OpenSSH and the server. Warden neither stores authentication secrets nor interacts with your phone. Its private control socket is under `Application Support/Warden/ssh`, in a directory restricted to your Mac account. The shared connection can remain in the background after its terminal closes; it expires after five idle minutes without client channels. This is OpenSSH connection sharing, not an extension of the server's authorization period.

If the server closes the connection or requires renewed approval, Warden shows **Authentication required**, retains the last observations as unavailable, and stops automatic authentication attempts. Choose **Authenticate in Terminal** again and approve the login yourself. If you sign in separately using your own configured shared connection, choose **Retry** afterward.

With SSH monitoring, a cluster that forcibly closes all approved connections after twelve hours requires another login. Jobs and agents in tmux or screen can continue independently; Warden reads their current state after reconnecting. Older logs belonging to a still-running process remain eligible within the collector's bounded file limit. The HTTPS mode below provides a separate route for monitoring.

## Follow after SSH expires

For long runs on a cluster with expiring SSH access, Warden can start a **temporary collector in memory** during one authorized login. After that, the collector sends end-to-end encrypted states to a HTTPS relay independently of SSH. Closing a terminal or refusing a new SSH login does not stop this route.

No Warden code, package, provider hook, SSH key or service is installed on the remote host. The collector runs under your own Linux account, using Python 3.8+, its existing system OpenSSL library and HTTPS certificate trust store. Its source and Warden pairing material arrive over SSH stdin and stay in the process's memory. Existing provider CLIs continue to manage their own usage-read runtime files. A server reboot or a cluster policy that terminates detached processes ends the collector; this mode does not override either policy.

1. Build 11 and later include the relay at `https://warden-agent-relay.darwishriad0.workers.dev`. You can also [host your own relay](relays.md#cloudflare-agent-relay). No extra server or software is needed on the cluster. The included relay uses shared free-plan quotas; if they are exhausted, monitoring is unavailable until service returns.
2. Add the host in **Settings → SSH**, then choose **Follow after SSH expires…**.
3. Keep the included relay origin, or enter your own, and choose **Start in Terminal**. Complete the ordinary SSH and phone approval once. The command sends the private bootstrap file from this Mac over stdin; it never copies a script to Linux.
4. When the feed connects, the host shows **HTTPS feed · SSH can be disconnected**. Start your agents in tmux or screen so they survive logout too.

The relay receives only opaque AES-256-GCM packets. The Mac holds the decryption key, interprets the same redacted metadata as SSH mode, and generates its usual alerts. The relay stores routing-token hashes and liveness configuration, without the key or conversation history. Cloudflare also replaces one stored encrypted packet per host to survive runtime hibernation; packets older than ninety seconds are deleted on the next feed read. The self-hosted Node relay keeps its packet in memory. A fresh Mac connection challenge, pause or removal clears the packet. The challenge and increasing packet counter prevent retained ciphertext from presenting an old state as a new heartbeat.

Telemetry is published and read every twenty seconds. A missed feed becomes unavailable after ninety seconds, without producing a completion alert. Keep Warden open and the Mac awake for alerts. The collector can remain active while the Mac sleeps; it stops if the Mac has not returned for seven days, or it cannot reach the relay for twenty-four hours. Pausing or removing the host stops its collector at the next successful request without stopping agents. To resume a paused collector, use **Start Temporary Collector…** again.

This avoids renewed SSH approval **for monitoring**. Opening the agent's terminal or responding to it still requires whatever SSH authentication the cluster normally enforces. The server must permit outbound HTTPS to the chosen relay and allow the detached process to survive logout. If all permitted network routes and event sources are unavailable, Warden cannot observe live events remotely.

## Return to the right terminal

Run an agent inside tmux when you want it to survive SSH disconnects:

```sh
ssh cluster
tmux new -s coding
claude
# Or: codex
```

Detach with **Ctrl-B, D**. Clicking that session in Warden opens Terminal and attaches another client to its existing tmux session, selecting the identified window and pane. It does not launch another agent or resume a duplicate conversation. Normal tmux permissions still apply.

For **GNU screen**, run `screen -S coding` before starting the agent. Detach with **Ctrl-A, D**. Clicking an identified screen session reattaches to that existing session and opens its window list, where you select the agent's window. Warden does not create another screen session or detach another client.

Without tmux or screen, Warden can focus a uniquely matching SSH tab in Terminal or iTerm. Several SSH tabs to the same destination are ambiguous; Warden asks you to return to the existing terminal yourself. Remote editor sessions are monitored through their logs; exact remote editor terminal selection remains unavailable.

## What is observed

The bundled Python collector runs over SSH stdin, with no installation, extra Python packages, or provider hook changes on the server. It reads bounded portions of recent Claude and Codex logs and current-user Linux process metadata. Claude's supported `agents --json` view adds live waiting states when available. Provider usage reads use the installed remote CLI without sending a model prompt.

Only allowlisted session metadata crosses SSH: IDs, titles, project paths, model names, timestamps, state signals, tmux identifiers, token counters and quota readings. Prompt text, model replies, tool arguments/results, images and credentials are excluded. Questions become a generic **Question awaiting your answer** indicator; answer in the original remote terminal. Remote approval buttons and phone answers are not supported.

Claude context remains unavailable without an exact provider reading. Codex context is estimated from logged input counts and capacity. A final question is detected by the same punctuation heuristic as local sessions. Codex permission waits that do not appear in its logs remain unavailable; a quiet running process alone cannot establish whether it is blocked on approval.

Provider quotas are polled at most every ten minutes and kept distinct by host/account. The account usage switches in **Settings → General** also control remote CLI usage reads; states and counters from logs remain available when those reads are off. Two hosts signed into one account can show the same shared quota; these are separate observations, not extra quota or values to add together. Remote session counters are not backfilled into the Mac's token history or quota attribution. Activity spans include a host-qualified project path. train-guard controls continue to govern jobs on the Mac.

## Disconnects and removal

Warden reconnects automatically after an SSH failure. While disconnected, retained sessions show an unknown state, not a completed turn. Last quota readings keep their original observation time. Missing heartbeats expire after 45 seconds.

Mac observations and alerts pause while the Mac sleeps or Warden is closed. Keeping an SSH terminal open is unnecessary while Warden runs, but the Mac still needs network access to the server or the configured relay. **Keep Awake** can prevent idle sleep during observed work; an unresolved disconnect is not treated as all work being done.

Turn a host off to pause monitoring, or choose **Remove** to forget it. In SSH mode, both close Warden's monitoring connection. In HTTPS mode, both request that the temporary collector stop when it next reaches the relay. They do not stop remote agents or remove their logs. Host configuration is stored locally in the private `remote-hosts.json`; it contains destinations and display names, plus generated Warden pairing material for HTTPS feeds. It contains no SSH or provider credentials.
