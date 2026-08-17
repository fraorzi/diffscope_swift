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

/// A note at the end of a line, not at the right edge of the pane.
///
/// The adopted design right-aligns these against the pane. Doing that needs the line to be a
/// containing block, and `position: relative` on `.cm-line` **breaks CodeMirror's line
/// measurement**: the gutter drifted out of step with the code, line 2's number sitting eighteen
/// pixels below line 2. Measured by removing the rule and watching the numbers snap back.
///
/// Alignment of the number columns is load-bearing — it is how a reader says *where* — and the
/// note's exact position is not. So the note follows the code inline, in the shape `ds-badge`
/// already uses for the same reason.
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
    // The hairline box belongs to a **region** the parser could not read, which is the one case
    // INV-4's notice cannot point at. `parse-error` is set in exactly one place — `markUnparsed` —
    // and since DEC-095 a fallback is no longer the whole file, so `ds-fallback` would draw the box
    // around every change in a `.css` file rather than around a hole in a `.tsx` one.
    if (seg.classification === "parse-error") classes.push("ds-parse-error");
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

/// A tint across every changed line (DEC-077), which is what replaced the underline. It is a
/// **line** decoration rather than a mark, so it reaches the full width of the line box instead of
/// stopping where the text stops, and the changed bytes inside it take the stronger tint.
///
/// Which lines are changed is the engine's answer (`changedLines`), the same one the gutter edge
/// is drawn from — so the two carriers cannot disagree about which line changed, and the selftest
/// asserts they do not.
function lineTintItems(state, changedLines) {
  const items = [];
  for (const number of changedLines) {
    if (number < 1 || number > state.doc.lines) continue;
    items.push({ from: state.doc.line(number).from,
                 deco: Decoration.line({ class: "ds-line-changed" }) });
  }
  return items;
}

function decorationsFor(state, segments, side, changedLines) {
  const items = lineTintItems(state, changedLines || [])
    .concat(markItems(state, segments))
    .concat(foldsFor(state, side));
  return Decoration.set(items.map(item => item.deco.range(item.from, item.to ?? item.from)), true);
}

/// The unified document's decorations: the same marks over projected offsets, plus one line
/// decoration per removed or added line. `Decoration.set` sorts, which matters here because a
/// line decoration and a mark can start at the same offset and a builder would refuse them.
/// Folds, projected into the composed document.
///
/// **They were missing entirely.** `decorationsForUnified` built marks and direction lines and
/// nothing else, so a collapsed range — the one presentation act that puts content out of sight,
/// and the one DEC-017 allows only because it states its count and opens on ⌘E — simply did not
/// appear in unified. It went unnoticed because the shell never actually started in unified
/// (DEC-059's default was never sent to the page), so the layout that hid folds was one nobody
/// reached without pressing a key twice.
///
/// A fold is offered only where both sides are byte-equal, and unified emits exactly those regions
/// as context **from the old side** — so the old range is the one to project, and it lands in the
/// context run between two blocks.
function foldsForUnified(state) {
  const items = [];
  const max = state.doc.length;
  folds.forEach((fold, index) => {
    if (expanded.has(index)) return;
    for (const run of unifiedRuns.old) {
      const from = Math.max(fold.oldStart, run.srcStart);
      const to = Math.min(fold.oldEnd, run.srcEnd);
      if (to <= from) continue;
      const start = Math.max(0, Math.min(run.docStart + (from - run.srcStart), max));
      const end = Math.max(start, Math.min(run.docStart + (to - run.srcStart), max));
      if (end <= start) continue;
      const widget = new FoldWidget(fold.lines, index, fold.label,
                                    fold.kind === "formatting" ? "ds-fold-formatting" : "");
      items.push({ from: start, to: end, deco: Decoration.replace({ widget, block: true }) });
    }
  });
  return items;
}

