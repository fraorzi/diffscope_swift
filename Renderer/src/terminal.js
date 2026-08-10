import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";

// The output grid (DEC-054). xterm.js draws it; everything about *what* runs stays in Swift.
//
// Two rules this file exists to keep:
//   1. Bytes arrive as bytes. Swift sends base64 of the raw PTY output and never a decoded string,
//      because a UTF-8 sequence routinely splits across two reads.
//   2. Colours come from tokens.css like every other visual value in the product (G2).

const SCROLLBACK = 10000;

const probe = document.createElement("span");
probe.setAttribute("aria-hidden", "true");
probe.style.position = "absolute";
probe.style.visibility = "hidden";
document.body.appendChild(probe);

// Declared and resolved are different questions. `getPropertyValue` says whether tokens.css
// declares the name at all; the probe element resolves `color-mix()` and system colours like
// `Canvas` into something xterm can actually parse.
const declared = (name) =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim();

const resolved = (name) => {
  probe.style.color = `var(${name})`;
  return getComputedStyle(probe).color;
};

const missingTokens = [];
const colour = (name) => {
  if (!declared(name)) missingTokens.push(name);
  return resolved(name);
};

// Written out rather than built from a loop: a token name assembled at runtime is invisible to the
// check that every declared token is actually used, and a palette entry nobody reaches is a value a
// designer would change to no effect.
const ansi = {
  black: colour("--ds-term-black"),
  red: colour("--ds-term-red"),
  green: colour("--ds-term-green"),
  yellow: colour("--ds-term-yellow"),
  blue: colour("--ds-term-blue"),
  magenta: colour("--ds-term-magenta"),
  cyan: colour("--ds-term-cyan"),
  white: colour("--ds-term-white"),
  brightBlack: colour("--ds-term-bright-black"),
  brightRed: colour("--ds-term-bright-red"),
  brightGreen: colour("--ds-term-bright-green"),
  brightYellow: colour("--ds-term-bright-yellow"),
  brightBlue: colour("--ds-term-bright-blue"),
  brightMagenta: colour("--ds-term-bright-magenta"),
  brightCyan: colour("--ds-term-bright-cyan"),
  brightWhite: colour("--ds-term-bright-white"),
};

const post = (message) =>
  window.webkit?.messageHandlers?.diffscopeTerminal?.postMessage(message);

// ---- Tabs (DEC-067) --------------------------------------------------------------------------
//
// **One xterm instance per tab**, not one grid replaying a buffer. Scrollback, cursor position and
// the alternate screen are the emulator's business, and an emulator that is asked to forget them
// and reproduce them later gets the cursor wrong on the first full-screen program. Instances are
// cheap next to the shell each one is attached to.
const tabs = new Map();   // id → { term, fit, element }
let activeTab = null;
const grid = document.getElementById("grid");

