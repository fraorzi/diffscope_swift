import { EditorView, Decoration, WidgetType } from "@codemirror/view";
import { EditorState, RangeSetBuilder, StateField, StateEffect } from "@codemirror/state";
import { javascript } from "@codemirror/lang-javascript";
import { syntaxHighlighting, defaultHighlightStyle } from "@codemirror/language";

const LABEL_CLASS = {
  changed: "ds-changed",
  moved: "ds-moved",
  fallback: "ds-fallback",
};

class NoticeWidget extends WidgetType {
  constructor(text) { super(); this.text = text; }
  toDOM() {
    const el = document.createElement("div");
    el.className = "ds-notice";
    el.textContent = this.text;
    return el;
  }
}

function decorationsFor(state, segments) {
  const items = [];
  const max = state.doc.length;
  for (const seg of segments) {
    const cls = LABEL_CLASS[seg.label];
    if (!cls) continue;
    const from = Math.max(0, Math.min(seg.start, max));
    const to = Math.max(from, Math.min(seg.end, max));
    if (to <= from) continue;
    items.push({ from, to, deco: Decoration.mark({ class: cls, attributes: seg.classification ? { "data-classification": seg.classification } : undefined }) });
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

function applySide(view, side) {
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: side.text },
  });
  view.dispatch({ effects: setSegments.of(side.segments) });
}

function renderNotices(model) {
  const bar = document.getElementById("notices");
  bar.innerHTML = "";
  const items = [...model.notices];
  if (!model.coverageVerified) items.push("coverage not verified");
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
  renderNotices(model);

  const stage = document.getElementById("stage");
  const unrenderable = document.getElementById("unrenderable");
  if (model.payload.kind !== "text") {
    stage.style.display = "none";
    unrenderable.style.display = "block";
    unrenderable.textContent = model.payload.reason || "content cannot be displayed as text";
    return { ok: true, pin: currentPin, rendered: "unrenderable" };
  }
  stage.style.display = "flex";
  unrenderable.style.display = "none";

  applySide(left, model.payload.old);
  applySide(right, model.payload.new);

  return {
    ok: true,
    pin: currentPin,
    oldLength: left.state.doc.length,
    newLength: right.state.doc.length,
    oldSegments: model.payload.old.segments.length,
    newSegments: model.payload.new.segments.length,
  };
};

window.diffscopeProbe = function () {
  return {
    pin: currentPin,
    oldDocLength: left.state.doc.length,
    newDocLength: right.state.doc.length,
    oldText: left.state.doc.toString(),
    newText: right.state.doc.toString(),
  };
};

window.diffscopeReady = true;
