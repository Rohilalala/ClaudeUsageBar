// ClaudeUsageBar background service worker.
//
// Receives usage payloads from the content script and forwards them to the
// local menu bar app over loopback only. Failures are expected when the app is
// not running, so they are swallowed and logged at debug level.

const ENDPOINT = "http://127.0.0.1:8787/usage";

// When the extension is installed or updated, Chrome does not re-inject content
// scripts into already-open tabs, so they keep running stale code (or none).
// Re-inject into every open claude.ai tab so updates take effect without the
// user having to reload each tab by hand.
chrome.runtime.onInstalled.addListener(() => {
  const contentScripts = [
    { url: "https://claude.ai/*", file: "content.js" },
    { url: "https://chatgpt.com/*", file: "content-chatgpt.js" }
  ];
  for (const { url, file } of contentScripts) {
    chrome.tabs.query({ url }, (tabs) => {
      for (const tab of tabs) {
        if (tab.id == null) continue;
        chrome.scripting.executeScript({
          target: { tabId: tab.id },
          files: [file]
        }).catch(() => { /* tab may be discarded or restricted; ignore */ });
      }
    });
  }
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== "usage") return;

  fetch(ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(message.payload)
  })
    .then(() => sendResponse({ ok: true }))
    .catch((err) => {
      // The app may not be running. This is not an error worth surfacing.
      console.debug("ClaudeUsageBar: relay failed", err);
      sendResponse({ ok: false });
    });

  // Keep the async message channel open for the fetch above.
  return true;
});
