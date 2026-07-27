import { EditorView, Decoration, WidgetType } from "@codemirror/view";
import { EditorState, RangeSetBuilder, StateField, StateEffect } from "@codemirror/state";
import { javascript } from "@codemirror/lang-javascript";
import { syntaxHighlighting, defaultHighlightStyle } from "@codemirror/language";

const LABEL_CLASS = {
  changed: "ds-changed",
  moved: "ds-moved",
  fallback: "ds-fallback",
};

// A group is a presentation grouping, never a filter: the segment keeps its label and its
// bytes stay on screen. Structural mode quietens formatting-only marks; Expanded drops the
// quietening. Both modes render the same segment set (INV-5).
const GROUP_CLASS = {
  "formatting-only": "ds-formatting",
  "potentially-behavior-affecting": "ds-behaviour",
};

let currentMode = "raw";

class NoticeWidget extends WidgetType {
  constructor(text) { super(); this.text = text; }
  toDOM() {
    const el = document.createElement("div");
    el.className = "ds-notice";
    el.textContent = this.text;
    return el;
  }
}

// DEC-023: a change that renders identically on both sides reads as a tool defect unless the
// tool says why nothing is visible. The badge carries the reason as text, not colour (DEC-035),
// and Expanded names the codepoints outright.
const INVISIBLE_SCALARS = new Set([
  0x00ad, 0x200b, 0x200c, 0x200d, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
  0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0xfeff, 0x00a0, 0x1680, 0x2000, 0x2001, 0x2002,
  0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a, 0x202f, 0x205f, 0x3000,
  0x0009,
]);

function revealedCodepoints(text) {
  const out = [];
  for (const char of text) {
    const code = char.codePointAt(0);
    const combining = /\p{Mn}|\p{Mc}/u.test(char);
    if (INVISIBLE_SCALARS.has(code) || combining) {
      out.push("U+" + code.toString(16).toUpperCase().padStart(4, "0"));
    }
  }
  return out;
}

class DisclosureWidget extends WidgetType {
  constructor(text) { super(); this.text = text; }
  eq(other) { return other.text === this.text; }
  toDOM() {
    const el = document.createElement("span");
    el.className = "ds-badge";
    el.textContent = this.text;
    return el;
  }
}

function decorationsFor(state, segments) {
  const items = [];
  const disclosureRuns = [];
  const max = state.doc.length;
  for (const seg of segments) {
    const cls = LABEL_CLASS[seg.label];
    if (!cls) continue;
    const from = Math.max(0, Math.min(seg.start, max));
    const to = Math.max(from, Math.min(seg.end, max));
    if (to <= from) continue;
    const classes = [cls];
    if (currentMode !== "expanded" && GROUP_CLASS[seg.group]) classes.push(GROUP_CLASS[seg.group]);
    if (seg.uncertain) classes.push("ds-uncertain");
    if (seg.disclosure) classes.push("ds-invisible");
    const attributes = {};
    if (seg.classification) attributes["data-classification"] = seg.classification;
    if (seg.disclosure) attributes["data-disclosure"] = seg.disclosure;
    if (seg.confidence != null) attributes["data-confidence"] = String(seg.confidence);
    items.push({
      from,
      to,
      deco: Decoration.mark({
        class: classes.join(" "),
        attributes: Object.keys(attributes).length ? attributes : undefined,
      }),
    });
    if (seg.disclosure) {
      const last = disclosureRuns[disclosureRuns.length - 1];
      if (last && last.to === from && last.reason === seg.disclosure) last.to = to;
      else disclosureRuns.push({ from, to, reason: seg.disclosure });
    }
  }

  // One badge per visible change, not per segment — reconciliation and snapping split a single
  // invisible edit into several, and repeating the reason on each reads as several problems.
  for (const run of disclosureRuns) {
    const codepoints = currentMode === "expanded"
      ? revealedCodepoints(state.doc.sliceString(run.from, run.to))
      : [];
    const label = codepoints.length ? run.reason + " " + codepoints.join(" ") : run.reason;
    items.push({
      from: run.to,
      to: run.to,
      deco: Decoration.widget({ widget: new DisclosureWidget(label), side: 1 }),
    });
  }
  items.sort((a, b) => a.from - b.from || a.to - b.to);
  const builder = new RangeSetBuilder();
  for (const item of items) builder.add(item.from, item.to, item.deco);
  return builder.finish();
}

