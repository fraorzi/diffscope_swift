import { EditorView, Decoration, WidgetType, lineNumbers, gutter, gutterLineClass, GutterMarker } from "@codemirror/view";
import { EditorState, RangeSetBuilder, StateField, StateEffect, Compartment } from "@codemirror/state";
import { javascript } from "@codemirror/lang-javascript";
import { syntaxHighlighting, HighlightStyle } from "@codemirror/language";
import { tags } from "@lezer/highlight";

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

function markItems(state, segments) {
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
  return items;
}

function decorationsFor(state, segments, side) {
  const items = markItems(state, segments).concat(foldsFor(state, side));
  return Decoration.set(items.map(item => item.deco.range(item.from, item.to)), true);
}

/// The unified document's decorations: the same marks over projected offsets, plus one line
/// decoration per removed or added line. `Decoration.set` sorts, which matters here because a
/// line decoration and a mark can start at the same offset and a builder would refuse them.
function decorationsForUnified(state, segments) {
  const items = markItems(state, segments).concat(directionDecorations(state));
  return Decoration.set(items.map(item => item.deco.range(item.from, item.to ?? item.from)), true);
}

// Syntax colours by class, never by value (DEC-066). CodeMirror's own `defaultHighlightStyle`
// carries literal colours inside the bundle, which is exactly the boundary `tokens.css` exists
// to hold: a design could not restyle a keyword without editing JavaScript. These classes are
// declared in `index.html` and read their colours from the token file.
const highlighting = HighlightStyle.define([
  { tag: [tags.keyword, tags.modifier, tags.controlKeyword, tags.moduleKeyword], class: "tok-keyword" },
  { tag: [tags.typeName, tags.className, tags.namespace, tags.tagName], class: "tok-type" },
  { tag: [tags.string, tags.special(tags.string)], class: "tok-string" },
  { tag: [tags.number, tags.bool, tags.null], class: "tok-number" },
  { tag: [tags.function(tags.variableName), tags.function(tags.propertyName)], class: "tok-function" },
  { tag: [tags.comment, tags.lineComment, tags.blockComment, tags.docComment], class: "tok-comment" },
  { tag: [tags.punctuation, tags.bracket, tags.angleBracket, tags.separator], class: "tok-punctuation" },
  { tag: [tags.variableName, tags.attributeName], class: "tok-variable" },
  { tag: [tags.propertyName, tags.definition(tags.propertyName)], class: "tok-property" },
  { tag: [tags.operator, tags.derefOperator, tags.arithmeticOperator, tags.logicOperator], class: "tok-operator" },
  { tag: [tags.regexp, tags.escape], class: "tok-regex" },
  { tag: tags.invalid, class: "tok-invalid" },
]);

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
        syntaxHighlighting(highlighting),
        EditorView.editable.of(false),
        wrapping.of(EditorView.lineWrapping),
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

// `12-…` §5.4: wrapping is *available*, not compulsory. Forced wrapping pushes the two panes out of
// vertical alignment on exactly the minified files that section was written about, because a line
// that wraps to three rows on one side and one on the other stops the panes lining up.
const wrapping = new Compartment();
// The unified pane has its own, because it is a separate view and a compartment belongs to one.
const unifiedWrapping = new Compartment();

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
let unified = null;   // built on first use — see `applyLayout`
let layout = "split"; // the renderer's default; the shell asks for unified at launch (DEC-059)

// ---- The unified layout (DEC-059) -----------------------------------------------------------
//
// One column, composed here from the two sides the engine produced — the model is unchanged and
// so is every offset in it; what changes is which document those offsets are projected into.
//
// Side-by-side separates *removed* from *added* by which pane a line is in, and that separation
// is free and survives greyscale. Unified has no panes, so the direction has to be carried by
// something: a sign column, `+` and `−`, drawn as a gutter beside the two number columns. Hue
// only reinforces it (DEC-035).
let unifiedLines = [];
let unifiedRuns = { old: [], new: [] };
/// One entry per merged change block: where it starts in the composed document, and the line
/// ranges it covers on each side. A hunk header is the answer to *where am I* in a file that has
/// been folded and interleaved — the two number columns say it per line, and this says it once.
let unifiedHunks = [];

function lineStartAt(text, index) { return text.lastIndexOf("\n", index - 1) + 1; }
function lineEndAt(text, index) {
  const at = text.indexOf("\n", index);
  return at === -1 ? text.length : at + 1;
}

