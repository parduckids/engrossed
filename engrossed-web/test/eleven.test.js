import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  VOICES, MESSAGES, MODEL_ID, OUTPUT_FORMAT, KEY_STORAGE, buildRequest, cleanKey,
  detailStatusOf, messageFor, speakable, speedFor, toBase64, uriFor, voiceChoices, voiceFromURI,
} from "../src/eleven.js";
import {
  ElevenNarrator, UNREACHABLE, elevenStatus, isSpoken, nextSpokenIndex,
} from "../src/reader/eleven-speech.js";

// Never a real key, anywhere.
const FAKE_KEY = "test-key-not-real";
const here = path.dirname(fileURLToPath(import.meta.url));
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------- the request ----------

test("the request is the verified shape: URL, headers, body, model and format", () => {
  const { url, init } = buildRequest(FAKE_KEY, "woman", "A tide pool is a rocky pool.", 1);
  assert.equal(url, `https://api.elevenlabs.io/v1/text-to-speech/WQP7cQUF5aAS6Axh5yaa?output_format=mp3_44100_64`);
  assert.equal(init.method, "POST");
  assert.deepEqual(init.headers, {
    "xi-api-key": FAKE_KEY,
    "Content-Type": "application/json",
    Accept: "audio/mpeg",
  });
  assert.deepEqual(JSON.parse(init.body), {
    text: "A tide pool is a rocky pool.",
    model_id: "eleven_flash_v2_5",
    voice_settings: { stability: 0.5, similarity_boost: 0.75, speed: 1 },
  });
  assert.equal(MODEL_ID, "eleven_flash_v2_5", "flash reads Hungarian; multilingual_v2 does not");
  assert.equal(OUTPUT_FORMAT, "mp3_44100_64");
  assert.equal(init.credentials, "omit");
});

test("the man's voice goes to its own id", () => {
  const { url } = buildRequest(FAKE_KEY, "man", "Hello.", 1);
  assert.equal(url, `https://api.elevenlabs.io/v1/text-to-speech/gOupLcAkjEnguROwi4oS?output_format=mp3_44100_64`);
});

test("the two voice ids are the chosen library voices, and the list shows labels only", () => {
  assert.deepEqual(Object.keys(VOICES), ["woman", "man"]);
  assert.equal(VOICES.woman.id, "WQP7cQUF5aAS6Axh5yaa");
  assert.equal(VOICES.man.id, "gOupLcAkjEnguROwi4oS");
  assert.deepEqual(voiceChoices(), [
    { uri: "eleven:woman", label: "Woman" },
    { uri: "eleven:man", label: "Man" },
  ]);
});

test("the key travels in its header only: not the URL, not the body", () => {
  const { url, init } = buildRequest(`  ${FAKE_KEY}\n`, "woman", "Some words.", 1);
  assert.equal(init.headers["xi-api-key"], FAKE_KEY, "the key is trimmed");
  assert.ok(!url.includes(FAKE_KEY));
  assert.ok(!init.body.includes(FAKE_KEY));
});

test("a key is trimmed but its prefix is not checked", () => {
  assert.equal(cleanKey("  sk_test-key-not-real  "), "sk_test-key-not-real");
  assert.equal(cleanKey("0123456789abcdef-not-real"), "0123456789abcdef-not-real");
  assert.equal(cleanKey("   "), "");
  assert.equal(cleanKey(undefined), "");
  assert.throws(() => buildRequest("   ", "woman", "Hello.", 1));
});

test("an unknown voice is refused, including names on Object.prototype", () => {
  for (const name of ["", "child", "constructor", "__proto__", "toString", undefined]) {
    assert.throws(() => buildRequest(FAKE_KEY, name, "Hello.", 1), `accepted ${String(name)}`);
  }
  assert.equal(voiceFromURI("eleven:woman"), "woman");
  assert.equal(voiceFromURI(uriFor("man")), "man");
  for (const uri of ["", "Samantha", "eleven:", "eleven:constructor", "eleven:__proto__", "woman", null]) {
    assert.equal(voiceFromURI(uri), null, `took ${String(uri)} for an ElevenLabs voice`);
  }
});