function makePane(parent, side) {
  const field = StateField.define({
    create: () => Decoration.none,
    update: (value, tr) => {
      for (const effect of tr.effects) if (effect.is(setSegments)) {
        return decorationsFor(tr.state, effect.value);
      }
      return value.map(tr.changes);
    },
    provide: f => EditorView.decorations.from(f),
  });
  const view = new EditorView({
    parent,
    state: EditorState.create({
      doc: "",
      extensions: [
        javascript({ typescript: true, jsx: true }),
        syntaxHighlighting(defaultHighlightStyle),
        EditorView.editable.of(false),
        EditorView.lineWrapping,
        field,
      ],
    }),
  });
  view.__segmentField = field;
  view.__side = side;
  return view;
}

const setSegments = StateEffect.define();

const left = makePane(document.getElementById("left"), "old");
const right = makePane(document.getElementById("right"), "new");

let syncing = false;
function link(a, b) {
  a.scrollDOM.addEventListener("scroll", () => {
    if (syncing) return;
    syncing = true;
    b.scrollDOM.scrollTop = a.scrollDOM.scrollTop;
    syncing = false;
  });
}
link(left, right);
link(right, left);

let currentPin = null;
let lastSummary = null;

function applySide(view, side) {
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: side.text },
  });
  view.dispatch({ effects: setSegments.of(side.segments) });
}

function groupCounts(model) {
  const counts = new Map();
  const moves = new Set();
  if (model.payload.kind !== "text") return counts;
  for (const side of [model.payload.old, model.payload.new]) {
    for (const seg of side.segments) {
      if (seg.group) counts.set(seg.group, (counts.get(seg.group) || 0) + 1);
      if (seg.disclosure) {
        const key = "invisible: " + seg.disclosure;
        counts.set(key, (counts.get(key) || 0) + 1);
      }
      if (seg.uncertain) counts.set("uncertain", (counts.get("uncertain") || 0) + 1);
      if (seg.label === "moved" && seg.link != null) moves.add(seg.link);
    }
  }
  // Both sides carry the same move, so the pairing — not the segment count — is the number
  // worth showing (DEC-038: a move regroups what is presented, it never adds to it).
  if (moves.size) counts.set("moved", moves.size);
  return counts;
}

function renderNotices(model) {
  const bar = document.getElementById("notices");
  bar.innerHTML = "";
  const items = [...model.notices];
  if (!model.coverageVerified) items.push("coverage not verified");
  // Disclosed counts (DEC-017): grouping is only permissible while it says how much it grouped.
  for (const [group, count] of [...groupCounts(model)].sort()) {
    items.push(`${group}: ${count} shown`);
  }
  items.push(`mode: ${model.mode}`);
  for (const text of items) {
    const chip = document.createElement("span");
    chip.className = "ds-chip" + (text.startsWith("invariant") ? " ds-chip-alert" : "");
    chip.textContent = text;
    bar.appendChild(chip);
  }
}

window.diffscopeRender = function (json) {
  const model = typeof json === "string" ? JSON.parse(json) : json;
  currentPin = model.pinOld + ":" + model.pinNew;
  currentMode = model.mode;
  renderNotices(model);

  const stage = document.getElementById("stage");
  const unrenderable = document.getElementById("unrenderable");
  if (model.payload.kind !== "text") {
    stage.style.display = "none";
    unrenderable.style.display = "block";
    unrenderable.textContent = model.payload.reason || "content cannot be displayed as text";
    lastSummary = { ok: true, pin: currentPin, rendered: "unrenderable", mode: currentMode };
    return lastSummary;
  }
  stage.style.display = "flex";
  unrenderable.style.display = "none";

  applySide(left, model.payload.old);
  applySide(right, model.payload.new);

  lastSummary = {
    ok: true,
    pin: currentPin,
    oldLength: left.state.doc.length,
    newLength: right.state.doc.length,
    oldSegments: model.payload.old.segments.length,
    newSegments: model.payload.new.segments.length,
    groups: Object.fromEntries(groupCounts(model)),
    mode: currentMode,
  };
  return lastSummary;
};

window.diffscopeProbe = function () {
  return {
    pin: currentPin,
    mode: currentMode,
    oldDocLength: left.state.doc.length,
    newDocLength: right.state.doc.length,
    oldText: left.state.doc.toString(),
    newText: right.state.doc.toString(),
    summary: lastSummary,
    formattingMarks: document.querySelectorAll(".ds-formatting").length,
    badges: [...document.querySelectorAll(".ds-badge")].map(el => el.textContent),
    uncertainMarks: document.querySelectorAll(".ds-uncertain").length,
  };
};

window.diffscopeReady = true;