/// Change stops snapped out to whole lines and merged where they touch. A unified diff is a
/// line-based form and a stop is not: a stop can start mid-line, and emitting half a line as a
/// removal would print text the file does not contain.
function unifiedBlocks(model, oldText, newText) {
  const stops = (model.stops || []).slice()
    .sort((a, b) => a.oldStart - b.oldStart || a.newStart - b.newStart);
  // An empty range on one side is an insertion seen from that side. At a line boundary it takes
  // nothing from this side and the line count simply grows; **inside** a line it changes that
  // line, and the line has to appear as removed even though no byte of it was deleted. Getting
  // this wrong is invisible in the model and obvious on screen: `7` → `77` showed an added line
  // with nothing to compare it against.
  function snap(text, start, end) {
    if (end > start) return { start: lineStartAt(text, start), end: lineEndAt(text, end - 1) };
    const at = lineStartAt(text, start);
    return at === start ? { start, end: start } : { start: at, end: lineEndAt(text, start) };
  }
  const blocks = [];
  for (const stop of stops) {
    const oldRange = snap(oldText, stop.oldStart, stop.oldEnd);
    const newRange = snap(newText, stop.newStart, stop.newEnd);
    const block = {
      oldStart: oldRange.start, oldEnd: oldRange.end,
      newStart: newRange.start, newEnd: newRange.end,
    };
    const last = blocks[blocks.length - 1];
    if (last && block.oldStart <= last.oldEnd && block.newStart <= last.newEnd) {
      last.oldEnd = Math.max(last.oldEnd, block.oldEnd);
      last.newEnd = Math.max(last.newEnd, block.newEnd);
    } else {
      blocks.push(block);
    }
  }
  return blocks;
}

function buildUnified(model) {
  const oldText = model.payload.old.text;
  const newText = model.payload.new.text;
  const runs = { old: [], new: [] };
  const meta = [];
  let doc = "";
  let oldNumber = 1;
  let newNumber = 1;

  function emit(side, from, to, sign) {
    if (to <= from) return;
    const text = side === "old" ? oldText : newText;
    runs[side].push({ srcStart: from, srcEnd: to, docStart: doc.length });
    const chunk = text.slice(from, to);
    doc += chunk;
    // The last line of a file with no trailing newline still counts as a line.
    const count = chunk.split("\n").length - (chunk.endsWith("\n") ? 1 : 0);
    for (let index = 0; index < count; index += 1) {
      meta.push({
        sign,
        old: sign === "+" ? null : oldNumber,
        new: sign === "−" ? null : newNumber,
      });
      if (sign !== "+") oldNumber += 1;
      if (sign !== "−") newNumber += 1;
    }
  }

  const hunks = [];
  let oldCursor = 0;
  let newCursor = 0;
  for (const block of unifiedBlocks(model, oldText, newText)) {
    // Context is emitted from the old side only: between two stops the two sides are byte-equal,
    // which is what makes one column able to stand for both.
    emit("old", oldCursor, block.oldStart, " ");
    const at = doc.length;
    const oldFirst = oldNumber;
    const newFirst = newNumber;
    emit("old", block.oldStart, block.oldEnd, "−");
    emit("new", block.newStart, block.newEnd, "+");
    hunks.push({ at, oldFirst, oldCount: oldNumber - oldFirst,
                 newFirst, newCount: newNumber - newFirst });
    oldCursor = block.oldEnd;
    newCursor = block.newEnd;
  }
  emit("old", oldCursor, oldText.length, " ");

  unifiedLines = meta;
  unifiedRuns = runs;
  unifiedHunks = hunks;
  return doc;
}

/// Offsets are the engine's, projected. A segment is clipped to each run of its own side and
/// moved by that run's displacement; a segment spanning two runs comes out as two marks over the
/// same bytes, which is what the reader should see in a document where those bytes are apart.
function projectSegments(segments, runs) {
  const out = [];
  for (const seg of segments) {
    for (const run of runs) {
      const from = Math.max(seg.start, run.srcStart);
      const to = Math.min(seg.end, run.srcEnd);
      if (to <= from) continue;
      out.push({ ...seg,
                 start: run.docStart + (from - run.srcStart),
                 end: run.docStart + (to - run.srcStart) });
    }
  }
  return out.sort((a, b) => a.start - b.start || a.end - b.end);
}

