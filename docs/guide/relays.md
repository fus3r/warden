# Relay hosting

Warden beta 11 and later include an encrypted agent relay for [following Linux agents after SSH expires](remote-ssh.md#follow-after-ssh-expires). Keep the included origin in host setup to use it. Shared free-plan quotas apply.

Hosting your own relay is optional. The Cloudflare Worker carries agent observations. The Node relay carries agent observations and can also provide [phone access](phone.md#optional-self-hosted-relay). The public Mac beta offers local-network phone access; its included agent relay does not provide a phone page or phone notifications.

## Cloudflare agent relay

Use a Cloudflare account on the **Workers Free** plan. A personal server, domain, card or paid subscription is unnecessary for its generated `workers.dev` address. [Worker limits](https://developers.cloudflare.com/workers/platform/limits/) and [Durable Object limits](https://developers.cloudflare.com/durable-objects/platform/pricing/) apply. Exceeding free quotas can interrupt monitoring.

1. Download the matching [Warden release source](https://github.com/fus3r/warden/releases) and extract it on your Mac. Node.js and npm are required. This hosts the relay separately from the monitored Linux server.
2. From the extracted project directory, install the relay dependencies, complete Cloudflare's login and deploy:

    ```sh
    cd Relay/Worker
    npm ci --ignore-scripts
    npx wrangler login --scopes account:read user:read workers_scripts:write
    npm run deploy
    ```

3. Copy the HTTPS origin printed by Wrangler and check its health:

    ```sh
    curl --fail https://YOUR-WORKER.workers.dev/health
    ```

    The expected response is `{"ok":true,"service":"warden-agent-relay"}`.

4. In **Warden Settings → SSH → Follow after SSH expires…**, replace the included origin with your verified origin and choose **Start in Terminal**. Complete the ordinary SSH login as described in [remote setup](remote-ssh.md#follow-after-ssh-expires).

One upload and one Mac read every twenty seconds use approximately **8,640 requests per continuously connected host per day**, excluding setup, retries and health checks. This is an arithmetic estimate. Multiple agent sessions on that host share its feed. Account request, CPU and storage-operation quotas still apply.

The relay receives encrypted packets, without the decryption key or conversation content. Its SQLite Durable Object keeps routing-token hashes, connection challenges, preferences and liveness times. It replaces the latest encrypted packet per host, without a packet history. A fresh Mac challenge, pause or removal clears that packet; packets older than ninety seconds are deleted on the next feed read. Logs and application traces are disabled in the supplied configuration. Cloudflare handles traffic routing and can observe timing and packet sizes.

To retire your deployment, remove both its Worker and Durable Object namespace in Cloudflare. Deleting code alone does not remove the stored routing records.

## Self-hosted Node relay

Use a Linux host with Docker Compose and a DNS hostname pointing to it. It needs inbound ports 80 and 443. Copy the reviewed Warden release source there and run these commands from `Relay/`:

```sh
export WARDEN_PHONE_HOST=phone.your-domain.example
docker compose up -d --build
curl --fail "https://$WARDEN_PHONE_HOST/health"
```

Caddy obtains and renews the HTTPS certificate. The relay is reachable through Caddy, which replaces the client-IP header used for rate limiting. Do not publish port 8787 with `TRUST_PROXY=1`. The `phone-data` volume preserves pairing hashes and VAPID keys across upgrades; keep private backups. Replacing the VAPID keys requires users to enable phone notifications again.

For agent monitoring, enter this verified HTTPS origin in the host's **Follow after SSH expires…** setup. The Node relay keeps the latest encrypted agent packet in memory. A service restart clears it; the temporary collector supplies a new packet while it remains authorized.

For phone access, follow [the source build setup](../development.md), then build Warden against your verified service from the project directory:

```sh
WARDEN_PHONE_RELAY_URL=https://phone.your-domain.example train-guard run --name warden-phone-build -- ./Scripts/build-app.sh universal
```

The phone relay origin belongs to the build. **Settings → Phone → Anywhere** then provides the expiring QR code. On iPhone, add the page to the Home Screen, pair there and grant notifications there; Safari and the Home Screen app can have separate storage.

The Mac and phone hold independent pairing and encryption keys. The relay routes encrypted state and replies, stores routing and push metadata, and sends generic notifications. The served browser client is part of the trust boundary: restrict deployment access, and keep pairing links out of logs and analytics. A compromised web client could read its own keys.

## Verify a phone deployment

Run `npm ci --ignore-scripts` and `npm test` from `Relay/`. Then pair the signed Mac app with a physical phone on mobile data, receive a notification with the screen locked, answer a harmless pending prompt, interrupt and reconnect the Mac network, and unpair. Check that the old QR and removed phone cannot reconnect. Verify power and closed-lid behavior on the intended Mac too.

Local tests and a desktop browser do not establish mobile-data access or locked-screen delivery. The included public agent relay is separate from these phone checks.

**Related:** [Remote agents](remote-ssh.md) · [Phone access](phone.md) · [Sources and privacy](../reference/privacy.md#optional-network-access)
