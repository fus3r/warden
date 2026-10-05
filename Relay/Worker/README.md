# Agent relay on Cloudflare Workers

This service carries encrypted observations from a temporary Linux collector to Warden on the Mac, independently of SSH. Nothing is installed on the monitored host. The original Node relay in `Relay/` supports the same API for self-hosting.

For setup, use the official [relay hosting guide](https://warden.readthedocs.io/en/latest/guide/relays/#cloudflare-agent-relay).

Warden beta 11 includes `https://warden-agent-relay.darwishriad0.workers.dev` as its default agent relay. This deployment uses the Workers Free plan and shared account quotas. A custom relay origin can be selected per host.

The SQLite-backed Durable Object stores routing-token hashes, a Mac connection challenge, provider-read preferences and liveness times. It never receives the encryption key. It also replaces one opaque encrypted packet per host so Cloudflare hibernation cannot lose a publication between Mac polls. Packets older than ninety seconds are deleted on the next feed read; a fresh Mac connection challenge, pause or removal deletes that host's packet immediately. There is no packet history. Mac interpretation and alerts stay local. Access logs and application observability are disabled in the supplied configuration. Cloudflare still handles network routing and can observe traffic timing and packet sizes.

## Free-plan fit

Cloudflare currently offers [100,000 Worker requests per day](https://developers.cloudflare.com/workers/platform/limits/) and [SQLite Durable Objects on the free plan](https://developers.cloudflare.com/durable-objects/platform/pricing/). It is not a student credit or a time-limited trial. Free limits can change, and exceeding them stops operations until the next reset; there is no claim of guaranteed availability.

With one upload and one read every twenty seconds, one continuously connected host uses approximately **8,640 requests per day**, excluding setup, retries and health checks. Ten hosts would use approximately 86,400 requests daily. These are arithmetic estimates, not a production capacity benchmark. The request quota is shared with other Workers on the same account. CPU and Durable Object limits also apply. Do not use Workers KV for the packet stream: its free write limit is much smaller.

The same relay supports multiple agent sessions on each host; it does not make a separate request for each session. Each upload replaces the latest ciphertext in SQLite. Packet size determines whether it uses one or two storage rows. Pairing changes and liveness checkpoints also write storage; these must fit the Durable Object free storage-operation limits.

## Deploy

Use a Cloudflare account on the **Workers Free** plan. No paid subscription, domain, card or DNS change is required for the generated `workers.dev` origin.

```sh
cd Relay/Worker
npm ci --ignore-scripts
npx wrangler login
npm run deploy
curl --fail https://YOUR-WORKER.workers.dev/health
```

The expected health reply is `{"ok":true,"service":"warden-agent-relay"}`. Set that HTTPS origin in Warden's host setup. A publisher can supply it as the default with `WARDEN_AGENT_RELAY_URL=https://YOUR-WORKER.workers.dev ./Scripts/build-app.sh universal`.

This Worker implements the agent feed API only. It does not enable the phone browser or phone push service. Remove the Worker and its Durable Object namespace from Cloudflare when retiring the service; a code deletion alone does not remove stored routing hashes.

## Local verification

```sh
cd Relay/Worker
npm ci --ignore-scripts
npm run dev
# In another terminal, from the repository root:
WARDEN_FEED_RELAY_URL=http://127.0.0.1:8788 npm --prefix Relay test
train-guard run --name warden-feed-qa -- python3 Scripts/verify-remote-ssh.py --feed
```

The Linux test uses a disposable Docker SSH server, closes its SSH sessions, revokes its test key, and checks that a completion still reaches the Mac over this Worker. It also checks replayed-packet liveness, unavailable states, reconnection and collector removal. Release verification also passed these checks through the deployed public Worker, using normal TLS certificate verification. The collector identifies itself with a Warden User-Agent; the default Python identifier was rejected by Cloudflare with HTTP 403/error 1010 during verification. A particular cluster's logout or network policy and a physical phone approval have not been tested.

To exercise the public relay protocol with disposable pairings:

```sh
WARDEN_FEED_RELAY_URL=https://warden-agent-relay.darwishriad0.workers.dev npm --prefix Relay test
```

## Alternatives

- **Self-hosted computer:** run `Relay/` behind a stable HTTPS endpoint. It must stay on, avoid sleep, and keep network access. A named tunnel can expose it without an inbound router port. A temporary tunnel is unsuitable as the permanent relay address.
- **Heroku Student:** the [GitHub Student Developer Pack](https://education.github.com/pack) currently lists $13 monthly credit for 24 months. Eligibility and service costs determine what that covers; it is a temporary credit, not a permanent free hosting tier.
- **Azure for Students:** [Microsoft](https://azure.microsoft.com/en-us/free/students/) currently offers $100 credit usable within twelve months, without a card. Eligible new accounts also have limited free services. It requires more infrastructure setup for this small relay.

No installation or hosting change on the monitored cluster is needed for any of these choices. Its existing Python/OpenSSL runtime, permitted outbound HTTPS and permission for a detached process remain necessary.