/// `@@ −12,4 +12,5` — the form every reader of a unified diff already knows, and the reason it is
/// worth keeping: after a fold, the two number columns say where each *line* is and nothing says
/// where the *change* is.
class HunkWidget extends WidgetType {
  constructor(text) { super(); this.text = text; }
  eq(other) { return other.text === this.text; }
  toDOM() {
    const el = document.createElement("div");
    el.className = "ds-hunk";
    el.textContent = this.text;
    return el;
  }
}

class SignMarker extends GutterMarker {
  constructor(sign) { super(); this.sign = sign; }
  toDOM() {
    const el = document.createElement("span");
    el.className = "ds-sign";
    el.textContent = this.sign === " " ? " " : this.sign;
    return el;
  }
}

class NumberMarker extends GutterMarker {
  constructor(value) { super(); this.value = value; }
  toDOM() { return document.createTextNode(this.value == null ? " " : String(this.value)); }
}

function unifiedMeta(view, line) {
  return unifiedLines[view.state.doc.lineAt(line.from).number - 1]
    || { sign: " ", old: null, new: null };
}

/// The unified pane. Three gutters — old number, new number, sign — and the same decoration
/// machinery as the two panes, so a mark means the same thing in either layout.
function makeUnifiedPane(parent) {
  const field = StateField.define({
    create: () => Decoration.none,
    update: (value, tr) => {
      for (const effect of tr.effects) {
        if (effect.is(setSegments)) return decorationsForUnified(tr.state, effect.value);
      }
      return value.map(tr.changes);
    },
    provide: f => EditorView.decorations.from(f),
  });
  return new EditorView({
    parent,
    state: EditorState.create({
      doc: "",
      extensions: [
        javascript({ typescript: true, jsx: true }),
        syntaxHighlighting(highlighting),
        EditorView.editable.of(false),
        unifiedWrapping.of(EditorView.lineWrapping),
        gutter({ class: "ds-gutter-old",
                 lineMarker: (view, line) => new NumberMarker(unifiedMeta(view, line).old) }),
        gutter({ class: "ds-gutter-new",
                 lineMarker: (view, line) => new NumberMarker(unifiedMeta(view, line).new) }),
        gutter({ class: "ds-gutter-sign",
                 lineMarker: (view, line) => new SignMarker(unifiedMeta(view, line).sign) }),
        field,
      ],
    }),
  });
}

/// Line decorations for direction, beside the sign column: hue reinforcing a shape that is
/// already there, never carrying the meaning by itself (DEC-035).
function directionDecorations(state) {
  const items = [];
  for (const hunk of unifiedHunks) {
    if (hunk.at > state.doc.length) continue;
    const text = `@@ −${hunk.oldFirst},${hunk.oldCount} +${hunk.newFirst},${hunk.newCount} @@`;
    items.push({ from: hunk.at,
                 deco: Decoration.widget({ widget: new HunkWidget(text), block: true, side: -1 }) });
  }
  for (let number = 1; number <= state.doc.lines; number += 1) {
    const meta = unifiedLines[number - 1];
    if (!meta || meta.sign === " ") continue;
    const line = state.doc.line(number);
    items.push({ from: line.from,
                 deco: Decoration.line({ class: meta.sign === "+" ? "ds-line-add" : "ds-line-del" }) });
  }
  return items;
}

let syncing = false;
/// Both axes. `12-…` §5.4 asks for horizontal scrolling to be **linked between panes**, and only
/// the vertical half was ever wired: on a minified file the two panes drifted apart horizontally
/// and the reader was comparing column 200 of one side with column 40 of the other.
function link(a, b) {
  a.scrollDOM.addEventListener("scroll", () => {
    if (syncing) return;
    syncing = true;
    b.scrollDOM.scrollTop = a.scrollDOM.scrollTop;
    b.scrollDOM.scrollLeft = a.scrollDOM.scrollLeft;
    syncing = false;
    updateTrack();
  });
}

/// The one horizontal track under the pane (the adopted design). Two panes that scroll together
/// have one horizontal position, so they get one control for it — and a range input is reachable
/// from the keyboard, which a scrollbar is not.
function updateTrack() {
  const track = document.getElementById("track");
  if (!track) return;
  const scroller = left.scrollDOM;
  const span = Math.max(0, scroller.scrollWidth - scroller.clientWidth);
  track.max = String(span);
  track.value = String(scroller.scrollLeft);
  track.disabled = span === 0;
  track.title = span === 0 ? "nothing to scroll horizontally"
    : `column ${Math.round(scroller.scrollLeft)} of ${Math.round(span)}`;
}
link(left, right);
link(right, left);

