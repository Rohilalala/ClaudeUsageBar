// ClaudeUsageBar content script.
//
// Reads usage figures from claude.ai's own usage API (same-origin, using your
// already logged-in cookies) and relays them to the background worker, which
// forwards them to the local menu bar app.
//
// Using the API instead of scraping the page means this works from ANY claude.ai
// tab — the usage settings panel does not need to be open — and it does not
// depend on page markup that changes often.
//
// The endpoint is undocumented and may change. The shapes consumed below are:
//   GET /api/organizations            -> [{ uuid, name, ... }]
//   GET /api/organizations/:id/usage  -> {
//     five_hour: { utilization: <int %>, resets_at: <ISO8601> },
//     seven_day: { utilization: <int %>, resets_at: <ISO8601> }, ...
//   }
// "five_hour" is the 5-hour rolling limit; "seven_day" is the weekly all-models
// limit. If a field disappears or is renamed, update the references in poll().

// Idempotency guard. The background worker re-injects this file into open tabs
// on extension update, so bail out if a copy is already running here to avoid
// stacking duplicate timers.
if (document.documentElement.dataset.claudeUsageBar === "active") {
  // Already initialized in this document.
} else {
  document.documentElement.dataset.claudeUsageBar = "active";

  // How often to poll the usage API, in milliseconds.
  const POLL_INTERVAL_MS = 60000;

  // Resolved once and cached. Reset to null to force re-resolution.
  let orgId = null;

  async function getOrgId() {
    if (orgId) return orgId;
    const orgs = await fetch("/api/organizations", { credentials: "include" }).then((r) => r.json());
    if (!Array.isArray(orgs) || orgs.length === 0) throw new Error("no organizations");
    orgId = (orgs.find((o) => o && o.uuid) || {}).uuid;
    if (!orgId) throw new Error("no organization uuid");
    return orgId;
  }

  // Turns a usage node ({ utilization, resets_at }) into the Metric shape the app
  // expects, or null when the figure is absent.
  function metric(node, formatReset) {
    if (!node || typeof node.utilization !== "number") return null;
    const pct = Math.round(node.utilization);
    return {
      value: `${pct}%`,
      detail: `${pct}% used`,
      reset: node.resets_at ? formatReset(node.resets_at) : ""
    };
  }

  // 5-hour reset -> a local clock time like "2:40 PM" so the app can render a
  // live countdown from it.
  function clockReset(iso) {
    const d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    return d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
  }

  // Weekly reset -> "Mon 8:30 PM" (weekday plus local time).
  function weekdayReset(iso) {
    const d = new Date(iso);
    if (isNaN(d.getTime())) return "";
    return d
      .toLocaleString("en-US", { weekday: "short", hour: "numeric", minute: "2-digit" })
      .replace(",", "");
  }

  async function poll() {
    let usage;
    try {
      const id = await getOrgId();
      const res = await fetch(`/api/organizations/${id}/usage`, { credentials: "include" });
      if (res.status === 404) {
        orgId = null; // org may have changed; re-resolve next tick
        return;
      }
      if (!res.ok) return;
      usage = await res.json();
    } catch (e) {
      return; // signed out, offline, transient error: try again next tick
    }

    const payload = { provider: "claude" };
    const five = metric(usage.five_hour, clockReset);
    const weekly = metric(usage.seven_day, weekdayReset);
    if (five) payload.five_hour = five;
    if (weekly) payload.weekly = weekly;
    if (!payload.five_hour && !payload.weekly) return;

    // Send on every poll (not just on change) so the app's "Updated" line stays
    // fresh and it never falsely flips to stale while we are polling fine.
    try {
      chrome.runtime.sendMessage({ type: "usage", payload });
    } catch (e) {
      // Extension context can be invalidated on reload. Ignore quietly.
    }
  }

  console.info("[ClaudeUsageBar] content script active (API mode)");
  poll();
  setInterval(poll, POLL_INTERVAL_MS);
}