test("an error thrown while building a request never contains the key", () => {
  for (const [voice, text] of [["nobody", "Hello."], ["woman", "   "]]) {
    try {
      buildRequest(FAKE_KEY, voice, text, 1);
      assert.fail("should have thrown");
    } catch (error) {
      assert.ok(!String(error.message).includes(FAKE_KEY));
    }
  }
});

// ---------- speed ----------

test("speed is clamped to what ElevenLabs accepts, so it never answers invalid_voice_settings", () => {
  assert.equal(speedFor(1), 1);
  assert.equal(speedFor(0.6), 0.7, "the reader's slowest");
  assert.equal(speedFor(1.8), 1.2, "the reader's fastest");
  assert.equal(speedFor(0.85), 0.85);
  assert.equal(speedFor(1.15), 1.15);
  assert.equal(speedFor("1.1"), 1.1);
  for (const junk of [undefined, null, NaN, Infinity, "fast", {}]) {
    const speed = speedFor(junk);
    assert.ok(speed >= 0.7 && speed <= 1.2, `${String(junk)} gave ${speed}`);
  }
  for (let rate = 0.6; rate <= 1.8001; rate += 0.05) {
    const sent = JSON.parse(buildRequest(FAKE_KEY, "woman", "Hi.", rate).init.body).voice_settings.speed;
    assert.ok(sent >= 0.7 && sent <= 1.2, `rate ${rate} sent speed ${sent}`);
  }
});

// ---------- errors ----------

test("every ElevenLabs error has its own plain message", () => {
  assert.equal(messageFor(401, "invalid_api_key"), "ElevenLabs didn't accept that key.");
  assert.equal(messageFor(401, "missing_permissions"),
               "That key isn't allowed to make speech. Give it Text to Speech access in ElevenLabs.");
  assert.equal(messageFor(402, "payment_required"), "These voices need a paid ElevenLabs plan.");
  assert.equal(messageFor(404, "voice_not_found"), "That voice isn't available on your ElevenLabs account.");
  assert.equal(messageFor(429, "too_many_concurrent_requests"), "ElevenLabs is out of credits or busy right now.");
  assert.equal(messageFor(429, ""), "ElevenLabs is out of credits or busy right now.");
  assert.equal(messageFor(401, "quota_exceeded"), MESSAGES.busy);
  for (const [status, detail] of [[500, ""], [0, ""], [400, "invalid_voice_settings"], [401, "something_new"], [503, "x"]]) {
    assert.equal(messageFor(status, detail), "Couldn't reach ElevenLabs.", `${status} ${detail}`);
  }
});

test("the error status is read from the body, and a strange body is not a crash", () => {
  const body = JSON.stringify({ detail: { status: "invalid_api_key", message: "Invalid API key" } });
  assert.equal(detailStatusOf(body), "invalid_api_key");
  assert.equal(detailStatusOf("<html>Bad gateway</html>"), "");
  assert.equal(detailStatusOf(""), "");
  assert.equal(detailStatusOf(JSON.stringify({ detail: "Not found" })), "");
  assert.equal(detailStatusOf(JSON.stringify({ detail: [{ msg: "field required" }] })), "");
});

test("the messages are calm sentences with no em dashes", () => {
  for (const message of Object.values(MESSAGES)) {
    assert.ok(!message.includes("—"), message);
    assert.match(message, /\.$/);
  }
  const options = fs.readFileSync(path.join(here, "../src/options.html"), "utf8");
  assert.ok(!options.includes("—") && !options.includes("&mdash;"), "an em dash on the options page");
  assert.equal(UNREACHABLE, MESSAGES.unreachable, "the reader's fallback words drifted from the worker's");
});

// ---------- never pay for nothing ----------

test("empty or whitespace-only text is never sent: it would cost credits for silence", () => {
  for (const text of ["", " ", "\n\t  ", null, undefined, 42]) {
    assert.equal(speakable(text), false, JSON.stringify(text));
    assert.throws(() => buildRequest(FAKE_KEY, "woman", text, 1));
  }
  assert.equal(speakable(" a "), true);
});