function createTab(id) {
  const element = document.createElement("div");
  element.className = "ds-term-grid";
  grid.appendChild(element);

  const term = new Terminal({
    fontFamily: declared("--ds-font") || "monospace",
    fontSize: parseInt(declared("--ds-term-text-size"), 10) || 12,
    scrollback: SCROLLBACK,
    cursorBlink: false,
    convertEol: false,
    theme: {
      background: colour("--ds-term-bg"),
      foreground: colour("--ds-term-fg"),
      cursor: colour("--ds-term-cursor"),
      cursorAccent: colour("--ds-term-bg"),
      selectionBackground: colour("--ds-term-selection"),
      ...ansi,
    },
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.open(element);

  // Every message carries the tab it came from. Without the id the shell that receives a keystroke
  // is whichever one Swift happened to think was active, which is a race with the reader's hand.
  term.onData((data) => post({ name: "input", data, tab: id }));
  term.onBinary((data) => post({ name: "binary", data, tab: id }));
  term.onResize(({ cols, rows }) => post({ name: "resize", cols, rows, tab: id }));

  const entry = { term, fit, element };
  tabs.set(id, entry);
  if (activeTab === null) selectTab(id);
  return entry;
}

/// The active tab, or nothing. It used to create one on demand, and that turned every early
/// `focus()` into a second grid the shell behind it never wrote to — a tab with no session, which
/// is exactly the thing a tab strip must not contain.
function current() {
  return activeTab !== null ? tabs.get(activeTab) : undefined;
}

function selectTab(id) {
  if (!tabs.has(id)) createTab(id);
  activeTab = id;
  for (const [key, entry] of tabs) {
    entry.element.dataset.active = String(key === id);
  }
  refit();
  return id;
}

const refit = () => {
  const entry = tabs.get(activeTab);
  if (!entry) return;
  try {
    entry.fit.fit();
  } catch {
    // A zero-sized pane throws rather than returning a size; nothing to do until it has one.
  }
};
window.addEventListener("resize", refit);
new ResizeObserver(refit).observe(grid);

window.diffscopeTerminalOpenTab = (id) => { createTab(id); return selectTab(id); };
window.diffscopeTerminalSelectTab = (id) => selectTab(id);
window.diffscopeTerminalCloseTab = (id) => {
  const entry = tabs.get(id);
  if (!entry) return false;
  entry.term.dispose();
  entry.element.remove();
  tabs.delete(id);
  if (activeTab === id) {
    activeTab = null;
    const next = tabs.keys().next();
    if (!next.done) selectTab(next.value);
  }
  return true;
};

/// The strip. A tab says which shell it is and **where that shell says it is** — not where the
/// reader has selected, which is the distinction DEC-056 drew for one pane and DEC-067 makes
/// visible per tab. The active tab is marked by weight and an edge, never by colour alone.
window.diffscopeTerminalSetTabs = (payload) => {
  const strip = document.getElementById("tabs");
  strip.replaceChildren();
  for (const tab of payload.tabs || []) {
    const el = document.createElement("span");
    el.className = "ds-term-tab";
    el.dataset.active = String(tab.id === payload.active);
    el.textContent = tab.title + (tab.cwd ? "  " + tab.cwd : "");
    if (tab.diverged) {
      el.dataset.diverged = "true";
      el.title = "this shell is not in the selected repository";
    }
    el.addEventListener("click", () => post({ name: "selectTab", tab: tab.id }));
    strip.appendChild(el);
  }
  return (payload.tabs || []).length;
};

// The DOM renderer paints on requestAnimationFrame, and WebKit stops firing those while the window
// is occluded — the buffer then fills while the screen stays empty. The probe reports whether a
// frame arrived since it last asked.
//
// It re-arms on every probe deliberately: a self-perpetuating rAF chain dies the moment frames are
// suspended and never restarts, so it reads zero forever afterwards and says nothing about now.
let frames = 0;
const armFrameCounter = () => requestAnimationFrame(() => frames++);
armFrameCounter();

// ---- The input line (T2) -------------------------------------------------------------------
//
// This field replaces the shell's line editor while the shell is at a prompt, which is the whole
// feature: a real text control is where Option+←/→ and Cmd+←/→ come from (measured in T0).
//
// Routing is *not* decided here. Swift owns it — see InputRouter — and this file asks. Ordinary
// typing and caret motion never ask anything, which is why the round trip costs nothing.

const row = document.getElementById("input-row");
const field = document.getElementById("line");
const modeChip = document.getElementById("mode");
const cwdChip = document.getElementById("cwd");

let interceptedKeys = [];
let currentMode = "program";

// The list comes from Swift rather than being written twice; two copies of a keyboard map drift.
window.diffscopeTerminalConfigure = (config) => {
  interceptedKeys = config.interceptedKeys ?? [];
};

window.diffscopeTerminalSetMode = (mode, label) => {
  currentMode = mode;
  modeChip.textContent = label;
  const raw = mode !== "local";
  modeChip.dataset.raw = String(raw);
  row.dataset.hidden = String(raw);
  if (raw) {
    current()?.term.focus();
  } else {
    field.focus();
  }
};

window.diffscopeTerminalSetDirectory = (info) => {
  // "unknown" is a real answer: a shell with no integration reports nothing, and showing where it
  // *started* as though it were where it is would be a quiet lie.
  cwdChip.textContent = info.known
    ? (info.diverged ? info.name + " — not the selected repository" : info.name)
    : "directory unknown";
  cwdChip.title = info.path || "";
  cwdChip.dataset.diverged = String(Boolean(info.diverged));
};

window.diffscopeTerminalApply = (outcome) => {
  if (outcome.clear) field.value = "";
  if (typeof outcome.line === "string") {
    field.value = outcome.line;
    field.setSelectionRange(field.value.length, field.value.length);
  }
};

const keyName = (event) => {
  if (event.ctrlKey && event.key.length === 1) return "ctrl-" + event.key.toLowerCase();
  return event.key;
};

field.addEventListener("keydown", (event) => {
  const name = keyName(event);
  if (!interceptedKeys.includes(name)) return;
  event.preventDefault();
  post({
    name: "key",
    key: event.key,
    control: event.ctrlKey,
    alt: event.altKey,
    meta: event.metaKey,
    shift: event.shiftKey,
    line: field.value,
  });
});

// Escape releases a forced raw mode, and in that mode the grid holds focus — so the release has to
// be reachable from the document rather than from a field nobody is typing in.
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape" || currentMode !== "forcedRaw") return;
  event.preventDefault();
  post({ name: "releaseForcedRaw" });
});

