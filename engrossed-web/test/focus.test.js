import { test } from "node:test";
import assert from "node:assert/strict";
import { Sprint } from "../src/reader/sprint.js";
import { pickVoice, voicesFor } from "../src/reader/speech.js";
import { chunk } from "../src/reader/chunker.js";

// ---------- sprints ----------

test("a sprint measures time from the clock, not by counting ticks", () => {
  // Chrome throttles background timers to once a minute, so counting ticks
  // would lose almost all the time spent listening in another tab.
  const sprint = new Sprint(20);
  sprint.running = true;
  sprint.lastTick = performance.now() - 65_000;
  sprint.tick();
  assert.ok(sprint.elapsed >= 64 && sprint.elapsed < 67, `elapsed ${sprint.elapsed}`);
  sprint.halt();
});

test("pausing banks the partial second rather than throwing it away", () => {
  const sprint = new Sprint(20);
  sprint.running = true;
  sprint.lastTick = performance.now() - 700;
  sprint.pause();
  assert.ok(sprint.elapsed > 0.6, `lost time on pause: ${sprint.elapsed}`);
  assert.equal(sprint.running, false);
});

test("a sprint finishes exactly once and stops itself", () => {
  const sprint = new Sprint(1);
  let finishes = 0;
  sprint.onFinish = () => { finishes += 1; };
  sprint.running = true;
  sprint.elapsed = 59;
  sprint.lastTick = performance.now() - 2000;
  sprint.tick();
  sprint.tick();
  assert.equal(finishes, 1);
  assert.equal(sprint.finished, true);
  assert.equal(sprint.running, false);
  assert.equal(sprint.remainingText, "0:00");
});

test("restart clears the count and the clock", () => {
  const sprint = new Sprint(20);
  sprint.elapsed = 600;
  sprint.record(40);
  sprint.finished = true;
  sprint.restart();
  assert.deepEqual([sprint.elapsed, sprint.chunks, sprint.words, sprint.finished], [0, 0, 0, false]);
  sprint.halt();
});

test("a sprint carries over to the next article only within ten minutes", () => {
  const at = Date.now();
  const saved = { elapsed: 300, chunks: 12, words: 540, finished: false, updatedAt: at - 4 * 60_000 };

  const carried = Sprint.restore(saved, 20, at);
  assert.equal(carried.elapsed, 300);
  assert.equal(carried.chunks, 12);

  const stale = Sprint.restore({ ...saved, updatedAt: at - 11 * 60_000 }, 20, at);
  assert.equal(stale.elapsed, 0, "a sprint from half an hour ago should not continue");

  const done = Sprint.restore({ ...saved, finished: true }, 20, at);
  assert.equal(done.elapsed, 0, "a finished sprint must not be resumed");

  assert.equal(Sprint.restore(null, 20, at).elapsed, 0);
});

// ---------- voices ----------

const voice = (name, lang, localService, extra = {}) =>
  ({ name, lang, localService, voiceURI: name, default: false, ...extra });

const VOICES = [
  voice("Google US English", "en-US", false),
  voice("Samantha", "en-US", true),
  voice("Daniel", "en-GB", true, { default: true }),
  voice("Thomas", "fr-FR", true),
  voice("Google français", "fr-FR", false),
];

test("the automatic voice is always on-device, never an online one", () => {
  // Online voices send the text to Google. Everything else in the extension
  // stays on the device, so the default must not quietly change that.
  const picked = pickVoice(VOICES, "", "en-US");
  assert.ok(picked, "found no voice");
  assert.equal(picked.localService, true, `picked an online voice: ${picked.name}`);
  assert.equal(picked.name, "Daniel", "should prefer the system default among local voices");
});

test("the automatic voice matches the article's language", () => {
  assert.equal(pickVoice(VOICES, "", "fr")?.name, "Thomas");
});

test("with no on-device voice in that language, Chrome picks rather than us", () => {
  const onlyOnline = [voice("Google 日本語", "ja-JP", false)];
  assert.equal(pickVoice(onlyOnline, "", "ja"), null);
});

test("a chosen voice wins, including an online one the reader picked", () => {
  assert.equal(pickVoice(VOICES, "Google US English", "en")?.name, "Google US English");
  assert.equal(pickVoice(VOICES, "No Longer Installed", "en")?.localService, true,
               "a missing choice should fall back to on-device");
});

test("the voice list puts the article's language and on-device voices first", () => {
  const listed = voicesFor(VOICES, "en").map((v) => v.name);
  assert.deepEqual(listed, ["Daniel", "Samantha", "Google US English"]);
});

// ---------- contents ----------

test("headings keep their level, so the contents list can nest", () => {
  const { chunks } = chunk([
    { kind: "heading", text: "Zones", level: 2 },
    { kind: "heading", text: "High tide zone", level: 3 },
    { kind: "paragraph", text: "The high tide zone floods only at the top of the tide." },
  ]);
  const headings = chunks.filter((c) => c.kind === "heading");
  assert.deepEqual(headings.map((h) => h.level), [2, 3]);
});