test("audio survives the JSON trip as base64, including a buffer bigger than one chunk", () => {
  const bytes = new Uint8Array(100_000).map((_, i) => (i * 7) % 256);
  assert.equal(toBase64(bytes.buffer), Buffer.from(bytes).toString("base64"));
  assert.equal(toBase64(new Uint8Array(0)), "");
});

// ---------- which card is next ----------

test("the card fetched ahead is the next one actually spoken, and never past a checkpoint", () => {
  const chunks = [
    { kind: "prose", text: "One." },
    { kind: "aside", text: "| a | table |" },
    { kind: "figure", text: "" },
    { kind: "prose", text: "Two." },
    { kind: "prose", text: "Three." },
  ];
  assert.equal(nextSpokenIndex(chunks, 0), 3, "asides and figures are passed over");
  assert.equal(nextSpokenIndex(chunks, 4), -1, "nothing after the last card");
  assert.equal(nextSpokenIndex(chunks, 3, (i) => i === 3), -1, "the reader may read the stretch again");
  assert.equal(nextSpokenIndex(chunks, 0, (i) => i === 3), 3);
  assert.equal(isSpoken({ kind: "prose", text: "   " }), false);
  assert.equal(isSpoken({ kind: "heading", text: "Zones" }), true);
});

// ---------- the reader's player, with a fake worker and fake Web Audio ----------

function fakeContext({ state = "running", resumes = true } = {}) {
  const context = {
    state,
    destination: {},
    played: [],
    resume() { if (resumes) context.state = "running"; return Promise.resolve(); },
    close() { return Promise.resolve(); },
    decodeAudioData(buffer) {
      return Promise.resolve({ duration: 0.01, text: new TextDecoder().decode(buffer) });
    },
    createBufferSource() {
      const source = {
        buffer: null, onended: null, stopped: false,
        connect() {}, disconnect() {},
        start() { context.played.push(source.buffer.text); },
        stop() { source.stopped = true; source.onended?.(); },
      };
      return source;
    },
  };
  return context;
}

// A worker whose answers the test releases by hand. The "audio" is the text.
function fakeWorker() {
  const worker = { sent: [], pending: [] };
  worker.send = (message) => {
    worker.sent.push(message);
    return new Promise((resolve, reject) => worker.pending.push({ message, resolve, reject }));
  };
  worker.answer = (i = worker.pending.length - 1) => {
    const { message, resolve } = worker.pending[i];
    resolve({ ok: true, audio: Buffer.from(message.text).toString("base64") });
  };
  worker.fail = (message, i = worker.pending.length - 1) => worker.pending[i].resolve({ ok: false, message });
  // Answers anything left over, so no reply timer outlives its test.
  worker.drain = () => worker.pending.forEach(({ resolve }) => resolve(null));
  return worker;
}

function narrator(worker, context = fakeContext()) {
  const n = new ElevenNarrator({ send: worker.send, createContext: () => context });
  n.unlock();
  return { n, context };
}

test("the reader sends text, voice and speed to the worker, and never a key", async () => {
  const worker = fakeWorker();
  const { n } = narrator(worker);
  n.speak("First card.", { voice: "eleven:woman", rate: 1.4 });
  await wait(300);
  assert.equal(worker.sent.length, 1);
  assert.deepEqual(worker.sent[0], { type: "eleven:speak", text: "First card.", voice: "eleven:woman", speed: 1.4 });
  n.close();
  worker.drain();
});

test("a late answer is dropped when the reader stops or moves on: stale audio never plays", async () => {
  const worker = fakeWorker();
  const { n, context } = narrator(worker);
  let done = 0;
  let errors = 0;
  n.speak("First card.", { voice: "eleven:woman" }, () => { done += 1; }, () => { errors += 1; });
  await wait(300);
  n.stop();
  worker.answer();
  await wait(20);
  assert.deepEqual(context.played, [], "played after the reader stopped");

  n.speak("Second card.", { voice: "eleven:woman" }, () => { done += 1; });
  await wait(300);
  n.speak("Third card.", { voice: "eleven:woman" }, () => { done += 1; });
  worker.answer(1);
  await wait(300);
  worker.answer(2);
  await wait(20);
  assert.deepEqual(context.played, ["Third card."]);
  assert.equal(done, 0);
  assert.equal(errors, 0);
  n.close();
});

