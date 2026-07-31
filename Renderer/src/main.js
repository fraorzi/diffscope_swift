import { EditorView, Decoration, WidgetType, lineNumbers, gutterLineClass, GutterMarker } from "@codemirror/view";
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

// Folding is the only presentation act that puts content out of sight, so the marker states
// exactly how much and stays one keystroke from opening (DEC-017: disclosed count, immediate
// expansion). What it hides is byte-equal on both sides — the engine proves that before it
// offers the fold at all.
class FoldWidget extends WidgetType {
  constructor(lines, index, label, extraClass) {
    super();
    this.lines = lines;
    this.index = index;
    this.label = label;
    this.extraClass = extraClass || "";
  }
  eq(other) {
    return other.lines === this.lines && other.index === this.index && other.label === this.label;
  }
  toDOM() {
    const el = document.createElement("span");
    el.className = "ds-fold" + (this.extraClass ? " " + this.extraClass : "");
    el.textContent = `${this.label} — \u2318E, or click, to expand`;
    el.setAttribute("role", "button");
    el.addEventListener("mousedown", event => {
      event.preventDefault();
      expandFold(this.index);
    });
    return el;
  }
  ignoreEvent() { return false; }
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

// Unchanged folds and formatting-only groups share one list, because they share one expansion
// path: ⌘E and a click open either, and a reader should not have to learn two ways to see hidden
// text. They differ only in what the marker says and in DEC-048's pairing condition, which the
// engine has already applied by the time a group arrives here.
let folds = [];        // { oldStart, oldEnd, newStart, newEnd, lines, label, kind }
let expanded = new Set();
let stops = [];
let stopIndex = -1;
let anchors = [];

function foldsFor(state, side) {
  const items = [];
  const max = state.doc.length;
  folds.forEach((fold, index) => {
    if (expanded.has(index)) return;
    const from = Math.max(0, Math.min(side === "old" ? fold.oldStart : fold.newStart, max));
    const to = Math.max(from, Math.min(side === "old" ? fold.oldEnd : fold.newEnd, max));
    if (to <= from) return;
    const widget = new FoldWidget(fold.lines, index, fold.label,
                                  fold.kind === "formatting" ? "ds-fold-formatting" : "");
    items.push({ from, to, deco: Decoration.replace({ widget, block: true }) });
  });
  return items;
}

function decorationsFor(state, segments, side) {
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
  items.push(...foldsFor(state, side));
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
        return decorationsFor(tr.state, effect.value, side);
      }
      return value.map(tr.changes);
    },
    provide: f => EditorView.decorations.from(f),
  });
  const changedLineField = StateField.define({
    create: () => [],
    update: (value, tr) => {
      for (const effect of tr.effects) if (effect.is(setChangedLines)) return effect.value;
      return value;
    },
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
        lineNumbers(),
        changedLineField,
        gutterLineClass.compute([changedLineField], state => {
          const lines = state.field(changedLineField);
          const builder = new RangeSetBuilder();
          for (const number of lines) {
            if (number < 1 || number > state.doc.lines) continue;
            builder.add(state.doc.line(number).from, state.doc.line(number).from, changedLineMarker);
          }
          return builder.finish();
        }),
        field,
      ],
    }),
  });
  view.__changedLineField = changedLineField;
  view.__segmentField = field;
  view.__side = side;
  return view;
}

const setSegments = StateEffect.define();

// `12-…` §5.1 names the gutter as one of three carriers of change meaning, beside the underline and
// the background texture. The two others were built; this is the third.
//
// Which lines carry a difference is decided by the engine and arrives on the contract
// (`changedLines`), for the same reason navigation stops and folds do: a fact about the model
// belongs to the model, and one the renderer worked out for itself cannot be checked headlessly.
const setChangedLines = StateEffect.define();
const changedLineMarker = new (class extends GutterMarker {
  elementClass = "ds-gutter-changed";
})();


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
  view.__segments = side.segments;
  view.__changedLines = side.changedLines || [];
  view.dispatch({ effects: [setSegments.of(side.segments),
                            setChangedLines.of(side.changedLines || [])] });
}

function refreshDecorations() {
  for (const view of [left, right]) {
    view.dispatch({ effects: setSegments.of(view.__segments || []) });
  }
}

function expandFold(index) {
  expanded.add(index);
  refreshDecorations();
}

// Both panes scroll to the same stop, because a stop is stated on both sides (DEC-034 uses the
// same idea for refresh: an anchor that exists on one side only cannot align two panes).
function goToStop(delta) {
  if (!stops.length) return null;
  stopIndex = stopIndex < 0
    ? (delta > 0 ? 0 : stops.length - 1)
    : (stopIndex + delta + stops.length) % stops.length;
  const stop = stops[stopIndex];
  for (const [view, from] of [[left, stop.oldStart], [right, stop.newStart]]) {
    const position = Math.max(0, Math.min(from, view.state.doc.length));
    // A fold covering the target would swallow the jump.
    folds.forEach((fold, index) => {
      const start = view === left ? fold.oldStart : fold.newStart;
      const end = view === left ? fold.oldEnd : fold.newEnd;
      if (position >= start && position < end) expanded.add(index);
    });
    view.dispatch({
      effects: EditorView.scrollIntoView(position, { y: "center" }),
      selection: { anchor: position },
    });
  }
  refreshDecorations();
  return { index: stopIndex, total: stops.length };
}