modeChip.addEventListener("click", () => post({ name: "toggleForcedRaw" }));

window.diffscopeTerminalWrite = (base64, id) => {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  // Output goes to the tab it came from, whether or not that tab is the one on screen: a test
  // suite running in the background is still running. Output addressed to a tab the page has not
  // been told about **creates** it rather than falling back to the active one — bytes buffered
  // while the page was loading arrive before the tab that opened does, and answering them with
  // "the current tab" invented a second grid and wrote the first shell's output into it.
  const entry = id != null ? (tabs.get(id) || createTab(id)) : current();
  if (!entry) return;
  entry.term.write(bytes);
};

window.diffscopeTerminalFocus = () => current()?.term.focus();

// A new session starts on a clean grid. Without this the scrollback mixes two shells' output with
// nothing to say where one ended — and the reader has no way to tell which shell said what.
window.diffscopeTerminalReset = () => {
  current()?.term.reset();
  field.value = "";
};

function bufferText(buffer, limit) {
  const lines = [];
  for (let i = 0; i < Math.min(buffer.length, limit); i++) {
    const line = buffer.getLine(i);
    if (line) lines.push(line.translateToString(true));
  }
  return lines.join("\n");
}

window.diffscopeTerminalProbe = () => {
  const seen = frames;
  frames = 0;
  armFrameCounter();
  return probeBody(seen);
};

const probeBody = (framesSinceLastProbe) => ({
  cols: current()?.term.cols ?? 0,
  rows: current()?.term.rows ?? 0,
  scrollback: current()?.term.options.scrollback ?? 0,
  alternateScreen: current()?.term.buffer.active.type === "alternate",
  // A pane that is drawn at zero size reports a size and no defect anywhere else — M8-D's lesson,
  // where two lists rendered completely blank and nothing failed.
  pixelWidth: document.getElementById("grid").clientWidth,
  pixelHeight: document.getElementById("grid").clientHeight,
  missingTokens,
  tabs: tabs.size,
  activeTab,
  background: current()?.term.options.theme.background ?? "",
  foreground: current()?.term.options.theme.foreground ?? "",
  text: current() ? bufferText(current().term.buffer.active, current().term.rows) : "",
  // What the buffer holds and what the screen shows are different questions, and only the second
  // one is what the reader gets. M8-D was a surface that drew nothing while every check passed.
  // The **active** tab's rows, not the first in the DOM. With one grid per tab the first one is
  // whichever tab opened first, and a hidden element reports no text at all — so this read the
  // wrong grid and then reported it as blank.
  renderedText: (tabs.get(activeTab)?.element.querySelector(".xterm-rows")?.innerText ?? "").trim(),
  canvases: document.querySelectorAll("#grid canvas").length,
  visibility: document.visibilityState,
  framesSinceLastProbe,
  mode: currentMode,
  modeLabel: modeChip.textContent,
  inputVisible: row.dataset.hidden !== "true",
  inputFocused: document.activeElement === field,
  line: field.value,
  interceptedKeys,
  cwd: cwdChip.textContent,
  cwdDiverged: cwdChip.dataset.diverged === "true",
});