function decorationsForUnified(state, segments) {
  const items = markItems(state, segments)
    .concat(directionDecorations(state))
    .concat(foldsForUnified(state));
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
  const changedLineField = StateField.define({
    create: () => [],
    update: (value, tr) => {
      for (const effect of tr.effects) if (effect.is(setChangedLines)) return effect.value;
      return value;
    },
  });
  // **Declared after `changedLineField` and listed after it below**, so that this one may read it:
  // CodeMirror updates fields in the order the extensions give them, and a field may only ask
  // `tr.state` for one defined before it. The changed lines are read from the field rather than
  // from the effect because a mode change re-dispatches `setSegments` alone — reading the effect
  // would drop every line tint the moment the reader pressed ⌘2.
  const field = StateField.define({
    create: () => Decoration.none,
    update: (value, tr) => {
      for (const effect of tr.effects) if (effect.is(setSegments)) {
        return decorationsFor(tr.state, effect.value, side, tr.state.field(changedLineField));
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

// `12-…` §5.1 names the gutter as one of three carriers of change meaning, beside the line tint
// (the underline until DEC-077) and the background texture. The two others were built; this is the
// third.
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

/// The blocks the unified layout prints. Computed by the engine since DEC-096, because this is the
/// one part of that layout deciding *what is shown*, and a fact derived here cannot be checked
/// without a webview — the same rule `changedLines`, `stops` and `collapses` already follow.
function unifiedBlocks(model) {
  return model.unifiedBlocks || [];
}

/// What can be said about one merged block, **read off the segments inside it**.
///
/// The adopted design writes prose here — *wrapper removed, children preserved*. The engine has no
/// notion of a wrapper, so that sentence is not available and is not invented (`24-…` §1). What is
/// available is every fact the segments carry, and one of the design's own phrases turns out to be
/// among them: *one alignment left ambiguous* is `uncertain`, counted.
function blockFacts(model, block) {
  if (model.payload.kind !== "text") return [];
  const inside = [];
  for (const [side, from, to] of [["old", block.oldStart, block.oldEnd],
                                  ["new", block.newStart, block.newEnd]]) {
    for (const seg of model.payload[side].segments) {
      if (seg.end > from && seg.start < to) inside.push(seg);
    }
  }
  const facts = [];
  const moves = [...new Set(inside.filter(s => s.label === "moved" && s.link != null)
                                  .map(s => s.link + 1))].sort((a, b) => a - b);
  if (moves.length) facts.push(moves.map(n => "M" + n).join(" "));

  const changed = inside.filter(s => s.label === "changed" || s.label === "moved");
  if (changed.length && changed.every(s => s.group === "formatting-only")) {
    const kinds = [...new Set(changed.map(s => s.classification).filter(Boolean))].sort();
    facts.push("formatting only" + (kinds.length ? " — " + kinds.join(", ") : ""));
  } else if (inside.some(s => s.group === "potentially-behavior-affecting")) {
    facts.push("reordering — may change behaviour");
  }

  const disclosures = [...new Set(inside.map(s => s.disclosure).filter(Boolean))].sort();
  if (disclosures.length) facts.push(disclosures.join(", "));

  const ambiguous = inside.filter(s => s.uncertain).length;
  if (ambiguous === 1) facts.push("one alignment left ambiguous");
  else if (ambiguous > 1) facts.push(ambiguous + " alignments left ambiguous");
  return facts;
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
  for (const block of unifiedBlocks(model)) {
    // Context is emitted from the old side only: between two stops the two sides are byte-equal,
    // which is what makes one column able to stand for both.
    emit("old", oldCursor, block.oldStart, " ");
    const at = doc.length;
    const oldFirst = oldNumber;
    const newFirst = newNumber;
    emit("old", block.oldStart, block.oldEnd, "−");
    emit("new", block.newStart, block.newEnd, "+");
    hunks.push({ at, oldFirst, oldCount: oldNumber - oldFirst,
                 newFirst, newCount: newNumber - newFirst,
                 facts: blockFacts(model, block) });
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
  constructor(sign, oldLine, newLine) {
    super();
    this.sign = sign;
    this.oldLine = oldLine;
    this.newLine = newLine;
  }
  eq(other) {
    return other.sign === this.sign && other.oldLine === this.oldLine
      && other.newLine === this.newLine;
  }
  toDOM() {
    const el = document.createElement("span");
    el.className = "ds-sign";
    el.textContent = this.sign === " " ? " " : this.sign;
    // DEC-092: the sign column is where a line goes into the next commit, or comes out of
    // it. It is the mark that already says which side a line is on, so it is the mark that
    // carries the action — a column of checkboxes beside it would say the same thing twice.
    if (this.sign !== " ") {
      el.dataset.stageable = "true";
      el.title = "Stage or unstage this line";
      el.addEventListener("mousedown", (event) => {
        event.preventDefault();
        event.stopPropagation();
        // An addition is addressed by its new-side line, a removal by its old-side one
        // encoded negatively — the shell's own convention, so one message serves both.
        const line = this.sign === "+" ? this.newLine
          : (this.oldLine == null ? null : -this.oldLine);
        if (line == null || Number.isNaN(line)) return;
        window.webkit?.messageHandlers?.diffscope?.postMessage({ action: "stageLine", line });
      });
    }
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
  const view = new EditorView({
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
                 lineMarker: (view, line) => {
                   const meta = unifiedMeta(view, line);
                   return new SignMarker(meta.sign, meta.old, meta.new);
                 } }),
        field,
      ],
    }),
  });
  // The one column has a horizontal position too, and the track is the only keyboard-reachable way
  // to move it (`12-…` §5.4). Nothing linked it before, because the track read the left pane
  // whatever layout was showing.
  view.scrollDOM.addEventListener("scroll", () => { if (!syncing) updateTrack(); });
  return view;
}

/// Line decorations for direction, beside the sign column: hue reinforcing a shape that is
/// already there, never carrying the meaning by itself (DEC-035).
function directionDecorations(state) {
  const items = [];
  for (const hunk of unifiedHunks) {
    if (hunk.at > state.doc.length) continue;
    // The numeric form stays: it is what every reader of a unified diff already knows, and the
    // design's single range cannot say which side a count belongs to. The facts follow it.
    const text = `@@ −${hunk.oldFirst},${hunk.oldCount} +${hunk.newFirst},${hunk.newCount} @@`
      + (hunk.facts && hunk.facts.length ? " · " + hunk.facts.join(" · ") : "");
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

/// `updateTrack` lived here. The control it drove is gone (DEC-086): a range input only a pointer
/// could use, under two panes that already scroll with the wheel and the keyboard. `12-…` §5.4 asks
/// that the two panes share a horizontal position — which `link()` does, on both axes — and never
/// asked for a slider to do it with.
function updateTrack() {}
link(left, right);
link(right, left);

// The same command the keystroke runs, not a second implementation of it — ⌘E and this button must
// not be able to disagree about what expanding means.
document.getElementById("diff-footer-expand")?.addEventListener("click", () => {
  window.diffscopeCommand("expandAll");
  if (lastModel) updateFooter(lastModel);
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

/// The cost of the last `applyLayout`, in milliseconds, split by the three things that cost
/// anything. Recorded on every render rather than behind a flag: the numbers are wanted for the
/// path the reader actually takes, and a second timed path would be a copy of this one — which is
/// how this project has been wrong before about what the shipped surface does.
///
/// **Synchronous work only.** Layout and paint happen after this returns, and the obvious way to
/// reach them — `requestAnimationFrame` — is suspended whenever the window is occluded, which a
/// selftest launched from a terminal always is (T1-A). So this measures composition, which is the
/// question DEC-059 left open, and says nothing about frame time.
let lastTimings = null;

/// Only the active layout holds a document. Populating both and hiding one would double every
/// mark in the DOM, and the probes that count marks would agree with themselves while saying
/// nothing — the shape of failure this project keeps finding in checks that cannot fail.
function applyLayout(model) {
  const stage = document.getElementById("stage");
  const host = document.getElementById("unified");
  const empty = { text: "", segments: [], changedLines: [] };
  const clock = () => performance.now();
  const startedAt = clock();
  if (layout === "unified") {
    // **The host is shown before the view is built**, so the editor is never constructed inside a
    // `display: none` element and never has to start from the font's own defaults.
    //
    // Recorded honestly: this fixed nothing observable. The stale metrics it was written for were
    // real — gutter rows sized at 16.87 px beside lines the stylesheet lays out at 15 — but they
    // outlive construction, because CodeMirror re-measures inside an animation frame and the frame
    // never comes while the window is occluded. `diffscopeSettle` is what actually clears them, and
    // in a window the reader can see they were never there at all.
    stage.style.display = "none";
    host.style.display = "flex";
    if (!unified) unified = makeUnifiedPane(host);
    const composeAt = clock();
    const doc = buildUnified(model);
    const projectAt = clock();
    const segments = projectSegments(model.payload.old.segments, unifiedRuns.old)
      .concat(projectSegments(model.payload.new.segments, unifiedRuns.new))
      .sort((a, b) => a.start - b.start || a.end - b.end);
    const dispatchAt = clock();
    unified.dispatch({ changes: { from: 0, to: unified.state.doc.length, insert: doc } });
    unified.__segments = segments;
    unified.dispatch({ effects: setSegments.of(segments) });
    const doneAt = clock();
    lastTimings = {
      layout: "unified",
      compose: projectAt - composeAt,
      project: dispatchAt - projectAt,
      dispatch: doneAt - dispatchAt,
      total: doneAt - startedAt,
      docLength: doc.length,
      lines: unifiedLines.length,
      runs: unifiedRuns.old.length + unifiedRuns.new.length,
      blocks: unifiedHunks.length,
      segmentsIn: model.payload.old.segments.length + model.payload.new.segments.length,
      segmentsOut: segments.length,
    };
    applySide(left, empty);
    applySide(right, empty);
    // And a re-measure asked for explicitly, so the metrics cannot go stale a second way — a
    // window resized while unified is hidden, a font that loads late. It is a no-op when nothing
    // has changed.
    unified.requestMeasure();
  } else {
    if (unified) {
      unified.dispatch({ changes: { from: 0, to: unified.state.doc.length, insert: "" } });
      unified.__segments = [];
    }
    unifiedLines = [];
    unifiedRuns = { old: [], new: [] };
    const dispatchAt = clock();
    applySide(left, model.payload.old);
    applySide(right, model.payload.new);
    const doneAt = clock();
    // The baseline the unified numbers are stated against: the same model, in the layout that
    // shipped first. A ratio survives a loaded machine where an absolute millisecond does not.
    lastTimings = {
      layout: "split",
      compose: 0,
      project: 0,
      dispatch: doneAt - dispatchAt,
      total: doneAt - startedAt,
      docLength: model.payload.old.text.length + model.payload.new.text.length,
      lines: 0,
      runs: 0,
      blocks: 0,
      segmentsIn: model.payload.old.segments.length + model.payload.new.segments.length,
      segmentsOut: model.payload.old.segments.length + model.payload.new.segments.length,
    };
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
///
/// The `SHOWING` row that stood under it is **gone** (DEC-088) and with it the height it kept
/// changing: the shell pushed the comparison on its own schedule rather than inside a render, so
/// the row could appear under an editor that had already measured itself and CodeMirror would keep
/// the line heights it computed against the taller pane. The comparison is still stated — in the
/// status line and in the title band, both of which are chrome and neither of which resizes the
/// document. The value is kept so the shell's push has somewhere to land and so a check can read
/// back what it was told.
let comparison = "";

window.diffscopeSetComparison = function (text) {
  comparison = String(text || "");
  return comparison;
};

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
      // The topology, drawn from lanes the Git layer computed (DEC-092/DEC-093). `--graph`'s own
      // drawing is a presentation and is never parsed; what arrives here is one string per row,
      // built from `%P`, and the column is fixed-width so the lines join up between rows.
      // Picking a commit is what DEC-061's comparison is made of, and what every verb in
      // the Repository menu that acts on a commit needs. The shell has had the handler
      // since M9 and the page never sent the message, so History could not say *this one*.
      if ((payload.picked || []).includes(row.sha)) line.className += " ds-lens-picked";
      line.addEventListener("click", () => {
        window.webkit?.messageHandlers?.diffscope?.postMessage({ action: "pickCommit", sha: row.sha });
      });
      line.append(cell("ds-lens-graph", row.graph || ""),
                  cell("ds-lens-sha", row.sha.slice(0, 7)),
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
// carries at least one non-colour signal — texture, decoration, outline or edge (DEC-035, because
// colour alone fails in greyscale, in a screenshot and for a colour-blind reader).
window.diffscopeStyleAudit = function () {
  const marks = ["ds-changed", "ds-fallback", "ds-parse-error", "ds-moved", "ds-formatting",
                 "ds-behaviour", "ds-uncertain", "ds-invisible", "ds-fold", "ds-fold-formatting",
                 "ds-badge", "ds-gutter-changed", "ds-chip"];
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
      // **The tint, since DEC-083**, and it counts for the reason the source check says: the line
      // tint and the byte tint are held a measured 1.20:1 apart in *luminance*, so the pair is a
      // lightness difference rather than a hue one and survives greyscale. Asked of the computed
      // style, which is where an inherited or overridden value would show up.
      style.backgroundColor !== "rgba(0, 0, 0, 0)" && style.backgroundColor !== "transparent"
        ? "tint" : null,
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
  // **The bar is asked while it holds a notice** (DEC-088). It collapses when it is empty, and the
  // audit runs on a document that has nothing to declare — so reading it as it stands measured the
  // `:empty` rule and called it a hidden notice bar. INV-4 is a promise about a notice that
  // *exists*: put one in, ask, take it out. Which is the stronger question of the two, and the one
  // this arm was always meant to be asking.
  const notices = document.getElementById("notices");
  const chip = document.createElement("span");
  chip.className = "ds-chip";
  chip.textContent = "audit";
  notices.appendChild(chip);
  const bar = getComputedStyle(notices);
  report["#notices"] = {
    hidden: bar.display === "none" || bar.visibility === "hidden" || parseFloat(bar.opacity) === 0,
    distinguishing: ["notice bar"],
  };
  chip.remove();
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

/// The negative control for `diffscopeWidths`. The defect `28-…` item 2 records was one missing
/// `flex-direction` on the unified host: `display: flex` made it a row container, and a flex item
/// with no grow is as wide as its content. Putting that back is the only honest way to show the
/// measurement can fail — a width check that has only ever seen the fixed layout is an assumption.
window.diffscopeInjectShrinkWrap = function (enable) {
  const id = "ds-shrinkwrap-probe";
  document.getElementById(id)?.remove();
  if (!enable) return false;
  const style = document.createElement("style");
  style.id = id;
  style.textContent = "#unified { flex-direction: row; }";
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
  // Turning wrapping off is the one act that creates something to scroll to without changing the
  // document, and turning it on is the one that takes it away. Since DEC-077 the track is *absent*
  // rather than dimmed, so a stale answer here is a missing control rather than a dull one — and
  // the widths it is decided from are only right once the pending measurement has been read.
  window.diffscopeSettle();
  updateTrack();
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
    // DEC-078: one command, both directions. Expand everything **unless everything is already
    // expanded**, in which case collapse everything. Deliberately *everything*, not *anything*: a
    // reader who has opened one fold by clicking it, or who has jumped into one — `goToStop` opens
    // whatever covers its target — presses ⌘E to open the rest, which is the reading of the key
    // they already have. The second press closes them all.
    case "expandAll": {
      const allOpen = folds.length > 0 && folds.every((_, index) => expanded.has(index));
      if (allOpen) expanded = new Set();
      else folds.forEach((_, index) => expanded.add(index));
      refreshDecorations();
      if (lastModel) updateFooter(lastModel);
      return { expanded: allOpen ? 0 : folds.length, collapsed: allOpen };
    }
    default: return null;
  }
};

/// The bar across the bottom of the pane (the adopted design): what was grouped away, and the one
/// keystroke that opens it.
///
/// DEC-017 permits grouping **only while the count is shown**, and until now the count lived on the
/// fold markers alone — so a reader who had scrolled past them had no idea anything was grouped.
/// This says it in one place that does not move.
///
/// The wording follows the classifications actually present rather than the design's fixed
/// *indentation only*: `whitespace` and `quote-style` are different claims and the engine
/// distinguishes them (DEC-046), so the bar says which it found.
function updateFooter(model) {
  const bar = document.getElementById("diff-footer");
  const text = document.getElementById("diff-footer-text");
  if (!bar || !text) return;
  if (model.payload.kind !== "text") { bar.hidden = true; return; }

  let formatting = 0;
  const kinds = new Set();
  for (const side of [model.payload.old, model.payload.new]) {
    for (const seg of side.segments) {
      if (seg.group !== "formatting-only") continue;
      formatting += 1;
      if (seg.classification) kinds.add(seg.classification);
    }
  }
  const hidden = (model.collapses || []).reduce((sum, fold) => sum + fold.lines, 0);

  const parts = [];
  if (formatting > 0) {
    parts.push(`${formatting} formatting difference${formatting === 1 ? "" : "s"}`
      + (kinds.size ? " — " + [...kinds].sort().join(", ") : ""));
  }
  if (hidden > 0) parts.push(`${hidden} unchanged lines folded`);
  bar.hidden = parts.length === 0;
  text.textContent = parts.join(" · ");

  // DEC-078: the button says **which way it will go**. A control whose effect depends on state the
  // reader cannot otherwise see has to state the effect, and this is the only place in the pane
  // where the fold state is not visible — a reader who has scrolled past every fold marker sees
  // this bar and nothing else. No keystroke on it (DEC-077): the rule was written about the chrome
  // and this label is the one place in the webview it had been missed.
  const button = document.getElementById("diff-footer-expand");
  if (button) {
    const allOpen = folds.length > 0 && folds.every((_, index) => expanded.has(index));
    button.textContent = allOpen ? "Collapse" : "Expand";
    button.hidden = folds.length === 0;
  }
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
      // `uncertain` was counted here too, and drew `uncertain: 2 shown` — beside the sentence that
      // now says *2 parts of this file could not be matched confidently*. One fact, two wordings,
      // one of them the matcher's. DEC-017's disclosed count is about **grouping**, which hides
      // something; an uncertain alignment hides nothing and is marked on the line it is on.
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

/// One sentence about how far the alignment can be trusted, from the segments themselves.
///
/// `uncertain` is `confidence < confidenceFloor`, decided in the engine (0.8) rather than here — a
/// renderer that picked its own threshold would be redefining what counts as certain, which is why
/// the flag rides on the contract instead of the number.
function confidenceSummary(model) {
  if (model.payload.kind !== "text") return "";
  let aligned = 0;
  let low = 0;
  for (const side of [model.payload.old, model.payload.new]) {
    for (const seg of side.segments) {
      if (seg.confidence == null) continue;
      aligned += 1;
      if (seg.uncertain) low += 1;
    }
  }
  if (aligned === 0) return "";
  // **Nothing while everything is normal** (DEC-077). `confidence: high` was a permanent readout of
  // a fact that only matters when it is not high, and DEC-017's requirement is met by saying so
  // when it is not — in the reader's language rather than in the matcher's.
  if (low === 0) return "";
  return low === 1
    ? "One part of this file could not be matched confidently — it is marked in the diff."
    : `${low} parts of this file could not be matched confidently — they are marked in the diff.`;
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
  // **The three technical chips are gone** (DEC-077). `parser: parsed — tree-sitter tsx`,
  // `confidence: high` and `mode: structural` were drawn on every normal file, and each was written
  // for a reader auditing the diff engine rather than for one reading a diff. Every one of those
  // facts is still computed, still on the wire and still asserted — `chipText` and `modeChip` are
  // untouched — and none of them is drawn while everything is normal.
  //
  // **What stays is the floor, and it does not move.** `12-…` §5.2's parser-state indicator is
  // still what makes INV-4 visible; it now speaks when there is something to say. The *not parsed*
  // case is carried by the degradation notice at the top of this list, whose wording is DEC-077's;
  // `plainSentence` covers the one case that has no notice behind it — a partial parse, where the
  // structural result stands and part of the file sits inside it without a structural claim.
  if (model.parser && model.parser.plainSentence) items.push(model.parser.plainSentence);
  // Confidence — DEC-017 lists it among the mandatory trust indicators, and DEC-045 says outright
  // that dropping the *ambiguity* indicator leaves it untouched. Kept, and silent while it is high.
  const confidence = confidenceSummary(model);
  if (confidence) items.push(confidence);
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
  // **Before** the layout, not after. The footer changes the page's height, and an editor
  // populated first is an editor measured against a height that is about to change: CodeMirror
  // kept the line heights it had computed and the gutter drifted out of step with the code, 33 px
  // a row against the content's 30. Settle the geometry, then fill it. (The `SHOWING` row was the
  // other height that moved here; DEC-088 removed it.)
  updateFooter(model);
  applyLayout(model);
  restoreAnchor(model.restore);
  updateTrack();
  // And say so anyway. Anything else that resizes the pane — the drawer opening, the window — has
  // the same hazard, and this is the one line that makes the editor re-measure rather than trust
  // what it worked out earlier.
  for (const view of [left, right, unified]) if (view) view.requestMeasure();

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

/// Deliberately small. `diffscopeProbe` returns `oldText`, `newText` **and** `unifiedText` in
/// full, and at fifty thousand lines that is megabytes of JSON across the bridge — enough to be
/// most of what any timing arm would measure. A measurement probe that costs more than the thing
/// it measures reports the bridge.
window.diffscopeTimings = function () {
  return lastTimings;
};

/// `performance.now()` is clamped to a millisecond in this webview, so a single composition of a
/// fifty-thousand-line file reads as `0` or `2` and neither number says anything about how the
/// cost grows. Repeating it is the only way to get under the clamp — the two functions are the
/// ones `applyLayout` calls, not copies of them, so what is timed is what the reader pays.
window.diffscopeMeasureCompose = function (iterations) {
  if (!lastModel) return null;
  const runs = Math.max(1, Number(iterations) || 1);
  const composeAt = performance.now();
  for (let i = 0; i < runs; i += 1) buildUnified(lastModel);
  const projectAt = performance.now();
  for (let i = 0; i < runs; i += 1) {
    projectSegments(lastModel.payload.old.segments, unifiedRuns.old);
    projectSegments(lastModel.payload.new.segments, unifiedRuns.new);
  }
  const doneAt = performance.now();
  // The module state above is rebuilt from the model on every call, so the last iteration left it
  // exactly as one render would. Re-rendering anyway, because leaving the document reflecting a
  // measurement rather than a render is how a probe starts lying about the layout.
  applyLayout(lastModel);
  return {
    iterations: runs,
    composeMs: (projectAt - composeAt) / runs,
    projectMs: (doneAt - projectAt) / runs,
  };
};

/// What the page thinks it has to fill. The AppKit frames said the web view fills its pane
/// (`diffWeb=798×731`) while the picture showed the panes ending half way down with black beneath —
/// so the disagreement is inside the document, and this is the only way to see it.
window.diffscopeHeights = function () {
  const el = id => document.getElementById(id);
  const editor = left.dom.querySelector(".cm-editor");
  const scroller = left.dom.querySelector(".cm-scroller");
  // Rectangles, not heights. A height says how big something is and not **where it stops**, and
  // the question here is what occupies the band between the last line of code and the bottom of
  // the pane. Reading that off a downscaled screenshot is what M8-K warns about.
  function rect(node) {
    if (!node) return "absent";
    const box = node.getBoundingClientRect();
    return `${Math.round(box.top)}→${Math.round(box.bottom)}`;
  }
  return {
    innerHeight: window.innerHeight,
    body: rect(document.body),
    stage: rect(el("stage")),
    left: rect(left.dom),
    scroller: rect(scroller),
    content: rect(left.dom.querySelector(".cm-content")),
    track: rect(el("track")),
    unified: rect(el("unified")),
    lens: rect(el("lens")),
    rendered: rect(el("rendered")),
    // Where the gutter rows sit against where the lines sit. Reading this off a screenshot has
    // misled me twice in one session; the numbers cannot.
    rows: (() => {
      const view = layout === "unified" ? unified : left;
      if (!view) return "no view";
      const tops = node => [...view.dom.querySelectorAll(node)]
        .slice(0, 8).map(el => Math.round(el.getBoundingClientRect().top)).join(",");
      return "gutter=" + tops(".cm-gutterElement") + " lines=" + tops(".cm-line");
    })(),
    // Everything the body holds, in order, with what it is — the one that is taking the space will
    // be in this list whether or not anybody thought to ask about it by name.
    children: [...document.body.children].map(node =>
      `${node.id || node.tagName.toLowerCase()}:${rect(node)}`).join(" "),
  };
};

/// The horizontal half of `diffscopeHeights`. The tint behind a changed line stops where the line
/// box stops, and a `.cm-line` is only as wide as `.cm-content` — which CodeMirror sizes to the
/// **widest line**, not to the scroller. So the question "does the tint reach the right edge" is
/// the question "how wide is a short line's box against the scroller", and it is the one to ask
/// before touching the tint's own rule.
///
/// Reported per view and per line, because the two layouts size their content differently and a
/// single number would hide which one is wrong.
/// Force every editor to read the measurement it has pending, and report what changed.
///
/// CodeMirror re-measures inside an animation frame and **`requestAnimationFrame` is suspended
/// while the window is occluded**, which a selftest launched from a terminal always is (T1-A). Until
/// this existed, a view built while its host was hidden kept its construction-time defaults for the
/// whole run: the *lines* were laid out by CSS and were right, and the **gutter rows** were sized
/// from the stale number — 16.87 px against 15 — so every unified snapshot this project has taken
/// has a number column in it that drifts a line by the sixth row, and the reader has never seen it.
///
/// Reading a coordinate forces the pending measurement to be read synchronously. Called before each
/// snapshot, so a picture shows the layout the reader gets rather than the one the frame scheduler
/// never got round to.
/// What the horizontal track is doing, and whether every line box still ends in the same place.
///
/// `28-…` item 3 is a rule with two halves — absent when there is nothing to scroll, present the
/// moment there is — so both are asked of the live document rather than of `updateTrack`'s source.
/// `sameEdge` is item 2's acceptance test in the case that actually exercises it: with wrapping off
/// and one line far longer than the rest, a three-character line and a three-hundred-character line
/// must still be tinted to the same right edge.
window.diffscopeTrackState = function () {
  // The slider is gone (DEC-086); `hidden` now reports that nothing draws one, which is the
  // claim that replaced *it is absent when there is nothing to scroll*.
  const track = document.getElementById("track");
  const view = layout === "unified" ? unified : left;
  if (view) { view.requestMeasure(); if (view.state.doc.length) view.coordsAtPos(0); }
  const scroller = view ? view.scrollDOM : null;
  const widths = view
    ? [...view.dom.querySelectorAll(".cm-line")].map(el => Math.round(el.getBoundingClientRect().width))
    : [];
  return {
    layout,
    hidden: track ? track.hidden : true,
    disabled: track ? track.disabled : true,
    span: scroller ? Math.max(0, Math.round(scroller.scrollWidth - scroller.clientWidth)) : 0,
    lines: widths.length,
    minLine: widths.length ? Math.min(...widths) : -1,
    maxLine: widths.length ? Math.max(...widths) : -1,
    sameEdge: widths.length > 1 && Math.min(...widths) === Math.max(...widths),
  };
};

window.diffscopeSettle = function () {
  const views = [left, right, unified].filter(Boolean);
  const before = views.map(v => v.defaultLineHeight);
  for (const view of views) {
    view.requestMeasure();
    if (view.state.doc.length) view.coordsAtPos(0);
  }
  return views.map((v, i) => `${before[i].toFixed(2)}→${v.defaultLineHeight.toFixed(2)}`).join(" ");
};

window.diffscopeWidths = function () {
  function measure(view, name) {
    if (!view) return { view: name, absent: true };
    // Settled first, for the reason `diffscopeSettle` exists: an occluded window never runs the
    // frame the re-measurement is queued in, and this arm would otherwise report the layout the
    // editor was constructed with rather than the one it has.
    view.requestMeasure();
    if (view.state.doc.length) view.coordsAtPos(0);
    const scroller = view.scrollDOM;
    const content = view.contentDOM;
    const lines = [...view.dom.querySelectorAll(".cm-line")];
    const widths = lines.map(el => Math.round(el.getBoundingClientRect().width));
    const gutters = view.dom.querySelector(".cm-gutters");
    return {
      view: name,
      // The pane the editor is supposed to fill. Without it the check is circular: a shrink-wrapped
      // editor has a narrow scroller *and* narrow lines, so every relation inside the editor still
      // agrees while the pane is half empty — which is exactly what the first version of the
      // control demonstrated by passing.
      hostWidth: Math.round(view.dom.parentElement?.getBoundingClientRect().width ?? -1),
      scrollerWidth: Math.round(scroller.getBoundingClientRect().width),
      scrollWidth: Math.round(scroller.scrollWidth),
      contentWidth: Math.round(content.getBoundingClientRect().width),
      // What the content has to fill: the scroller less the gutters beside it. A line box reaching
      // this number is a tint reaching the right edge; anything less is the defect.
      available: Math.round(scroller.getBoundingClientRect().width
        - (gutters ? gutters.getBoundingClientRect().width : 0)),
      lines: lines.length,
      // The shortest and the longest line box. `28-…` item 2's acceptance test is that a line of
      // three characters and a line of two hundred are tinted to the same right edge, which is
      // exactly these two numbers being equal.
      minLine: widths.length ? Math.min(...widths) : -1,
      maxLine: widths.length ? Math.max(...widths) : -1,
      // And whether the gutter rows stand where the lines stand. **Matched by position, not by
      // index.** `.cm-gutterElement` comes back grouped by gutter, and the list also holds rows
      // that belong to no line — the spacer at the top, and one per block widget, which is what a
      // hunk header is. Pairing the two lists by index reported an 18 px drift in unified that a
      // photograph appeared to confirm and that does not exist: every line has a row level with it,
      // and the extra rows are the widget's own.
      rowDrift: (() => {
        const first = view.dom.querySelector(".cm-gutter");
        if (!first) return "no gutter";
        const rows = [...first.querySelectorAll(".cm-gutterElement")]
          .map(el => Math.round(el.getBoundingClientRect().top));
        const tops = lines.map(el => Math.round(el.getBoundingClientRect().top));
        const unmatched = tops.filter(top => !rows.some(row => Math.abs(row - top) <= 1)).length;
        return `rows=${rows.length} lines=${tops.length} lines-with-no-row=${unmatched}`;
      })(),
    };
  }
  return { layout, innerWidth: window.innerWidth,
           panes: [measure(left, "left"), measure(right, "right"),
                   measure(unified, "unified")] };
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
    // DEC-077's line tint, counted so the selftest can hold it against `gutterChanged`: two
    // carriers of "this line changed", read off the same `changedLines`, must agree.
    tintedLines: document.querySelectorAll(".ds-line-changed").length,
    formattingMarks: document.querySelectorAll(".ds-formatting").length,
    // `ds-note` is gone (DEC-083); the probe keeps the key so an arm that still asks
    // gets an empty list rather than `undefined`, and so the count is assertable.
    notes: [...document.querySelectorAll(".ds-note")].map(el => el.textContent),
    footer: document.getElementById("diff-footer")?.hidden === false
      ? (document.getElementById("diff-footer-text")?.textContent || "") : "",
    foldMarks: document.querySelectorAll(".ds-fold").length,
    // DEC-078: what the footer's button says it will do next. Read from the document rather than
    // from the fold set, because the promise is the label a reader sees.
    expandLabel: document.getElementById("diff-footer-expand")?.hidden === false
      ? (document.getElementById("diff-footer-expand")?.textContent || "") : "",
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