test("stopping during playback does not count as the card finishing", async () => {
  const worker = fakeWorker();
  const { n, context } = narrator(worker);
  let done = 0;
  n.speak("A card.", { voice: "eleven:woman" }, () => { done += 1; });
  await wait(300);
  worker.answer();
  await wait(20);
  assert.deepEqual(context.played, ["A card."]);
  n.stop();
  assert.equal(done, 0, "stop() advanced the reader");
  n.close();
});

test("Back and Read it again do not pay twice", async () => {
  const worker = fakeWorker();
  const { n, context } = narrator(worker);
  n.speak("A card.", { voice: "eleven:woman" });
  await wait(300);
  worker.answer();
  await wait(20);
  n.speak("A card.", { voice: "eleven:woman" });
  await wait(20);
  assert.equal(worker.sent.length, 1);
  assert.deepEqual(context.played, ["A card.", "A card."]);
  n.close();
});

test("at most one card is fetched ahead, and that one is not fetched again", async () => {
  const worker = fakeWorker();
  const { n, context } = narrator(worker);
  n.speak("One.", { voice: "eleven:woman", next: "Two." });
  await wait(300);
  worker.answer(0);
  await wait(50);
  assert.deepEqual(worker.sent.map((m) => m.text), ["One.", "Two."]);

  // Asked for while the prefetch is still in flight: waits for it, no new request.
  n.speak("Two.", { voice: "eleven:woman" });
  await wait(20);
  worker.answer(1);
  await wait(20);
  assert.deepEqual(worker.sent.map((m) => m.text), ["One.", "Two."]);
  assert.deepEqual(context.played, ["One.", "Two."]);
  n.close();
});

test("stepping quickly past cards while listening does not pay for each one", async () => {
  const worker = fakeWorker();
  const { n } = narrator(worker);
  for (const text of ["One.", "Two.", "Three.", "Four."]) {
    n.speak(text, { voice: "eleven:woman" });
    await wait(30);
  }
  await wait(300);
  assert.deepEqual(worker.sent.map((m) => m.text), ["Four."]);
  n.close();
  worker.drain();
});

test("a failure is reported with its message and is never asked for again", async () => {
  const worker = fakeWorker();
  const { n, context } = narrator(worker);
  const messages = [];
  n.speak("A card.", { voice: "eleven:woman" }, null, (m) => messages.push(m));
  await wait(300);
  worker.fail(MESSAGES.badKey);
  await wait(20);
  n.speak("A card.", { voice: "eleven:woman" }, null, (m) => messages.push(m));
  await wait(20);
  assert.deepEqual(messages, [MESSAGES.badKey, MESSAGES.badKey]);
  assert.equal(worker.sent.length, 1, "retried a failed card");
  assert.deepEqual(context.played, []);
  n.close();
});

test("a worker that cannot be reached, or audio that will not start, hands the card back", async () => {
  const messages = [];
  const broken = { send: () => Promise.reject(new Error("Could not establish connection")) };
  const a = new ElevenNarrator({ send: broken.send, createContext: () => fakeContext() });
  a.speak("A card.", { voice: "eleven:woman" }, null, (m) => messages.push(m));
  await wait(300);

  const worker = fakeWorker();
  const silent = fakeContext({ state: "suspended", resumes: false });
  const b = new ElevenNarrator({ send: worker.send, createContext: () => silent });
  b.speak("A card.", { voice: "eleven:woman" }, null, (m) => messages.push(m));
  await wait(300);
  worker.answer();
  await wait(20);

  assert.deepEqual(messages, [UNREACHABLE, UNREACHABLE]);
  assert.deepEqual(silent.played, []);
  a.close();
  b.close();
});

