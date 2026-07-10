// ClaudeUsageBar content script for chatgpt.com (Codex limits).
//
// Reads Codex usage figures from ChatGPT's own backend API (same-origin, using
// your already logged-in session) and relays them to the background worker,
// which forwards them to the local menu bar app.
//
// Auth: backend-api calls need a bearer token, not just cookies. The token is
// obtained the same way the chatgpt.com frontend does it:
//   GET /api/auth/session -> { accessToken, account?: { id } }
// then:
//   GET /backend-api/wham/usage  (Authorization: Bearer <accessToken>)
//
// This is the endpoint the Codex CLI polls for its own rate-limit display.
// The shapes consumed below are:
//   rate_limit.primary_window    -> 5-hour lane
//   rate_limit.secondary_window  -> weekly lane
//   additional_rate_limits[]     -> model-specific lanes (e.g. Codex Spark)
// Field names inside a window vary across deployments, so parsing tolerates
// both { used_percent | utilization } and { resets_at | resets_in_seconds |
// resets_at_unix }. If a field disappears entirely, update parseWindow().

// Idempotency guard: the background worker re-injects this file into open tabs
// on extension update, so bail out if a copy is already running here.
if (document.documentElement.dataset.claudeUsageBarCodex === "active") {
  // Already initialized in this document.
} else {
  document.documentElement.dataset.claudeUsageBarCodex = "active";

  // How often to poll the usage API, in milliseconds.
  const POLL_INTERVAL_MS = 60000;

  // Resolved once and cached. Reset to null to force re-resolution (e.g. after
  // a 401, when the token has likely expired).
  let session = null; // { token, accountId }

  async function getSession() {
    if (session) return session;
    const res = await fetch("/api/auth/session", { credentials: "include" });
    if (!res.ok) throw new Error("no session");
    const data = await res.json();
    const token = data && data.accessToken;
    if (!token) throw new Error("signed out");
    const accountId =
      (data.account && data.account.id) ||
      (data.user && data.user.accountId) || "";
    session = { token, accountId };
    return session;
  }

  // Turns a rate-limit window into the Metric shape the app expects, or null
  // when the figure is absent. Tolerates the known field-name variants.
  function parseWindow(node, formatReset) {
    if (!node || typeof node !== "object") return null;
    let pct = node.used_percent;
    if (typeof pct !== "number") pct = node.utilization;
    if (typeof pct !== "number") return null;
    pct = Math.round(pct);

    let resetDate = null;
    if (typeof node.resets_in_seconds === "number") {
      resetDate = new Date(Date.now() + node.resets_in_seconds * 1000);
    } else if (typeof node.resets_at === "number") {
      resetDate = new Date(node.resets_at * 1000); // unix seconds
    } else if (typeof node.resets_at === "string") {
      resetDate = new Date(node.resets_at); // ISO8601
    }
    if (resetDate && isNaN(resetDate.getTime())) resetDate = null;

    return {
      value: `${pct}%`,
      detail: `${pct}% used`,
      reset: resetDate ? formatReset(resetDate) : ""
    };
  }

  // 5-hour reset -> a local clock time like "2:40 PM" so the app can render a
  // live countdown from it.
  function clockReset(d) {
    return d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
  }

  // Weekly reset -> "Mon 8:30 PM" (weekday plus local time).
  function weekdayReset(d) {
    return d
      .toLocaleString("en-US", { weekday: "short", hour: "numeric", minute: "2-digit" })
      .replace(",", "");
  }

  // Logged once per page load so the real response shape can be inspected in
  // the tab console if parsing ever comes up empty.
  let loggedShape = false;

  async function poll() {
    let usage;
    try {
      const s = await getSession();
      const headers = { Authorization: `Bearer ${s.token}` };
      if (s.accountId) headers["ChatGPT-Account-Id"] = s.accountId;
      const res = await fetch("https://chatgpt.com/backend-api/wham/usage", { headers });
      if (res.status === 401 || res.status === 403) {
        session = null; // token expired; re-resolve next tick
        return;
      }
      if (!res.ok) return;
      usage = await res.json();
    } catch (e) {
      return; // signed out, offline, transient error: try again next tick
    }

    if (!loggedShape) {
      loggedShape = true;
      console.debug("[ClaudeUsageBar] wham/usage shape", usage);
    }

    const rl = usage.rate_limit || usage.rate_limits || {};
    const payload = { provider: "codex" };
    const five = parseWindow(rl.primary_window, clockReset);
    const weekly = parseWindow(rl.secondary_window, weekdayReset);
    if (five) payload.five_hour = five;
    if (weekly) payload.weekly = weekly;

    // Model-specific lanes, e.g. GPT-5.3-Codex-Spark. Capped to keep the menu
    // (and the local payload) bounded.
    const extra = Array.isArray(usage.additional_rate_limits)
      ? usage.additional_rate_limits : [];
    const models = [];
    for (const entry of extra.slice(0, 10)) {
      if (!entry || typeof entry !== "object") continue;
      const erl = entry.rate_limit || entry.rate_limits || entry;
      const mFive = parseWindow(erl.primary_window, clockReset);
      const mWeekly = parseWindow(erl.secondary_window, weekdayReset);
      if (!mFive && !mWeekly) continue;
      const label = entry.label || entry.name || entry.model || entry.slug || "Model";
      const id = String(entry.id || entry.slug || entry.model || label);
      const model = { id, label: String(label) };
      if (mFive) model.five_hour = mFive;
      if (mWeekly) model.weekly = mWeekly;
      models.push(model);
    }
    if (models.length) payload.models = models;

    if (!payload.five_hour && !payload.weekly && !payload.models) return;

    // Send on every poll (not just on change) so the app's staleness tracking
    // stays accurate while we are polling fine.
    try {
      chrome.runtime.sendMessage({ type: "usage", payload });
    } catch (e) {
      // Extension context can be invalidated on reload. Ignore quietly.
    }
  }

  console.info("[ClaudeUsageBar] chatgpt content script active (API mode)");
  poll();
  setInterval(poll, POLL_INTERVAL_MS);
}
