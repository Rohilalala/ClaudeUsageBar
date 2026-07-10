# Codex (ChatGPT) usage support — design

Date: 2026-07-10
Status: approved (chat, 2026-07-10)

## Goal

Show OpenAI Codex usage limits in the menu bar alongside Claude, sourced from the
user's own logged-in chatgpt.com session, with a menu option to choose which
Codex model version's limit lane is displayed.

## Decisions (user-approved)

- **Single status item, both providers**: title like `Claude 35% · Codex 12%`.
  Settings toggles choose which providers/metrics appear.
- **"Codex version" picks the limit lane**: the wham usage API returns the main
  account windows plus per-model limits (`additional_rate_limits[]`). The
  submenu selects which lane feeds the displayed Codex figures. Default = main
  account window.

## Data source

`GET https://chatgpt.com/backend-api/wham/usage` — the same endpoint the Codex
CLI polls every 60s.

Auth from a browser session (content script on chatgpt.com):
1. `GET /api/auth/session` with cookies → `accessToken` (+ account id when present)
2. `GET /backend-api/wham/usage` with `Authorization: Bearer <accessToken>`
   (+ `ChatGPT-Account-Id` header when known)

Response shape (per Codex CLI / CodexBar docs; field names to be verified live):
- `rate_limit.primary_window` → 5-hour lane (`used_percent`, reset time)
- `rate_limit.secondary_window` → weekly lane
- `additional_rate_limits[]` → model-specific lanes (e.g. GPT-5.3-Codex-Spark)

The parser must tolerate both plausible naming variants (`used_percent` vs
`utilization`, `resets_at` ISO vs `resets_in_seconds`) and drop absent fields.

## Components

### Extension

- **`Extension/content-chatgpt.js`** (new): runs on `https://chatgpt.com/*`.
  60s poll: session token → wham/usage → build payload:

  ```json
  {
    "provider": "codex",
    "five_hour": { "value": "12%", "detail": "12% used", "reset": "2:40 PM" },
    "weekly":    { "value": "4%",  "detail": "4% used",  "reset": "Mon 8:30 PM" },
    "models": [
      { "id": "gpt-5.3-codex", "label": "GPT-5.3-Codex",
        "five_hour": { ... }, "weekly": { ... } }
    ]
  }
  ```

  Same idempotency guard, error-swallowing, and reset formatting conventions as
  `content.js`. Signed-out / non-JSON / 401 → skip tick silently.

- **`Extension/content.js`**: add `provider: "claude"` to the payload. No other
  change.

- **`Extension/manifest.json`**: add `https://chatgpt.com/*` to
  `host_permissions` and a second `content_scripts` entry for
  `content-chatgpt.js`.

- **`Extension/background.js`**: payload passthrough unchanged; extend the
  onInstalled re-inject to chatgpt.com tabs with `content-chatgpt.js`.

### Menu bar app (`MenuBarApp/main.swift`)

- **State**: per-provider. Claude {fiveHour, weekly, lastUpdate}; Codex
  {fiveHour, weekly, models[], lastUpdate}. Staleness computed per provider
  (>10 min), so a closed chatgpt tab never marks Claude stale and vice versa.
  Model list and metrics sanitized like existing values; models capped (≤10)
  to bound menu size.

- **HTTP `/usage`**: route on `provider` field; absent → claude (back-compat
  with an already-loaded old extension). CORS: replace the hardcoded
  `Access-Control-Allow-Origin: https://claude.ai` with reflection of the
  request Origin when it is in {https://claude.ai, https://chatgpt.com}
  (requires parsing the Origin header; fall back to claude.ai).

- **Menu**: new Codex section between the Claude lines and Updated line —
  5-hour detail + reset, weekly detail + reset, and a **Codex version ▸**
  submenu rebuilt when the model list changes: first item "Account limit"
  (default), then one item per model. Selection stored in UserDefaults
  (`codexVersionId`); when the selected lane is a model, its metrics feed the
  Codex figures everywhere (title, details, notifications). If a selected
  model disappears from the payload, fall back to account lane (keep the
  stored preference).

- **Settings**: add "Show Codex 5-hour in title" (default off) and "Show Codex
  weekly in title" (default off). Existing "Show Claude label" now renders the
  provider-prefixed style: when multiple providers are shown, each part is
  prefixed (`Claude 35% · Codex 12%`); label toggle off → `35% · 12%`.

- **Title composition**: parts joined `·`; existing 100%-reset-countdown
  behavior stays Claude-five-hour-only. Warn/crit coloring by the max percent
  among shown parts (unchanged logic, now includes Codex parts).

- **Notifications**: threshold crossing extended to Codex 5-hour and weekly
  (`"Codex usage high"`). Reset alarm remains Claude 5-hour only (unchanged
  scope).

- **"Sync usage with ChatGPT"** menu item opening
  `https://chatgpt.com/codex/settings/usage`.

## Error handling

- Extension: any fetch/parse failure = skip tick, retry next minute; never
  throws user-visible errors. 404/401 on usage → also drop cached token so the
  next tick re-resolves the session.
- App: unknown provider value → ignored. Malformed models entries dropped
  individually.

## Testing / verification

1. Build (`./build.sh`), load extension unpacked, open logged-in chatgpt.com
   tab; verify real wham/usage response shape in the tab console (content
   script logs raw shape once at debug level) and adjust parser if field names
   differ.
2. Verify menu bar shows both providers live; toggle settings; pick a model
   version; kill chatgpt tab → Codex goes stale alone.
3. curl the local server: claude-only payload (old extension shape, no
   provider) still updates Claude — back-compat check.
