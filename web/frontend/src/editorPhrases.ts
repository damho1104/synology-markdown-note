import { EditorState } from "@uiw/react-codemirror";
import { codeMirrorMessages } from "./catalogs";
import { currentLanguage } from "./i18n";

export function editorPhrases() {
  return EditorState.phrases.of(codeMirrorMessages(currentLanguage()));
}
