// A reading sprint: a bounded stretch of time with a visible end.
//
// A port of Sprint.swift. The bound is the point. An open-ended "read this"
// has no edge to aim at; twenty minutes does, and it also forces the break
// that stops a session from quietly decaying into staring at the same card.
//
// One difference from the app: on the web people hop between short articles,
// so a sprint carries over to the next article if you open it within ten
// minutes. Without that, a sprint would restart on every page and the break
// would never come.

const KEY = "sprint";
const CARRY_OVER_MS = 10 * 60 * 1000;

export class Sprint {
  constructor(targetMinutes = 20) {
    this.targetMinutes = targetMinutes;
    this.elapsed = 0;
    this.running = false;
    this.finished = false;
    this.chunks = 0;
    this.words = 0;
    this.lastTick = null;
    this.timer = null;
    this.onTick = null;
    this.onFinish = null;
  }

  get remaining() {
    return Math.max(0, this.targetMinutes * 60 - this.elapsed);
  }

  get remainingText() {
    const total = Math.ceil(this.remaining);
    return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
  }

  start() {
    if (this.running || this.finished) return;
    this.running = true;
    this.lastTick = now();
    this.timer = setInterval(() => this.tick(), 1000);
  }

  pause() {
    // Bank the time since the last tick first. The app had this bug: clearing
    // the running flag before ticking threw away every partial second.
    this.tick();
    this.halt();
  }

  restart() {
    this.halt();
    this.elapsed = 0;
    this.finished = false;
    this.chunks = 0;
    this.words = 0;
    this.start();
  }

  record(words) {
    this.chunks += 1;
    this.words += words || 0;
  }

  // Elapsed time is measured from the clock, not by counting ticks, because
  // Chrome throttles timers in background tabs to once a minute.
  tick() {
    if (!this.running || this.lastTick === null) return;
    const t = now();
    this.elapsed += (t - this.lastTick) / 1000;
    this.lastTick = t;
    if (!this.finished && this.remaining <= 0) {
      this.finished = true;
      this.halt();
      this.onTick?.();
      this.onFinish?.();
      return;
    }
    this.onTick?.();
  }

  halt() {
    this.running = false;
    clearInterval(this.timer);
    this.timer = null;
    this.lastTick = null;
  }

  snapshot() {
    return {
      elapsed: this.elapsed, chunks: this.chunks, words: this.words,
      finished: this.finished, targetMinutes: this.targetMinutes, updatedAt: Date.now(),
    };
  }

  static restore(saved, targetMinutes, at = Date.now()) {
    const sprint = new Sprint(targetMinutes);
    const fresh = saved && !saved.finished && at - (saved.updatedAt || 0) < CARRY_OVER_MS;
    if (fresh) {
      sprint.elapsed = Math.max(0, Number(saved.elapsed) || 0);
      sprint.chunks = saved.chunks | 0;
      sprint.words = saved.words | 0;
    }
    return sprint;
  }
}

function now() {
  return typeof performance !== "undefined" ? performance.now() : Date.now();
}

export async function loadSprint(targetMinutes) {
  try {
    const got = await chrome.storage.local.get(KEY);
    return Sprint.restore(got?.[KEY], targetMinutes);
  } catch {
    return new Sprint(targetMinutes);
  }
}

export async function saveSprint(sprint) {
  try {
    await chrome.storage.local.set({ [KEY]: sprint.snapshot() });
  } catch { /* not worth interrupting anyone over */ }
}