document.getElementById("track")?.addEventListener("input", event => {
  const position = Number(event.target.value);
  syncing = true;
  left.scrollDOM.scrollLeft = position;
  right.scrollDOM.scrollLeft = position;
  syncing = false;
});

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

/// Only the active layout holds a document. Populating both and hiding one would double every
/// mark in the DOM, and the probes that count marks would agree with themselves while saying
/// nothing — the shape of failure this project keeps finding in checks that cannot fail.
function applyLayout(model) {
  const stage = document.getElementById("stage");
  const host = document.getElementById("unified");
  const empty = { text: "", segments: [], changedLines: [] };
  if (layout === "unified") {
    if (!unified) unified = makeUnifiedPane(host);
    const doc = buildUnified(model);
    const segments = projectSegments(model.payload.old.segments, unifiedRuns.old)
      .concat(projectSegments(model.payload.new.segments, unifiedRuns.new))
      .sort((a, b) => a.start - b.start || a.end - b.end);
    unified.dispatch({ changes: { from: 0, to: unified.state.doc.length, insert: doc } });
    unified.__segments = segments;
    unified.dispatch({ effects: setSegments.of(segments) });
    applySide(left, empty);
    applySide(right, empty);
    stage.style.display = "none";
    host.style.display = "flex";
  } else {
    if (unified) {
      unified.dispatch({ changes: { from: 0, to: unified.state.doc.length, insert: "" } });
      unified.__segments = [];
    }
    unifiedLines = [];
    unifiedRuns = { old: [], new: [] };
    applySide(left, model.payload.old);
    applySide(right, model.payload.new);
    host.style.display = "none";
    stage.style.display = "flex";
  }
}

let lastModel = null;

/// The lens views (DEC-061). Rows rather than an editor: neither answer is a diff, and pretending
/// otherwise would put change marks on text that has none.
///
/// The date arrives as ISO-8601 and is aged here, for the reason `stalenessDescription` exists on
/// the Git side — a date makes the reader do the subtraction, and the subtraction is the answer.
function ageOf(iso) {
  if (!iso) return "";
  const days = Math.floor((Date.now() - Date.parse(iso)) / 86400000);
  if (Number.isNaN(days)) return "";
  if (days <= 0) return "today";
  if (days === 1) return "1 day ago";
  if (days < 14) return days + " days ago";
  if (days < 90) return Math.floor(days / 7) + " weeks ago";
  if (days < 365) return Math.floor(days / 30) + " months ago";
  return Math.floor(days / 365) + " years ago";
}

function cell(className, text) {
  const el = document.createElement("span");
  el.className = className;
  el.textContent = text;
  return el;
}

/// The file header. Pushed rather than derived: the renderer is handed a model, and a model does
/// not carry the path it came from — the shell is the side that knows which file the reader chose.
window.diffscopeSetFile = function (path) {
    const cut = String(path || "").lastIndexOf("/");
    document.getElementById("file-path").textContent = cut < 0 ? "" : path.slice(0, cut + 1);
    document.getElementById("file-name").textContent = cut < 0 ? path : path.slice(cut + 1);
    return path;
};

window.diffscopeShowLens = function (json) {
  const payload = typeof json === "string" ? JSON.parse(json) : json;
  const host = document.getElementById("lens");
  host.replaceChildren();
  const header = document.createElement("div");
  header.className = "ds-lens-header";
  header.textContent = payload.summary || "";
  host.appendChild(header);

  for (const row of payload.rows || []) {
    const line = document.createElement("div");
    line.className = "ds-lens-row" + (row.uncommitted ? " ds-lens-uncommitted" : "");
    if (payload.kind === "blame") {
      line.append(cell("ds-lens-sha", row.uncommitted ? "uncommitted" : row.sha.slice(0, 7)),
                  cell("ds-lens-who", row.who),
                  cell("ds-lens-when", row.uncommitted ? "" : ageOf(row.when)),
                  cell("ds-lens-line", String(row.line)),
                  cell("ds-lens-text", row.text));
    } else {
      line.append(cell("ds-lens-sha", row.sha.slice(0, 7)),
                  cell("ds-lens-who", row.who),
                  cell("ds-lens-when", ageOf(row.when)),
                  cell("ds-lens-subject", row.subject),
                  cell("ds-lens-refs", row.refs || ""));
    }
    host.appendChild(line);
  }

  document.getElementById("stage").style.display = "none";
  document.getElementById("unified").style.display = "none";
  host.style.display = "block";
  lastLens = { kind: payload.kind, rows: (payload.rows || []).length };
  return lastLens;
};