// DEC-034: the anchor the reader is currently looking at — the last one at or above the top of
// the viewport. The engine decides where that anchor goes after a refresh; this only reports it,
// because a renderer that also chose the destination could drift without anything checking.
window.diffscopeAnchorState = function () {
  if (!anchors.length) return null;
  const top = left.scrollDOM.scrollTop;
  let current = anchors[0];
  for (const anchor of anchors) {
    const position = Math.max(0, Math.min(anchor.oldStart, left.state.doc.length));
    if (left.coordsAtPos(position) == null) continue;
    const offset = left.lineBlockAt(position).top;
    if (offset <= top) current = anchor; else break;
  }
  return current;
};

// DEC-015: "open this line" needs a line, and the application used to hand the editor a literal 1
// because nothing on this side could say what the reader was looking at.
//
// The active change stop wins when there is one — a reader who pressed ⌘N is looking at that change,
// not at the top of the screen. Otherwise it is the first line visible in the new pane. Reported in
// the **new** side's numbering, because that is the file on disk the editor will open.
window.diffscopeCurrentLine = function () {
  const doc = right.state.doc;
  if (stopIndex >= 0 && stopIndex < stops.length) {
    const position = Math.max(0, Math.min(stops[stopIndex].newStart, doc.length));
    return doc.lineAt(position).number;
  }
  const top = right.scrollDOM.scrollTop;
  const block = right.lineBlockAtHeight(top);
  return doc.lineAt(Math.max(0, Math.min(block.from, doc.length))).number;
};

// Instant, never animated: DEC-016's reduced-motion commitment is met by construction here
// rather than by a media query someone has to remember to write.
function restoreAnchor(restore) {
  if (!restore || restore.resolution === "noPreviousAnchor") return;
  for (const [view, position] of [[left, restore.oldStart], [right, restore.newStart]]) {
    const target = Math.max(0, Math.min(position, view.state.doc.length));
    view.dispatch({ effects: EditorView.scrollIntoView(target, { y: "start" }) });
  }
}

window.diffscopeCommand = function (name) {
  switch (name) {
    case "nextChange": return goToStop(1);
    case "previousChange": return goToStop(-1);
    case "expandAll":
      folds.forEach((_, index) => expanded.add(index));
      refreshDecorations();
      return { expanded: folds.length };
    default: return null;
  }
};

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

  folds = (model.collapses || []).map(fold => ({
    ...fold, kind: "unchanged", label: `${fold.lines} unchanged lines`,
  })).concat((model.formattingCollapses || []).map(group => ({
    ...group,
    kind: "formatting",
    // DEC-017: a group is only permissible while it says how much it grouped.
    label: `${group.changes} formatting-only changes over ${group.lines} lines`,
  })));
  stops = model.stops || [];
  anchors = model.anchors || [];
  expanded = new Set();
  stopIndex = -1;
  applySide(left, model.payload.old);
  applySide(right, model.payload.new);
  restoreAnchor(model.restore);

  lastSummary = {
    ok: true,
    pin: currentPin,
    oldLength: left.state.doc.length,
    newLength: right.state.doc.length,
    oldSegments: model.payload.old.segments.length,
    newSegments: model.payload.new.segments.length,
    groups: Object.fromEntries(groupCounts(model)),
    mode: currentMode,
    stops: stops.length,
    folds: folds.length,
    formattingGroups: folds.filter(fold => fold.kind === "formatting").length,
    anchors: anchors.length,
    restored: model.restore ? model.restore.resolution : null,
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
    foldMarks: document.querySelectorAll(".ds-fold").length,
    formattingFoldMarks: document.querySelectorAll(".ds-fold-formatting").length,
    foldLabels: [...document.querySelectorAll(".ds-fold")].map(el => el.textContent),
    scrollTop: Math.round(left.scrollDOM.scrollTop),
    stopIndex,
    badges: [...document.querySelectorAll(".ds-badge")].map(el => el.textContent),
    // Asked from the document rather than from the model: INV-4 is a promise about what the reader
    // can see, and a notice that never reached the DOM is not visible however well it was computed.
    notices: [...document.querySelectorAll("#notices .ds-chip")].map(el => el.textContent),
    lineNumbers: document.querySelectorAll(".cm-lineNumbers .cm-gutterElement").length,
    gutterChanged: document.querySelectorAll(".ds-gutter-changed").length,
    uncertainMarks: document.querySelectorAll(".ds-uncertain").length,
  };
};

window.diffscopeReady = true;
