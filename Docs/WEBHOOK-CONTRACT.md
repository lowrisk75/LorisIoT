# LorisIoT webhook contract (v1)

The app↔automation boundary is a **versioned, signed JSON contract** (research #08), not ad-hoc
URLs. Producer: `IoTWebhook.WebhookClient`. Consumer: any HTTPS endpoint — the reference
Node-RED flow in [`nodered/flows.json`](nodered/flows.json) implements the full verification.

## Request

```
POST <https URL, no query/userinfo/fragment>
Content-Type: application/json
X-LorisIoT-Signature: sha256=<hex HMAC-SHA256(secret, rawBody)>
X-LorisIoT-Timestamp: <unix seconds, same value as body.ts>
```

Body (`WebhookPayload`):

```json
{ "v": 1, "eventId": "8A6E…-uuid", "ts": 1723400000,
  "action": "wake", "device": "coffee", "params": { "on": "true" } }
```

| Field | Rule |
|---|---|
| `v` | Contract version. Flows branch on it; unknown version → 400, never guess. |
| `eventId` | Idempotency key. The consumer dedupes — a retried POST must not double-fire. |
| `ts` | Replay window: reject when `|now − ts| > 300 s`. |
| `action` / `device` / `params` | Domain payload. `params` values are strings by design (stable wire format). |

## Consumer obligations (all implemented in the reference flow)

1. Recompute `HMAC-SHA256(secret, rawBody)` and constant-time-compare with the header. 401 on mismatch.
2. Reject stale/future `ts` outside the 300 s window (403).
3. Dedupe on `eventId` (200 with `{"duplicate":true}` — success, because the first delivery won).
4. Branch on `v`; unknown → 400.
5. Never log the secret; never accept the secret via query string.

## Responses

- `2xx` — accepted (including deduped replays). The client treats anything else as retryable
  failure (`eventId` makes retries safe).
- Inbound (server→app) is **not** part of this contract: iOS can't hold a socket — use APNs
  silent push, or the app polls on foreground (research #07/#08).

## Secret management

Per-URL secret, generated once, stored in Keychain (`KeychainStore`, ThisDeviceOnly), pasted into
the Node-RED flow's credential field. Rotation = new secret both sides; the contract carries no
key-id on purpose (one URL = one secret).