/// Back to the diff. The lens is a projection like the layout is, so leaving it re-renders the
/// model that was already there rather than asking the shell for a new one.
window.diffscopeHideLens = function () {
  document.getElementById("lens").style.display = "none";
  lastLens = null;
  if (lastModel) window.diffscopeRender(lastModel);
  return true;
};

let lastLens = null;
let lastRendered = null;

/// The rendered comparison (DEC-063). The shell has already decoded both sides, measured them and
/// counted the differing pixels — this draws what it was told and computes nothing, which is why
/// the sentence above the stage can be checked in Swift before it is ever displayed.
let blendAmount = 0.5;
let splitAt = 0.5;

/// One control for both modes: a range input, its two ends labelled, and the value in words. The
/// design draws a draggable divider on the image itself; a slider does the same job from the
/// keyboard as well, which the divider alone would not (DEC-016).
function slider(leftLabel, rightLabel, value, onChange, describe) {
  const row = document.createElement("div");
  row.className = "ds-render-slider";
  const left = document.createElement("span");
  left.className = "ds-render-label";
  left.textContent = leftLabel;
  const input = document.createElement("input");
  input.type = "range";
  input.min = "0";
  input.max = "100";
  input.value = String(Math.round(value * 100));
  const right = document.createElement("span");
  right.className = "ds-render-label";
  right.textContent = rightLabel;
  const readout = document.createElement("span");
  readout.className = "ds-render-label";
  readout.textContent = describe(value);
  input.addEventListener("input", () => {
    const amount = Number(input.value) / 100;
    onChange(amount);
    readout.textContent = describe(amount);
  });
  row.append(left, input, right, readout);
  return row;
}

/// Search results, grouped by file, in the pane (DEC-062). The file list keeps showing files:
/// results are an answer to a question, not a replacement for the thing being reviewed, and a
/// reader who loses the file list to a search cannot see where the answer sits.
window.diffscopeShowSearch = function (json) {
  const payload = typeof json === "string" ? JSON.parse(json) : json;
  const host = document.getElementById("lens");
  host.replaceChildren();
  const header = document.createElement("div");
  header.className = "ds-lens-header";
  header.textContent = payload.summary || "";
  host.appendChild(header);

  let index = 0;
  for (const group of payload.groups || []) {
    const title = document.createElement("div");
    title.className = "ds-search-file";
    title.textContent = `${group.path}  ·  ${group.hits.length}`;
    host.appendChild(title);
    for (const hit of group.hits) {
      const row = document.createElement("div");
      const current = index === payload.current;
      row.className = "ds-lens-row ds-search-hit" + (current ? " ds-search-current" : "");
      row.append(cell("ds-lens-mark", current ? "▸" : " "),
                 cell("ds-lens-line", String(hit.line)),
                 cell("ds-search-before", hit.before),
                 cell("ds-search-match", hit.match),
                 cell("ds-search-after", hit.after));
      host.appendChild(row);
      if (current) requestAnimationFrame(() => row.scrollIntoView({ block: "center" }));
      index += 1;
    }
  }

  document.getElementById("stage").style.display = "none";
  document.getElementById("unified").style.display = "none";
  document.getElementById("rendered").style.display = "none";
  host.style.display = "block";
  lastLens = { kind: "search", rows: index };
  return lastLens;
};

