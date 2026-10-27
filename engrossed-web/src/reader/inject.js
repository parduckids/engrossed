// Bootstrap.
//
// Injected files run as classic scripts, not modules, so this tiny shim is the
// bridge: it hands Readability (injected just before it, into the same isolated
// world) to the module graph, then dynamically imports the real reader. The
// import needs src/reader/* to be web-accessible, which the manifest declares.

(() => {
  if (typeof Readability === "function") {
    globalThis.__engrossedReadability = Readability;
  }

  const url = chrome.runtime.getURL("src/reader/main.js");
  import(url)
    .then((module) => module.open())
    .catch((error) => {
      console.error("Engrossed failed to open:", error);
    });
})();