test("the reader never asks the worker to read empty text", async () => {
  const worker = fakeWorker();
  const { n } = narrator(worker);
  let done = 0;
  n.speak("   \n", { voice: "eleven:woman", next: "  " }, () => { done += 1; });
  await wait(300);
  assert.equal(worker.sent.length, 0);
  assert.equal(done, 1, "an empty card should move on, not hang");
  n.close();
});

test("the reader learns only whether a key exists, never the key", async () => {
  const status = await elevenStatus(async () => ({ configured: true, voices: voiceChoices(), key: FAKE_KEY }));
  assert.deepEqual(status, { configured: true, voices: voiceChoices() });
  assert.deepEqual(await elevenStatus(() => Promise.reject(new Error("no worker"))), { configured: false, voices: [] });
});

// ---------- the service worker, with a fake chrome and a fake fetch ----------

test("the worker answers only this extension, reads the key itself, and never returns it", async (t) => {
  const listeners = {};
  const store = { [KEY_STORAGE]: `  ${FAKE_KEY} ` };
  const event = (name) => ({ addListener: (fn) => { listeners[name] = fn; } });
  globalThis.chrome = {
    runtime: { id: "engrossed-test-id", onInstalled: event("installed"), onMessage: event("message"), openOptionsPage: async () => {} },
    action: { onClicked: event("clicked") },
    storage: { local: { get: async (key) => ({ [key]: store[key] }) } },
  };
  const realFetch = globalThis.fetch;
  const calls = [];
  let reply = () => new Response(new Uint8Array([1, 2, 3]), { status: 200 });
  globalThis.fetch = async (url, init) => { calls.push({ url, init }); return reply(); };
  t.after(() => { globalThis.fetch = realFetch; delete globalThis.chrome; });

  await import("../src/background.js");
  const ask = (message, sender = { id: "engrossed-test-id" }) => new Promise((resolve) => {
    const async = listeners.message(message, sender, resolve);
    if (!async) resolve(undefined);
  });

  assert.equal(await ask({ type: "eleven:status" }, { id: "someone-else" }), undefined, "answered another extension");
  assert.deepEqual(await ask({ type: "eleven:status" }), { configured: true, voices: voiceChoices() });

  const ok = await ask({ type: "eleven:speak", text: "A card.", voice: "eleven:man", speed: 1.8 });
  assert.deepEqual(ok, { ok: true, audio: Buffer.from([1, 2, 3]).toString("base64") });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].init.headers["xi-api-key"], FAKE_KEY);
  assert.match(calls[0].url, /gOupLcAkjEnguROwi4oS/);
  assert.equal(JSON.parse(calls[0].init.body).voice_settings.speed, 1.2);

  assert.deepEqual(await ask({ type: "eleven:speak", text: "  ", voice: "eleven:man", speed: 1 }),
                   { ok: false, message: MESSAGES.unreachable });
  assert.equal(calls.length, 1, "sent empty text");

  reply = () => new Response(JSON.stringify({ detail: { status: "payment_required", message: "Upgrade" } }), { status: 402 });
  const paid = await ask({ type: "eleven:speak", text: "A card.", voice: "eleven:woman", speed: 1 });
  assert.deepEqual(paid, { ok: false, message: MESSAGES.needsPaidPlan });

  reply = () => { throw new TypeError("Failed to fetch"); };
  assert.deepEqual(await ask({ type: "eleven:speak", text: "A card.", voice: "eleven:woman", speed: 1 }),
                   { ok: false, message: MESSAGES.unreachable });

  for (const answer of [ok, paid]) assert.ok(!JSON.stringify(answer).includes(FAKE_KEY));

  delete store[KEY_STORAGE];
  assert.deepEqual(await ask({ type: "eleven:status" }), { configured: false, voices: voiceChoices() });
  const before = calls.length;
  assert.deepEqual(await ask({ type: "eleven:speak", text: "A card.", voice: "eleven:woman", speed: 1 }),
                   { ok: false, message: "" }, "with no key the built-in voice reads, quietly");
  assert.equal(calls.length, before);
});