window.diffscopeShowRendered = function (json) {
  const payload = typeof json === "string" ? JSON.parse(json) : json;
  const host = document.getElementById("rendered");
  host.replaceChildren();
  let mode = payload.modes.find(m => !m.reason)?.id || "sidebyside";

  const bar = document.createElement("div");
  bar.className = "ds-render-bar";
  const summary = document.createElement("div");
  summary.className = "ds-render-summary";
  summary.textContent = payload.summary;
  const stage = document.createElement("div");
  stage.className = "ds-render-stage";

  function panel(label, src) {
    const wrap = document.createElement("div");
    wrap.className = "ds-render-panel";
    const caption = document.createElement("div");
    caption.className = "ds-render-label";
    caption.textContent = label;
    const frame = document.createElement("div");
    frame.className = "ds-checker";
    if (src) {
      const image = document.createElement("img");
      image.src = src;
      frame.appendChild(image);
    } else {
      const none = document.createElement("div");
      none.className = "ds-render-label";
      none.textContent = "no counterpart on this side";
      frame.appendChild(none);
    }
    wrap.append(caption, frame);
    return wrap;
  }

  function draw() {
    stage.replaceChildren();
    stage.dataset.mode = mode;
    if (mode === "sidebyside") {
      stage.append(panel("◀ Before", payload.oldSrc), panel("▶ After", payload.newSrc));
      return;
    }
    const frame = document.createElement("div");
    frame.className = "ds-checker";
    if (mode === "blend") {
      // A slider rather than a fixed half: the useful position depends on what changed, and half
      // is the one setting that hides a small difference under both images at once.
      const before = document.createElement("img");
      before.src = payload.oldSrc;
      const after = document.createElement("img");
      after.src = payload.newSrc;
      after.style.opacity = String(blendAmount);
      const overlay = document.createElement("div");
      overlay.className = "ds-render-overlay";
      overlay.appendChild(after);
      frame.append(before, overlay);
      stage.appendChild(frame);
      stage.appendChild(slider("Before", "After", blendAmount, value => {
        blendAmount = value;
        after.style.opacity = String(value);
      }, amount => Math.round(amount * 100) + "% after"));
      return;
    } else if (mode === "split") {
      const before = document.createElement("img");
      before.src = payload.oldSrc;
      const after = document.createElement("img");
      after.src = payload.newSrc;
      after.style.clipPath = `inset(0 0 0 ${splitAt * 100}%)`;
      const overlay = document.createElement("div");
      overlay.className = "ds-render-overlay";
      overlay.appendChild(after);
      const divider = document.createElement("div");
      divider.className = "ds-render-divider";
      divider.style.left = `${splitAt * 100}%`;
      frame.append(before, overlay, divider);
      stage.appendChild(frame);
      stage.appendChild(slider("◀ Before", "After ▶", splitAt, value => {
        splitAt = value;
        after.style.clipPath = `inset(0 0 0 ${value * 100}%)`;
        divider.style.left = `${value * 100}%`;
      }, amount => Math.round(amount * 100) + "%"));
      return;
    } else if (mode === "pixel") {
      const base = document.createElement("img");
      base.src = payload.newSrc;
      base.style.opacity = "0.3";
      const overlay = document.createElement("div");
      overlay.className = "ds-render-overlay";
      const mask = document.createElement("img");
      mask.className = "ds-pixel-mask";
      mask.src = payload.maskSrc;
      overlay.appendChild(mask);
      frame.append(base, overlay);
    }
    stage.appendChild(frame);
  }

  for (const entry of payload.modes) {
    const button = document.createElement("span");
    button.className = "ds-render-mode" + (entry.reason ? " ds-mode-off" : "");
    button.dataset.on = String(entry.id === mode && !entry.reason);
    button.textContent = entry.reason ? entry.label + " — " + entry.reason : entry.label;
    if (!entry.reason) {
      button.addEventListener("click", () => {
        mode = entry.id;
        for (const other of bar.querySelectorAll(".ds-render-mode")) other.dataset.on = "false";
        button.dataset.on = "true";
        draw();
      });
    }
    bar.appendChild(button);
  }

  host.append(bar, summary, stage);
  draw();
  document.getElementById("stage").style.display = "none";
  document.getElementById("unified").style.display = "none";
  document.getElementById("lens").style.display = "none";
  document.getElementById("unrenderable").style.display = "none";
  host.style.display = "flex";
  lastRendered = { modes: payload.modes.length, mode };
  return lastRendered;
};

/// ⌥⌘→ (DEC-059). The pinned pair does not move, so the re-render compares the same two versions
/// and lands on the same change stop — switching layout is a change of projection, not of subject.
window.diffscopeSetLayout = function (name) {
  layout = name === "unified" ? "unified" : "split";
  if (lastModel) window.diffscopeRender(lastModel);
  return layout;
};

