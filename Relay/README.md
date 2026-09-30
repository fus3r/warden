# Warden phone service

The publisher hosts this service once. Users scan a QR code in Warden and can then use the phone page over Wi-Fi or mobile data. They do not install a VPN, configure a server, or trust a local certificate. The existing local-network mode remains available.

The Mac makes an outbound WebSocket connection. Each phone gets independent 256-bit pairing and encryption keys. A QR expires after five minutes and is exchanged for new credentials when used. HKDF-SHA256 derives separate AES-256-GCM keys for each direction. Connection challenges and request IDs bind answers to the current connection. The relay routes ciphertext without storing it. Saved routing tokens are hashed; the relay stores push subscriptions and last-connection times. Push notifications contain only a generic notice. The phone renders decrypted state in memory; local storage holds its pairing credentials, not session content.

The browser client is delivered by this service, so the HTTPS origin and the software deployed there are part of the trust boundary. Keep its deployment access restricted. A compromised web client could read its own keys. Pairing links grant access to a phone; do not put them in logs or analytics. There are no analytics or third-party scripts in this service.

## Deploy

Use a Linux host with Docker Compose and a DNS hostname pointing to it. The host needs inbound ports 80 and 443. Copy the reviewed release files to that host, then from `Relay/` run:

```sh
export WARDEN_PHONE_HOST=phone.your-domain.example
docker compose up -d --build
curl --fail "https://$WARDEN_PHONE_HOST/health"
```

Caddy obtains and renews the HTTPS certificate. The relay is reachable only through Caddy, which replaces the client-IP header used for rate limiting. Do not publish port 8787 with `TRUST_PROXY=1`. The `phone-data` volume keeps pairing token hashes and VAPID keys across upgrades. Back it up privately; replacing VAPID keys requires users to enable notifications again. No account, payment, DNS change, or public deployment is performed by the build scripts.

Build the app against that verified service:

```sh
WARDEN_PHONE_RELAY_URL=https://phone.your-domain.example ./Scripts/build-app.sh universal
```

The URL belongs to the release, not a user preference. Builds without it offer local-network access and do not claim to provide remote access. On an iPhone, add the phone page to the Home Screen, open it there, pair there if needed, and enable notifications using its button. Safari and the installed web app may have different storage.

## Verify before offering it to users

```sh
npm ci --ignore-scripts
npm test
```

Then pair the signed Mac app with a physical phone on mobile data, receive a notification with the screen locked, answer a harmless pending prompt, interrupt/reconnect the Mac network, and unpair. Verify that the old QR and the removed phone cannot reconnect. Also check the Mac's battery and closed-lid behavior on supported hardware. Local tests, a desktop browser, and mock push delivery do not prove those device behaviors.

For development only, run with `PUBLIC_ORIGIN=http://127.0.0.1:8787 DATA_DIR=/a/private/scratch/folder npm start`. A debug Warden build accepts `WARDEN_PHONE_RELAY_URL=http://127.0.0.1:8787`; release builds require HTTPS. The service defaults to 1,000 rooms, 1 MB packets, bounded connection/message rates and deletion of inactive routing records after seven days. These are operational safeguards, not a validated production capacity figure.
