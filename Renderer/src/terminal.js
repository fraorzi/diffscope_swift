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

const term = new Terminal({
  fontFamily: declared("--ds-font") || "monospace",
  fontSize: parseInt(declared("--ds-term-text-size"), 10) || 12,
  scrollback: SCROLLBACK,
  cursorBlink: false,
  convertEol: false,
  theme: {
    background: colour("--ds-term-surface"),
    foreground: colour("--ds-term-ink"),
    cursor: colour("--ds-term-cursor"),
    cursorAccent: colour("--ds-term-surface"),
    selectionBackground: colour("--ds-term-selection"),
    ...ansi,
  },
});

const fit = new FitAddon();
term.loadAddon(fit);
term.open(document.getElementById("grid"));
fit.fit();

const post = (message) =>
  window.webkit?.messageHandlers?.diffscopeTerminal?.postMessage(message);

// The one path a keystroke takes. DEC-028 rests on it: what runs is what the user typed, never
// anything derived from repository content.
term.onData((data) => post({ name: "input", data }));
term.onBinary((data) => post({ name: "binary", data }));
term.onResize(({ cols, rows }) => post({ name: "resize", cols, rows }));

const refit = () => {
  try {
    fit.fit();
  } catch {
    // A zero-sized pane throws rather than returning a size; nothing to do until it has one.
  }
};
window.addEventListener("resize", refit);
new ResizeObserver(refit).observe(document.getElementById("grid"));

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
    term.focus();
  } else {
    field.focus();
  }
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

window.diffscopeTerminalWrite = (base64) => {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  term.write(bytes);
};

window.diffscopeTerminalFocus = () => term.focus();

// A new session starts on a clean grid. Without this the scrollback mixes two shells' output with
// nothing to say where one ended — and the reader has no way to tell which shell said what.
window.diffscopeTerminalReset = () => {
  term.reset();
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
  cols: term.cols,
  rows: term.rows,
  scrollback: term.options.scrollback,
  alternateScreen: term.buffer.active.type === "alternate",
  // A pane that is drawn at zero size reports a size and no defect anywhere else — M8-D's lesson,
  // where two lists rendered completely blank and nothing failed.
  pixelWidth: document.getElementById("grid").clientWidth,
  pixelHeight: document.getElementById("grid").clientHeight,
  missingTokens,
  background: term.options.theme.background,
  foreground: term.options.theme.foreground,
  text: bufferText(term.buffer.active, term.rows),
  // What the buffer holds and what the screen shows are different questions, and only the second
  // one is what the reader gets. M8-D was a surface that drew nothing while every check passed.
  renderedText: (document.querySelector(".xterm-rows")?.innerText ?? "").trim(),
  canvases: document.querySelectorAll("#grid canvas").length,
  visibility: document.visibilityState,
  framesSinceLastProbe,
  mode: currentMode,
  modeLabel: modeChip.textContent,
  inputVisible: row.dataset.hidden !== "true",
  inputFocused: document.activeElement === field,
  line: field.value,
  interceptedKeys,
});
