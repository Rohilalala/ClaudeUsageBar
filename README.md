<div align="center">

<img src="assets/icon.png" alt="ClaudeUsageBar icon" width="128" height="128" />

# ClaudeUsageBar

### See your Claude AI — and ChatGPT Codex — usage limits live in the macOS menu bar

Track your **Claude 5-hour limit** and **weekly limit** (and optionally your **ChatGPT Codex limits**) at a glance — no more opening settings, refreshing the page, or getting surprised by a "you've reached your usage limit" message mid-prompt.

[![Download .dmg](https://img.shields.io/github/v/release/Rohilalala/ClaudeUsageBar?label=Download%20.dmg&color=D97757)](https://github.com/Rohilalala/ClaudeUsageBar/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black?logo=apple)](#install)
[![Browser](https://img.shields.io/badge/browser-Chrome%20%C2%B7%20Edge%20%C2%B7%20Brave%20%C2%B7%20Arc-4285F4?logo=googlechrome&logoColor=white)](#2-load-the-browser-extension)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Made with Swift](https://img.shields.io/badge/Swift-native-orange?logo=swift&logoColor=white)](MenuBarApp/main.swift)

</div>

---

> **TL;DR** — A tiny native macOS menu bar app + a browser extension. The extension reads your usage straight from your own logged-in Claude.ai (and optionally chatgpt.com) session and shows it in your menu bar like `Claude 35%` or `Claude 35% · Codex 12%`. It turns **orange at 75%** and **red at 90%**, and pings you before you hit the wall.

<div align="center">
<img src="assets/screenshot.png" alt="ClaudeUsageBar showing Claude 5-hour and weekly usage in the macOS menu bar" width="380" />
</div>

## Why?

If you use **Claude**, **Claude Code**, or the **Claude Max / Pro** plans, you live with two invisible meters: a rolling **5-hour session limit** and a **weekly limit**. Anthropic only shows them buried in Settings → Usage. ClaudeUsageBar surfaces them where you'll actually see them — your menu bar — so you can pace your work and never get blindsided by a rate limit again.

## Features

- 📊 **5-hour + weekly usage** — both Claude limits, live in the menu bar (`Claude 35%`).
- 🤖 **ChatGPT Codex too** *(new in 1.1)* — optionally track your ChatGPT Codex 5-hour and weekly limits alongside Claude: `Claude 35% · Codex 12%`.
- 🎨 **Color warnings** — title goes **orange at 75%**, **red at 90%**. Glanceable.
- 🖌️ **Per-provider title colors** *(new in 1.1)* — pick a palette color per provider (defaults: Claude orange, Codex green); warning colors still take over near the limit.
- 🔔 **Threshold notifications** — a macOS alert when any limit crosses 90%, so you can wrap up before you're cut off.
- ⏰ **Reset countdown + alarm** — see exactly when your 5-hour window resets, with an optional alarm at reset time.
- 🔕 **Pick your sound** — choose any macOS system sound for alerts (hover to preview).
- 🧩 **Reads the real numbers** — pulls from Claude.ai's own usage API in your logged-in session. Accurate, not guessed.
- 🪶 **Native & tiny** — pure Swift `NSStatusItem`, no Dock icon, no Electron, negligible resources.
- 🔒 **100% local & private** — your usage never leaves your machine. Talks only to `127.0.0.1`.
- ⚙️ **Customizable title** — show 5-hour, weekly, or both; hide the word "Claude" for a minimal `35%`.
- 🚀 **Start at login** — set it once and forget it.

## Install

### 1. The menu bar app

**Option A — download the prebuilt disk image (easiest):**

Grab **`ClaudeUsageBar.dmg`** from the [latest release](https://github.com/Rohilalala/ClaudeUsageBar/releases/latest) and open it.

**Option B — build the disk image yourself:**

```bash
./package.sh
open build/ClaudeUsageBar.dmg
```

The disk image bundles everything — the app, the browser **Extension** folder, and an **INSTALL.txt** — on a single drag-to-install screen. Drag `ClaudeUsageBar.app` into **Applications** and launch it from there.

**Option C — build and run directly (no disk image):**

```bash
./build.sh
open build/ClaudeUsageBar.app
```

The build is ad-hoc code signed (required for start-at-login and notifications). The app appears in the menu bar with **no Dock icon**. It shows `Claude --` until the extension sends data.

> 💡 Launch the app from **/Applications**, not `build/` — `./build.sh` wipes `build/` on every run, which would break the start-at-login registration.

### 2. Load the browser extension

Works in any Chromium browser — **Chrome, Edge, Brave, Arc**.

1. Copy the **Extension** folder somewhere permanent (e.g. `~/Documents`). An unpacked extension must stay on disk — loading it from the disk image breaks once the image ejects.
2. Open `chrome://extensions`.
3. Turn on **Developer mode** (top-right).
4. Click **Load unpacked** and select that **Extension** folder.
5. Open or reload a logged-in [claude.ai](https://claude.ai) tab. For Codex usage, also keep a logged-in [chatgpt.com](https://chatgpt.com) tab open.

That's it. The menu bar starts updating within a minute.

## Usage

Click the menu bar item for the full breakdown:

```
Sync usage with Claude.ai
Sync usage with ChatGPT
───────────────
Claude 5-hour:  35% used
Resets 2:43 PM (in 3h 28m)
Claude weekly:  32% used
Resets Mon 8:30 PM
───────────────
Codex 5-hour:  12% used
Resets 4:10 PM (in 4h 55m)
Codex weekly:  8% used
Resets Thu 11:00 AM
───────────────
Updated 12s ago
───────────────
Settings ▸
  Show Claude 5-hour in title
  Show Claude weekly in title
  Show Codex 5-hour in title
  Show Codex weekly in title
  Show provider labels
  Show "Resets at" label
  Show reset countdown
  Alarm at 5-hour reset
  Claude color ▸
  Codex color ▸
  Notification sound ▸
  ─────────────
  Start at login
───────────────
Quit
```

- **Color coding** — each provider's segment uses its own color (orange for Claude, green for Codex by default, or any palette color you pick), overridden by **orange ≥ 75%** / **red ≥ 90%** based on that provider's own figures.
- **At 100%** the 5-hour title flips to the reset time, e.g. `Claude Resets at 2:40 PM`.
- **Minimal mode** — turn off *Show provider labels* for a bare `35%`, or show both figures for `35% / 32%`.

You only need a logged-in claude.ai tab open *somewhere* — the Settings/Usage page does **not** have to be open. Same for chatgpt.com if you track Codex. The extension polls about once a minute and keeps the menu bar fresh on its own.

## How it works

```
claude.ai usage API   →  content.js          ⎫
  (/api/.../usage)        (poll+map)          ⎬→  background.js  →  127.0.0.1:8787  →  Swift app
chatgpt.com wham API  →  content-chatgpt.js  ⎭     (relay POST)      (loopback)        (menu bar)
  (/backend-api/wham/usage)  (poll+map)
```

1. `content.js` polls Claude.ai's own usage API (`/api/organizations/:id/usage`) from your logged-in tab; `content-chatgpt.js` does the same for Codex via chatgpt.com's `/backend-api/wham/usage` (the endpoint the Codex CLI itself polls).
2. `background.js` relays the result as JSON to the local app, tagged per provider.
3. The Swift app runs a minimal HTTP server bound to `127.0.0.1:8787` **only** and renders the figures. Staleness is tracked per provider — a closed chatgpt.com tab never marks your Claude figures stale.

## Privacy & security

ClaudeUsageBar is **fully local and client-side**:

- Reads **your own** usage from **your own** logged-in session — no credentials stored, no login, no account.
- Sends data **only** to `http://127.0.0.1:8787` on your machine. Nothing is uploaded anywhere.
- The local server binds to **loopback only**, locks CORS to `https://claude.ai` and `https://chatgpt.com`, rejects mismatched `Host` headers (DNS-rebinding guard), caps request size, and sanitizes every field before it reaches the menu bar.

## FAQ

**How do I see how much Claude usage I have left?**
Install ClaudeUsageBar — it shows your remaining 5-hour and weekly Claude usage as a live percentage in the macOS menu bar.

**Does this work with Claude Code and the Claude Max / Pro plans?**
Yes. It reads whatever limits your account has (5-hour session + weekly), so it works across Claude.ai chat, Claude Code, Max, and Pro.

**Can it track ChatGPT Codex usage too?**
Yes (since 1.1). Keep a logged-in chatgpt.com tab open and toggle *Show Codex 5-hour / weekly in title* in Settings. It reads the same rate-limit endpoint the Codex CLI polls, so it works on Plus, Pro, and Team plans.

**Is it safe / does it have my Claude password?**
No password, no login, no data leaves your Mac. It only reads usage numbers from your already-logged-in browser session and shows them locally.

**Why a browser extension instead of an API key?**
Anthropic doesn't expose usage limits via the public API. The extension reads them from your own session — the same numbers you'd see on the Usage page.

**It stopped updating — what do I do?**
Anthropic may have changed their internal API. See [When it stops working](#when-it-stops-working) to point it at the new fields in a couple of lines.

**Does it support Safari?**
Not out of the box — Safari needs Xcode's `safari-web-extension-converter`. Chromium browsers are plug-and-play.

## When it stops working

The extension reads Claude.ai's usage API, so UI/wording changes don't affect it — but the API shape could change. `poll()` in `Extension/content.js`:

- `GET /api/organizations` → finds your organization id
- `GET /api/organizations/:id/usage` → reads `five_hour.utilization` / `five_hour.resets_at` and `seven_day.utilization` / `seven_day.resets_at`

If the menu bar stops updating:

1. Open a logged-in claude.ai tab + DevTools. Confirm the console shows `[ClaudeUsageBar] content script active (API mode)`.
2. Run `await (await fetch("/api/organizations")).json()`, then fetch `/api/organizations/<id>/usage` to see the current field names.
3. Update the field references in `poll()`, then reload the extension at `chrome://extensions`.

Codex works the same way in `Extension/content-chatgpt.js`: `/api/auth/session` → access token, then `GET /backend-api/wham/usage` → `rate_limit.primary_window` (5-hour) and `secondary_window` (weekly), fields `used_percent` / `reset_at`. The raw response shape is logged once at `console.debug` to make re-mapping easy.

## Contributing

Issues and PRs welcome. The whole thing is ~600 lines of Swift + ~150 lines of JavaScript, no build system beyond `swiftc`.

## Disclaimer

Unofficial project. **Not affiliated with, endorsed by, or supported by Anthropic.** It reads your own usage figures from your own logged-in Claude.ai session, entirely client-side. The figures come from an undocumented Claude.ai endpoint that Anthropic may change at any time. You are responsible for reviewing Anthropic's terms before use.

## License

[MIT](LICENSE) © ClaudeUsageBar contributors

---

**Keywords:** Claude usage menu bar, Claude AI usage tracker for Mac, Claude Code usage monitor, Claude 5-hour limit, Claude weekly limit tracker, Claude Max / Pro usage, macOS menu bar Claude rate limit, ChatGPT Codex usage tracker, Codex rate limit monitor, see how much Claude usage is left.