function refreshDecorations() {
  if (unified) unified.dispatch({ effects: setSegments.of(unified.__segments || []) });
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
// The G2 rule, asked of the live document rather than of the stylesheet: **a design may restyle any
// mark and may never hide one.** Parsing CSS text would miss a rule added elsewhere, a cascade that
// wins, or an inherited `opacity`. Computed style is what the reader actually gets.
//
// A mark is "visible" if it takes part in layout and is not transparent, and "distinguishable" if it
// carries at least one non-colour signal — texture, underline, outline or edge (DEC-035, because
// colour alone fails in greyscale, in a screenshot and for a colour-blind reader).
window.diffscopeStyleAudit = function () {
  const marks = ["ds-changed", "ds-fallback", "ds-moved", "ds-formatting", "ds-behaviour",
                 "ds-uncertain", "ds-invisible", "ds-fold", "ds-fold-formatting", "ds-badge",
                 "ds-gutter-changed", "ds-chip"];
  const probe = document.createElement("span");
  document.body.appendChild(probe);
  const report = {};
  for (const name of marks) {
    probe.className = name;
    const style = getComputedStyle(probe);
    const distinguishing = [
      style.textDecorationLine !== "none" ? "underline" : null,
      style.textDecorationStyle !== "solid" ? "decoration-style" : null,
      style.backgroundImage !== "none" ? "texture" : null,
      style.outlineStyle !== "none" ? "outline" : null,
      parseFloat(style.borderRightWidth) > 0 || parseFloat(style.borderTopWidth) > 0 ? "border" : null,
      style.fontWeight !== "400" && style.fontWeight !== "normal" ? "weight" : null,
    ].filter(Boolean);
    report[name] = {
      hidden: style.display === "none" || style.visibility === "hidden"
        || parseFloat(style.opacity) === 0,
      distinguishing,
    };
  }
  probe.remove();
  const bar = getComputedStyle(document.getElementById("notices"));
  report["#notices"] = {
    hidden: bar.display === "none" || bar.visibility === "hidden" || parseFloat(bar.opacity) === 0,
    distinguishing: ["notice bar"],
  };
  return report;
};

// The negative control for the audit above. A check that cannot fail proves nothing — the lesson
// M6-B paid for with the boundary-snap budget — so the suite hides a mark on purpose and requires
// the audit to notice.
window.diffscopeInjectHostileStyle = function (enable) {
  const id = "ds-hostile-probe";
  document.getElementById(id)?.remove();
  if (!enable) return false;
  const style = document.createElement("style");
  style.id = id;
  style.textContent = ".ds-changed { display: none; }";
  document.head.appendChild(style);
  return true;
};

window.diffscopeSetWrap = function (enabled) {
  if (unified) {
    unified.dispatch({ effects: unifiedWrapping.reconfigure(enabled ? EditorView.lineWrapping : []) });
  }
  for (const view of [left, right]) {
    view.dispatch({ effects: wrapping.reconfigure(enabled ? EditorView.lineWrapping : []) });
  }
  return enabled;
};

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

// Jumps to a stop by number rather than by direction, which is what `12-…` §9's "show raw for the
// current region" needs: stops come from the canonical diff, so stop *n* is the same region in every
// mode, and the shell can switch modes and put the reader back where they were standing (DEC-057).
function firstVisibleStop() {
  if (!stops.length) return -1;
  const doc = right.state.doc;
  const block = right.lineBlockAtHeight(right.scrollDOM.scrollTop);
  const top = Math.max(0, Math.min(block.from, doc.length));
  const found = stops.findIndex((stop) => stop.newStart >= top);
  return found >= 0 ? found : stops.length - 1;
}

function goToStopIndex(index) {
  if (!stops.length) return null;
  if (!(index >= 0 && index < stops.length)) return null;
  stopIndex = index;
  return goToStop(0);
}

window.diffscopeCommand = function (name) {
  if (name.startsWith("goToStopIndex:")) {
    return goToStopIndex(parseInt(name.slice("goToStopIndex:".length), 10));
  }
  switch (name) {
    case "nextChange": return goToStop(1);
    case "previousChange": return goToStop(-1);
    // Reported, never decided here: the shell records it before a mode change and hands it back
    // afterwards, the same division of labour as the refresh anchor. A reader who has not navigated
    // yet still has a current region — the first change at or below the top of the viewport —
    // because otherwise "raw for the current region" would do nothing on the file they just opened.
    case "currentStop": return stopIndex >= 0 ? stopIndex : firstVisibleStop();
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

function emptyDiffState(model) {
  if (model.payload.kind !== "text") return null;
  const changed = seg => seg.label === "changed" || seg.label === "moved" || seg.label === "fallback";
  const marks = [...model.payload.old.segments, ...model.payload.new.segments].filter(changed);
  if (!marks.length) {
    // Byte-equal is the only case this may be said in, and the engine has already established it:
    // every segment is unchanged exactly when the sides are identical.
    return "no changes — the two sides are byte-for-byte identical";
  }
  const formattingOnly = marks.every(seg => seg.group === "formatting-only");
  if (!formattingOnly) return null;
  const groups = model.formattingCollapses.length;
  const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
  return groups
    ? `no structural changes; ${plural(marks.length, "formatting difference")} in `
      + `${plural(groups, "group")} — \u2318E to expand`
    : `no structural changes; ${plural(marks.length, "formatting difference")}`;
}

function renderNotices(model) {
  const bar = document.getElementById("notices");
  bar.innerHTML = "";
  const items = [...model.notices];
  if (!model.coverageVerified) items.push("coverage not verified");
  // `12-…` §5.3: the empty-diff state reads as "no structural changes; N formatting differences",
  // and a bare "no changes" is permitted **only** when the two sides are byte-equal (INV-3). Without
  // this sentence a file whose every change is formatting looks, at a glance, like a file with
  // nothing in it.
  const state = emptyDiffState(model);
  if (state) items.push(state);
  // Disclosed counts (DEC-017): grouping is only permissible while it says how much it grouped.
  for (const [group, count] of [...groupCounts(model)].sort()) {
    items.push(`${group}: ${count} shown`);
  }
  // `12-…` §5.2's parser-state indicator. Composed in Swift (`ParserStateReport.chipText`) so the
  // two surfaces that show it cannot word it differently, and so it is checkable without a webview.
  if (model.parser) items.push(model.parser.chipText);
  // The pill says what the reader selected *and* what is actually on screen when they differ —
  // `23b-…` §2: it read `mode: structural` beside a notice saying structural analysis was
  // unavailable, because it reported the selection alone.
  items.push(model.modeChip || `mode: ${model.mode}`);
  for (const text of items) {
    const chip = document.createElement("span");
    chip.className = "ds-chip" + (text.startsWith("invariant") ? " ds-chip-alert" : "");
    chip.textContent = text;
    bar.appendChild(chip);
  }
}

window.diffscopeRender = function (json) {
  const model = typeof json === "string" ? JSON.parse(json) : json;
  lastModel = model;
  currentPin = model.pinOld + ":" + model.pinNew;
  currentMode = model.mode;
  renderNotices(model);

  const stage = document.getElementById("stage");
  const unrenderable = document.getElementById("unrenderable");
  document.getElementById("rendered").style.display = "none";
  lastRendered = null;
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
  applyLayout(model);
  restoreAnchor(model.restore);
  updateTrack();

  lastSummary = {
    ok: true,
    pin: currentPin,
    oldLength: left.state.doc.length,
    newLength: right.state.doc.length,
    oldSegments: model.payload.old.segments.length,
    newSegments: model.payload.new.segments.length,
    groups: Object.fromEntries(groupCounts(model)),
    mode: currentMode,
    layout,
    unifiedLines: unifiedLines.length,
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
    layout,
    fileHeader: document.getElementById("file-name").textContent,
    lens: lastLens,
    rendered: lastRendered,
    renderedModes: document.querySelectorAll(".ds-render-mode").length,
    renderedModesOff: document.querySelectorAll(".ds-mode-off").length,
    renderedImages: document.querySelectorAll(".ds-checker img").length,
    lensRows: document.querySelectorAll(".ds-lens-row").length,
    searchHits: document.querySelectorAll(".ds-search-hit").length,
    searchCurrent: document.querySelector(".ds-search-current")?.textContent || "",
    lensUncommitted: document.querySelectorAll(".ds-lens-uncommitted").length,
    unifiedLines: unifiedLines.length,
    unifiedText: unified ? unified.state.doc.toString() : "",
    signs: document.querySelectorAll(".ds-sign").length,
    signGlyphs: [...document.querySelectorAll(".ds-sign")].map(el => el.textContent).join(""),
    addedLines: document.querySelectorAll(".ds-line-add").length,
    removedLines: document.querySelectorAll(".ds-line-del").length,
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
