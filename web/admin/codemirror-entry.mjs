// Source for the vendored `web/admin/codemirror.mjs` bundle.
// Re-exports the minimal CodeMirror 6 API the admin Code tab uses
// so consumers don't pull from the underlying packages directly.
// Regenerate via `scripts/build-codemirror.sh`.

export { EditorView, lineNumbers, highlightActiveLine, keymap } from "@codemirror/view";
export { EditorState, Compartment } from "@codemirror/state";
export {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
} from "@codemirror/commands";
export {
  syntaxHighlighting,
  defaultHighlightStyle,
  bracketMatching,
  indentOnInput,
} from "@codemirror/language";
export { javascript } from "@codemirror/lang-javascript";
export { html } from "@codemirror/lang-html";
export { css } from "@codemirror/lang-css";
