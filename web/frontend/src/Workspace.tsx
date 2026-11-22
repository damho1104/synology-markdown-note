import {
  useCallback,
  useEffect,
  useEffectEvent,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type SetStateAction,
} from "react";
import {
  ArrowLeft,
  ArrowRight,
  Book,
  BookOpenText,
  ChevronRight,
  FilePlus2,
  FileUp,
  FileText,
  FolderOpen,
  LogOut,
  Menu,
  Paperclip,
  RefreshCw,
  Search,
  ShieldAlert,
  Trash2,
  X,
  Star,
  Tag,
  Settings,
  PanelRight,
  PanelLeftClose,
  PanelLeftOpen,
  FolderPlus,
  BookPlus,
  ChevronDown,
  Code,
  Eye,
  Network,
  Link2,
} from "lucide-react";
import { AppIcon } from "./AppIcon";
import {
  ApiFailure,
  errorText,
  jsonRequest,
  readInSession,
  request,
  type Session,
  type Status,
} from "./api";
import { requestId } from "./ids";
import { GlobalSearchDialog, type BodySearchResult } from "./GlobalSearchDialog";
import { HttpNasWarning } from "./HttpNasWarning";
import { NoteGraph } from "./NoteGraph";
import { GraphIndexProvider, GraphIndexStatus } from "./GraphIndex";
import { GraphNavigationProvider, GraphNavigationPanel, initialState, type NavigationState } from "./GraphNavigation";
import { sameLocation, newGraphVisit, type Location, type Route } from "./navigation";
import {
  LibraryDialog,
  type DialogAction,
  type LibraryAction,
} from "./LibraryDialog";
import {
  OriginalEditor,
  type StructureEdit,
  changedHtmlPreview,
  type TextChange,
} from "./OriginalEditor";
import { NoteLinkPicker } from "./NoteLinkPicker";
import { SettingsDialog } from "./SettingsDialog";
import { loadPreferences, savePreferences } from "./preferences";
import CodeMirror, { EditorView, type ReactCodeMirrorRef } from "@uiw/react-codemirror";
import { Transaction } from "@codemirror/state";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags as syntaxTags } from "@lezer/highlight";
import { markdown as markdownLanguage } from "@codemirror/lang-markdown";
import { exportMath } from "./mathExport";
import { readMarkdownFile } from "./markdownImport";
import { NotePreview } from "./NotePreview";
import { NoteRevisionDialog } from "./NoteRevisionDialog";
import { AttachmentQueue } from "./AttachmentQueue";
import {
  detachUploadReferences, MAX_ATTACHMENT_BYTES, MAX_QUEUED_ATTACHMENTS, recoveryUploadReferences, restoreUploads, uploadManifest,
  uploadInsertion, uploadMarkdown, uploadPath, uploadReferences, type DraftUpload, type DraftUploads, type UploadTarget,
} from "./attachmentUploads";
import { useUploadQueue, type UploadPatch } from "./useUploadQueue";
import {
  remoteNoteLink,
  sortNotes,
  preference,
  savePreference,
  dateLabel,
  type SortField,
  type SortDirection,
} from "./library";

type Notebook = { id: string; name: string; stack: string };
type NoteSummary = {
  id: string;
  title: string;
  notebook_id: string;
  version: string;
  locked: boolean;
  trashed: boolean;
  created_at?: number | null;
  modified_at?: number | null;
  tags?: string[];
  excerpt?: string;
  favorite?: boolean;
  is_markdown?: boolean;
};
type NoteFormat = Required<Pick<NoteSummary, "id" | "version" | "is_markdown">>;
type Attachment = { id: string; name: string; ref: string | null };
type NoteDetail = NoteSummary & {
  html_text_layout?: string;
  html_text_preview?: string;
  html_text_token?: string;
  html_text_blocks?: (TextChange & { start?: number; end?: number })[];
  attachment_bindings?: Record<string, string>;
  source_file_id?: string;
  math_attachments?: Record<string, unknown>;
  markdown?: string;
  blocks?: { id: string; html: string; label: string }[];
  html: string;
  attachments: Attachment[];
  editable: boolean;
  read_only_reason: string | null;
  write_in_progress?: boolean;
};
type WriteOperation = {
  operation_id: string;
  target: string;
  note_id: string | null;
  title: string;
  status: string;
  created: number;
};
type Draft = {
  text_changes?: TextChange[];
  text_layout?: string;
  text_blocks?: NoteDetail["html_text_blocks"];
  client_request_id?: string;
  attachments?: DraftUploads;
  pending_upload_ids?: string[];
  create_sent?: {title:string;html:string;markdown?:string};
  review_required?: boolean;
  recovery_acknowledged?: boolean;
  resume_paused?: boolean;
  key: string;
  title: string;
  html: string;
  notebook_id: string;
  version?: string;
  markdown?: string;
};

// Offsets are supplied with the authoritative HTML, never derived from the
// sanitized editing DOM. The server supplies UTF-16 offsets for JS slicing.
function exportHtml(note: NoteDetail, draft: Draft): string {
  if (!draft.text_changes?.length) return draft.html;
  let source = draft.html;
  const changes = draft.text_changes.map(change => {
    const blocks = draft.text_blocks ?? (draft.version === note.version ? note.html_text_blocks : undefined);
    const block = blocks?.find(block => block.index === change.index);
    if (!block || !Number.isInteger(block.start) || !Number.isInteger(block.end) ||
        block.start! < 0 || block.end! < block.start! || block.end! > source.length)
      throw new Error("원본 HTML의 텍스트 위치를 확인할 수 없습니다. 편집본을 보관했습니다.");
    return {...change, start:block.start!, end:block.end!};
  }).sort((a,b) => b.start-a.start);
  for (const change of changes) {
    const text = change.text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    source = source.slice(0, change.start) + text + source.slice(change.end);
  }
  return source;
}

const EDITOR_EXTENSIONS = [
  markdownLanguage(),
  syntaxHighlighting(
    HighlightStyle.define([
      { tag: syntaxTags.heading, color: "#1685ed", fontWeight: "600" },
      { tag: syntaxTags.monospace, color: "#1685ed" },
      { tag: syntaxTags.processingInstruction, color: "#1685ed" },
    ]),
  ),
];
const BLANK_HTML = "<p></p>";
const readOnlyReasons: Record<string, string> = {
  AMBIGUOUS_SOURCE:
    "본문과 일치하는 Markdown 원문이 여러 개 있어 편집할 원문을 안전하게 결정할 수 없습니다.",
  WRITE_IN_PROGRESS:
    "NAS에 완료되지 않은 Markdown 저장 원문이 있습니다. 저장 확인 대기 작업을 먼저 확인하세요.",
  LOCKED: "암호화된 노트는 이 웹 버전에서 편집할 수 없습니다.",
  TRASHED: "휴지통에 있는 노트는 편집할 수 없습니다.",
  ATTACHMENTS:
    "첨부파일 또는 Markdown 원문 메타데이터가 포함된 노트입니다. 손상을 막기 위해 읽기 전용으로 엽니다.",
  COMPLEX_HTML:
    "복합 HTML·서식·내부 링크가 포함된 문서입니다. 안전한 왕복 편집이 검증될 때까지 읽기 전용입니다.",
};

function readRoute(): Route {
  const q = new URLSearchParams(window.location.search);
  return {
    shelf: q.get("s"),
    notebook: q.get("n"),
    note: q.get("note"),
    compose: q.get("new") === "1",
    filter: q.get("f") ?? undefined,
  };
}

function writeRoute(route: Route, index: number, replace = false, location?: Location, scope?: string): void {
  const url = new URL(window.location.href);
  for (const key of ["s", "n", "note", "new", "f"])
    url.searchParams.delete(key);
  if (route.shelf) url.searchParams.set("s", route.shelf);
  if (route.notebook) url.searchParams.set("n", route.notebook);
  if (route.note) url.searchParams.set("note", route.note);
  if (route.filter) url.searchParams.set("f", route.filter);
  if (route.compose) url.searchParams.set("new", "1");
  window.history[replace ? "replaceState" : "pushState"](
    { ...window.history.state, __synonote_index: index, __synonote_location: location, __synonote_scope: scope },
    "",
    url,
  );
}

function draftRead(key: string): Draft | null {
  try {
    const raw = sessionStorage.getItem(key);
    const value = raw && (JSON.parse(raw) as Draft);
    if (
      value &&
      typeof value.title === "string" &&
      typeof value.html === "string" &&
      typeof value.notebook_id === "string"
    )
      return value;
  } catch {
    /* Storage can be unavailable in private browsing. */
  }
  return null;
}

function draftStore(key: string, draft: Draft): void {
  try {
    sessionStorage.setItem(key, JSON.stringify(draft));
  } catch {
    /* Keep the in-memory edit. */
  }
}

function writeInProgress(note: NoteDetail | null): boolean {
  return !!(note?.write_in_progress || note?.read_only_reason === "WRITE_IN_PROGRESS");
}

function uploadBlocksSave(item: DraftUpload, references: ReadonlySet<string>, compose: boolean,
  bindings?: Record<string, string>) {
  if (item.phase === "committed") return false;
  if (item.recoveryOnly || item.phase === "reviewed" || item.phase === "discarding")
    return references.has(item.id) && !bindings?.[item.id];
  return item.phase !== "ready" || !item.inserted || (compose && !references.has(item.id));
}

function recoveryMarkdown(markdown: string, detach: (id: string) => boolean): string {
  const cleaned = detachUploadReferences(markdown, detach);
  if ([...recoveryUploadReferences(cleaned)].some(id => !id || detach(id)))
    throw new Error("해결되지 않은 첨부 링크가 남아 있습니다. 본문에서 해당 링크를 이름만 남도록 수정해 주세요.");
  return cleaned;
}

function savedAttachments(uploads: DraftUploads | undefined, saved: string[], created?: NoteDetail): DraftUploads | undefined {
  if (!uploads) return undefined;
  const committed = new Set(saved);
  return {...uploads, items: uploads.items.map(item => {
    if (committed.has(item.id)) return {...item, phase: "committed",
      metadata: item.metadata && {...item.metadata, status: "committed"}};
    if (created && item.phase === "queued")
      return {...item, target: {notebook_id: created.notebook_id, note_id: created.id}};
    return item;
  })};
}

function draftDelete(key: string): void {
  try {
    sessionStorage.removeItem(key);
  } catch {
    /* Storage can be unavailable. */
  }
}

export function Workspace({
  session,
  status,
  onLogout,
  onSessionExpired,
}: {
  session: Session;
  status: Status;
  onLogout: () => Promise<void>;
  onSessionExpired: () => void;
}) {
  const [route, setRoute] = useState<Route>(readRoute);
  const [notebooks, setNotebooks] = useState<Notebook[]>([]);
  const [notes, setNotes] = useState<NoteSummary[]>([]);
  const [listLoading, setListLoading] = useState(true);
  const [libraryReady, setLibraryReady] = useState(false);
  const graphRevision = useMemo(() => JSON.stringify(notes.map(note => [note.id, note.version, note.locked, note.trashed])), [notes]);
  const [listError, setListError] = useState("");
  const [noteError, setNoteError] = useState("");
  const [detail, setDetail] = useState<NoteDetail | null>(null);
  const [noteFormats, setNoteFormats] = useState<Map<string, NoteFormat>>(() => new Map());
  const [noteLoading, setNoteLoading] = useState(false);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [editing, setEditing] = useState(false);
  const [savingAction, setSavingAction] = useState<"note" | "library" | "import" | "note-action" | null>(null);
  const markdownImportInput = useRef<HTMLInputElement>(null);
  const saving = savingAction !== null;
  const [composing, setComposing] = useState(false);
  const [saveFailure, setSaveFailure] = useState<"safe" | "conflict" | "uncertain" | null>(null);
  const writeInFlight = useRef(false);
  const saveHasMore = useRef(false);
  const saveLatest = useRef<() => Promise<boolean>>(async () => false);
  const createdDraft = useRef<{note: NoteDetail; draft: Draft} | null>(null);
  const [query, setQuery] = useState("");
  const [showGlobalSearch,setShowGlobalSearch] = useState(false);
  const [graphState, setGraphState] = useState<NavigationState>(initialState);
  const [pending, setPending] = useState<WriteOperation[]>([]);
  const [pendingError, setPendingError] = useState("");
  const [createReceipt, setCreateReceipt] = useState<{status:string;operation_id?:string} | null>(null);
  const [recoveredDetail, setRecoveredDetail] = useState<NoteDetail | null>(null);
  const [compare, setCompare] = useState<NoteDetail | null>(null);
  const [message, setMessage] = useState("");
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [sidebarCollapsed, setSidebarCollapsed] = useState(() => preference<boolean>("sidebarCollapsed", false) === true);
  const [listCollapsed, setListCollapsed] = useState(() => preference<boolean>("noteListCollapsed", false) === true);
  const [sortField, setSortField] = useState<SortField>(() =>
    preference("noteListSortField", "modifiedAt"),
  );
  const [sortDirection, setSortDirection] = useState<SortDirection>(() =>
    preference("noteListSortDirection", "descending"),
  );
  const [expandedStacks, setExpandedStacks] = useState<string[]>(() =>
    preference("expandedStacks", []),
  );
  const [viewMode, setViewMode] = useState<"source" | "split" | "read">(() =>
    preference("editorMode", "read"),
  );
  const editorRef = useRef<ReactCodeMirrorRef>(null);
  const [previewLine, setPreviewLine] = useState<number>();
  const [showLinkPicker, setShowLinkPicker] = useState(false);
  const [showLocalGraph, setShowLocalGraph] = useState(false);
  const [dialogAction, setDialogAction] = useState<DialogAction | null>(null);
  const [contextMenu, setContextMenu] = useState<{
    kind: "notebook" | "stack";
    id: string;
    x: number;
    y: number;
  } | null>(null);
  const [inspector, setInspector] = useState(false);
  const [revisionNoteId, setRevisionNoteId] = useState<string | null>(null);
  const [preferences, setPreferences] = useState(loadPreferences);
  const [showSettings, setShowSettings] = useState(false);
  const [systemDark, setSystemDark] = useState(
    () => window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false,
  );
  const dark = preferences.appearance === "system" ? systemDark : preferences.appearance === "dark";
  const editorExtensions = useMemo(() => [
    ...EDITOR_EXTENSIONS,
    ...(preferences.lineWrapping ? [EditorView.lineWrapping] : []),
  ], [preferences.lineWrapping]);
  const attachmentInput = useRef<HTMLInputElement>(null);
  const [attachmentError, setAttachmentError] = useState("");
  const composingNow = useRef(false);
  const mermaidPreferences = { mermaidStyle: preferences.mermaidStyle, mermaidTheme: preferences.mermaidTheme };
  useEffect(() => { savePreferences(preferences); }, [preferences]);
  useEffect(() => {
    const media = window.matchMedia?.("(prefers-color-scheme: dark)");
    if (!media) return;
    const update = () => setSystemDark(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);
  const [revision, setRevision] = useState(0);
  const shelfRenames = useRef(new Map<string, string>());
  const historyIndex = useRef(0);
  const historyScope = useRef(requestId());
  const historyLocation = useRef<Location>({route, search:query, graph:graphState});
  const [historyBounds, setHistoryBounds] = useState({index:0, last:0});
  const historyLast = useRef(0);
  const navigating = useRef({
    route,
    draft,
    activeKey: null as string | null,
    draftKey: null as string | null,
    dirty: false,
    saving: false,
    attachmentsBlocked: false,
    bindings: undefined as NoteDetail["attachment_bindings"],
  });

  // No NAS credential, cookie token or SID is stored in browser storage.
  const draftPrefix = `synonote:web-draft:${JSON.stringify([status.nas_url, session.username])}:`;
  const activeKey =
    route.compose && route.notebook
      ? `new:${route.notebook}`
      : route.note
        ? `note:${route.note}`
        : null;
  useEffect(() => { setPreviewLine(undefined); }, [activeKey]);
  const activeDraftKey = activeKey ? draftPrefix + activeKey : null;
  const original = detail && !route.compose ? detail : null;
  const dirty = !!(
    draft &&
    activeKey === draft.key &&
    (route.compose
      ? draft.title.trim().length > 0 ||
        draft.html !== BLANK_HTML ||
        !!draft.markdown
      : original &&
        (original.title !== draft.title ||
          original.html !== draft.html ||
          original.markdown !== draft.markdown ||
          !!draft.text_changes?.length))
  );
  const readOnlyRecovery = !!(draft?.review_required && activeKey === draft.key && !editing);
  const reviewingUploads = !!(draft?.review_required && !saving);
  const uploads = activeKey === draft?.key ? draft?.attachments : undefined;
  const referencedUploads = useMemo(() => uploads ? uploadReferences(draft?.markdown) : new Set<string>(),
    [uploads, draft?.markdown]);
  const hasStagedUploads = !!uploads?.items.some(item => item.phase !== "committed");
  const bindings = original?.attachment_bindings;
  const attachmentsBlocked = !!uploads?.items.some(item => uploadBlocksSave(item, referencedUploads, route.compose, bindings));
  const unresolvedRecoveryLinks = useMemo(() => {
    if (!draft?.resume_paused) return false;
    const ready = new Set(uploadManifest(uploads, draft.markdown, bindings).map(item => item.upload_id));
    return [...recoveryUploadReferences(draft.markdown)].some(id => !bindings?.[id] && !ready.has(id));
  }, [draft?.resume_paused, draft?.markdown, uploads, bindings]);
  const pendingUploadIds = useMemo(() => new Set(draft?.pending_upload_ids), [draft?.pending_upload_ids]);
  const stagedImages = useMemo(() => {
    if (!uploads) return undefined;
    return Object.fromEntries(uploads.items.flatMap(item =>
      (item.phase === "ready" || item.phase === "reviewed" || item.metadata?.status === "pinned") && item.metadata?.image
        ? [[item.id, uploadPath(uploads.id, item.id, item.target, true)]] : []));
  }, [uploads]);
  const stagedDownloads = useMemo(() => uploads && Object.fromEntries(uploads.items.flatMap(item =>
    item.phase === "ready" || item.phase === "reviewed" || item.metadata?.status === "pinned"
      ? [[item.id, uploadPath(uploads.id, item.id, item.target, true)]] : [])), [uploads]);
  navigating.current = {
    route,
    draft,
    activeKey,
    draftKey: activeDraftKey,
    dirty,
    saving,
    attachmentsBlocked,
    bindings,
  };

  const changeActiveDraft = useCallback((change: (current: Draft) => Draft) => {
    const current = navigating.current;
    if (!current.draft || current.draft.key !== current.activeKey || !current.draftKey) return;
    const next = change(current.draft);
    if (next === current.draft) return;
    current.draft = next;
    const references = next.attachments ? uploadReferences(next.markdown) : new Set<string>();
    current.attachmentsBlocked = !!next.attachments?.items.some(item =>
      uploadBlocksSave(item, references, current.route.compose, current.bindings));
    // Persist queue IDs/bookmarks before network work can run, even on a blank note.
    if (next.attachments) draftStore(current.draftKey, next);
    setDraft(next);
  }, []);

  const patchUpload = useCallback<UploadPatch>((id, uploadId, update) => {
    changeActiveDraft(current => {
      const attachments = current.attachments;
      if (!attachments || attachments.id !== id || !attachments.items.some(item => item.id === uploadId))
        return current;
      const items = attachments.items.flatMap(item => item.id === uploadId ? update(item) ?? [] : item);
      return {...current, attachments: {...attachments, items}};
    });
  }, [changeActiveDraft]);

  const queue = useUploadQueue(uploads, session.csrf_token, !!(route.compose && saving), reviewingUploads, patchUpload);
  const canAttach = !!(editing && !reviewingUploads && draft?.key === activeKey &&
    draft.markdown !== undefined && (route.compose || (detail?.editable && !detail.locked && !detail.trashed)));
  const acceptFiles = useRef<(files: File[], position: number) => void>(() => {});
  acceptFiles.current = (files, position) => {
    if (!canAttach) return;
    const errors: string[] = [];
    changeActiveDraft(current => {
      if (current.markdown === undefined) return current;
      const target: UploadTarget = route.compose
        ? {notebook_id: current.notebook_id, client_request_id: current.client_request_id!}
        : {notebook_id: current.notebook_id, note_id: route.note!};
      const attachments = current.attachments ?? {id: requestId(), items: []};
      const items = [...attachments.items];
      let count = items.filter(item => item.phase !== "committed").length;
      for (const file of files) {
        if (!file.size || file.size > MAX_ATTACHMENT_BYTES) {
          errors.push(`${file.name}: ${file.size ? "50 MB를 초과했습니다." : "빈 파일입니다."}`);
          continue;
        }
        if (count >= MAX_QUEUED_ATTACHMENTS) {
          errors.push(`임시 첨부파일은 최대 ${MAX_QUEUED_ATTACHMENTS}개까지 추가할 수 있습니다.`);
          break;
        }
        const id = requestId();
        count++;
        queue.files.set(`${attachments.id}/${id}`, file);
        items.push({id, target, name: file.name, phase: "queued", position, inserted: false});
      }
      return items.length === attachments.items.length ? current : {...current, attachments: {...attachments, items}};
    });
    setAttachmentError(errors.join(" "));
  };
  const attachmentEvents = useMemo(() => EditorView.domEventHandlers({
    paste(event, view) {
      const files = Array.from(event.clipboardData?.files ?? []);
      if (!files.length || !view.state.facet(EditorView.editable)) return false;
      event.preventDefault();
      acceptFiles.current(files, view.state.selection.main.head);
      return true;
    },
    dragover(event, view) {
      if (!event.dataTransfer?.types.includes("Files") || !view.state.facet(EditorView.editable)) return false;
      event.preventDefault();
      return true;
    },
    drop(event, view) {
      const files = Array.from(event.dataTransfer?.files ?? []);
      if (!files.length || !view.state.facet(EditorView.editable)) return false;
      event.preventDefault();
      acceptFiles.current(files, view.posAtCoords({x: event.clientX, y: event.clientY}) ?? view.state.selection.main.head);
      return true;
    },
  }), []);
  const markdownExtensions = useMemo(() => [...editorExtensions, attachmentEvents], [editorExtensions, attachmentEvents]);

  // Put the next ready file at its live bookmark only after earlier files and
  // the current IME composition have finished.
  useEffect(() => {
    if (!uploads || !canAttach || composing || composingNow.current) return;
    const item = uploads.items.find(row => !row.recoveryOnly && !row.inserted && row.phase !== "committed");
    if (!item || item.phase !== "ready" || !item.metadata || draft?.markdown === undefined) return;
    const view = editorRef.current?.view;
    const {position, text} = uploadInsertion(draft.markdown, item.position, item.metadata);
    const useEditor = view && view.state.doc.toString() === draft.markdown;
    changeActiveDraft(current => {
      if (current.markdown === undefined || current.attachments?.id !== uploads.id) return current;
      const items = current.attachments.items.map(row => {
        if (row.id === item.id) return {...row, inserted: true, insertedText: text};
        if (row.inserted) return row;
        // If insertion moved past leading front matter, move the other
        // bookmarks inside it so their order survives the same adjustment.
        const bookmark = item.position < position ? Math.max(row.position, position) : row.position;
        return {...row, position: useEditor || bookmark < position ? bookmark : bookmark + text.length};
      });
      return {...current,
        markdown: useEditor ? current.markdown : current.markdown.slice(0, position) + text + current.markdown.slice(position),
        attachments: {...current.attachments, items}};
    });
    if (useEditor) view.dispatch({changes: {from: position, insert: text}, userEvent: "input.attach"});
  }, [uploads, canAttach, composing, draft?.markdown, changeActiveDraft]);

  function cancelUpload(id: string) {
    const current = navigating.current.draft;
    const attachments = current?.attachments;
    const item = attachments?.items.find(row => row.id === id);
    if (!current || !attachments || !item || reviewingUploads || item.recoveryOnly ||
        item.metadata?.status === "pinned" || item.metadata?.status === "reviewed" || composingNow.current ||
        writeInFlight.current || pendingUploadIds.has(id)) return;
    const markdown = current.markdown;
    if (markdown !== undefined && item.metadata && uploadReferences(markdown).has(id)) {
      const text = item.insertedText && markdown.includes(item.insertedText)
        ? item.insertedText : uploadMarkdown(item.metadata);
      const position = markdown.indexOf(text);
      if (position < 0 || uploadReferences(markdown.slice(0, position) + markdown.slice(position + text.length)).has(id)) {
        setAttachmentError("본문에서 이 첨부파일을 가리키는 링크를 지운 뒤 취소하세요.");
        return;
      }
      const view = editorRef.current?.view;
      if (view && view.state.doc.toString() === markdown) {
        view.dispatch({changes: {from: position, to: position + text.length},
          annotations: Transaction.addToHistory.of(false)});
      } else {
        changeActiveDraft(latest => ({
          ...latest, markdown: markdown.slice(0, position) + markdown.slice(position + text.length),
          attachments: {...attachments, items: attachments.items.map(row => row.inserted || row.position <= position
            ? row : {...row, position: Math.max(position, row.position - text.length)})},
        }));
      }
    }
    patchUpload(attachments.id, id, row => ({...row, phase: "canceling", error: undefined}));
    queue.abort(id);
    setAttachmentError("");
  }

  async function discardReviewedUpload(id: string) {
    const current = navigating.current;
    const attachments = current.draft?.attachments;
    const item = attachments?.items.find(row => row.id === id);
    if (!attachments || !item || !current.draftKey || writeInFlight.current || composingNow.current ||
        (item.phase !== "reviewed" && !(item.phase === "missing" &&
          (current.draft?.review_required || item.recoveryOnly)))) return;
    const baseline = recoveredDetail ?? detail;
    const bound = !current.route.compose && baseline?.id === current.route.note &&
      !writeInProgress(baseline) && !!baseline?.attachment_bindings?.[id];
    const detach = (reference: string) => !bound && reference === id;
    const linked = recoveryUploadReferences(current.draft?.markdown).has(id) && !bound;
    const action = item.phase === "missing" ? "만료된 첨부 표시를 지울까요?" : "웹 서버에 보관된 임시 파일을 버릴까요?";
    if (!window.confirm(`${item.name}: ${action}${linked ? " 본문의 첨부 링크는 이름만 남습니다." : ""}`)) return;
    const storageKey = current.draftKey;
    try {
      // Check that any affected link can be converted before deleting bytes.
      if (linked) recoveryMarkdown(current.draft!.markdown!, detach);
      patchUpload(attachments.id, id, row => ({...row, phase:"discarding"}));
      if (item.phase === "reviewed") {
        await request(uploadPath(attachments.id, item.id, item.target),
          jsonRequest({}, {"X-CSRF-Token":session.csrf_token}, "DELETE")).catch(error => {
          if (!(error instanceof ApiFailure && error.status === 404)) throw error;
        });
      }
      queue.files.delete(`${attachments.id}/${id}`);
      const remove = (source: Draft): Draft => {
        if (source.attachments?.id !== attachments.id) return source;
        // Editing during the request may have changed the link. Keep its text
        // and require an explicit cleanup if it no longer converts safely.
        const markdown = linked && source.markdown !== undefined ? detachUploadReferences(source.markdown, detach) : source.markdown;
        return {...source, markdown, pending_upload_ids:source.pending_upload_ids?.filter(value => value !== id),
          attachments:{...source.attachments,
            items:source.attachments.items.filter(row => row.id !== id)}};
      };
      if (navigating.current.draftKey === storageKey) {
        changeActiveDraft(remove);
        setAttachmentError(recoveryUploadReferences(navigating.current.draft?.markdown).has(id) && !bound
          ? "본문에 남은 첨부 링크를 지우거나 파일을 다시 선택하세요." : "");
      } else {
        const stored = draftRead(storageKey);
        if (stored) draftStore(storageKey, remove(stored));
      }
    } catch (error) {
      patchUpload(attachments.id, id, row => ({...row, phase:item.phase, error:errorText(error)}));
      handleError(error, setAttachmentError);
    }
  }

  function recordLocation(next: Location, replace = false) {
    if (sameLocation(historyLocation.current, next)) return;
    const index = historyIndex.current + (replace ? 0 : 1);
    if (!replace) historyLast.current = index;
    writeRoute(next.route, index, replace, next, historyScope.current);
    historyIndex.current = index;
    historyLocation.current = next;
    setHistoryBounds({index, last:historyLast.current});
  }

  function changeGraphState(action: SetStateAction<NavigationState>, transient = false) {
    const current = historyLocation.current;
    const next = typeof action === 'function' ? action(current.graph) : action;
    const location = {...current, graph:next};
    recordLocation(location, transient || current.route.filter !== 'graph' || !newGraphVisit(current.graph,next));
    setGraphState(next);
  }

  function changeQuery(search: string) {
    recordLocation({...historyLocation.current,search}, true);
    setQuery(search);
  }

  function commitRoute(next: Route, replace = false, search = historyLocation.current.search) {
    recordLocation({...historyLocation.current,route:next,search}, replace);
    setQuery(search);
    setRoute(next);
    setSidebarOpen(false);
    setCompare(null);
  }

  const handleError = useCallback(
    (error: unknown, setter: (text: string) => void) => {
      setter(errorText(error));
      if (error instanceof ApiFailure && error.status === 401)
        onSessionExpired();
    },
    [onSessionExpired],
  );
  const searchNoteBody = useCallback((query: string, signal: AbortSignal) =>
    request<BodySearchResult>("/api/search/body", {
      ...jsonRequest({query}, {"X-CSRF-Token": session.csrf_token}), signal,
    }), [session.csrf_token]);

  const loadLists = useCallback(async () => {
    setListLoading(true);
    try {
      const [books, all] = await Promise.all([
        request<{ notebooks: Notebook[] }>("/api/notebooks"),
        request<{ notes: NoteSummary[] }>("/api/notes"),
      ]);
      setNotebooks(books.notebooks);
      setNotes(all.notes);
      setLibraryReady(true);
      setListError("");
    } catch (error) {
      handleError(error, setListError);
    } finally {
      setListLoading(false);
    }
  }, [handleError]);

  const loadPending = useCallback(async () => {
    try {
      const data = await request<{ operations: WriteOperation[] }>(
        "/api/writes",
      );
      setPending(data.operations);
      setPendingError("");
    } catch (error) {
      handleError(error, setPendingError);
    }
  }, [handleError]);

  useEffect(() => {
    void loadLists();
    void loadPending();
  }, [loadLists, loadPending]);
  useEffect(() => {
    writeRoute(route, 0, true, historyLocation.current, historyScope.current);
    const pop = (event: PopStateEvent) => {
      const known = event.state?.__synonote_scope === historyScope.current;
      const location: Location = known && event.state?.__synonote_location
        ? event.state.__synonote_location : {route:readRoute(),search:'',graph:initialState()};
      const renamed = location.route.shelf && shelfRenames.current.get(location.route.shelf);
      if (renamed) location.route = {...location.route, shelf:renamed};
      const next = location.route;
      const current = navigating.current;
      const destination =
        next.compose && next.notebook
          ? `new:${next.notebook}`
          : next.note
            ? `note:${next.note}`
            : null;
      const nextIndex =
        known && typeof event.state?.__synonote_index === "number"
          ? event.state.__synonote_index
          : null;
      const restore = () => {
        if (nextIndex !== null && nextIndex !== historyIndex.current) {
          window.history.go(historyIndex.current - nextIndex);
        } else {
          writeRoute(current.route, historyIndex.current, true, historyLocation.current, historyScope.current);
        }
      };
      if (current.saving || (current.activeKey !== destination && current.attachmentsBlocked && !current.draft?.resume_paused)) {
        if (current.attachmentsBlocked) setAttachmentError("이동하려면 진행 중인 첨부파일을 완료하거나 취소하세요.");
        restore();
        return;
      }
      if (current.activeKey !== destination && current.dirty) {
        if (
          !window.confirm("편집 내용은 이 탭에 임시 보관됩니다. 이동할까요?")
        ) {
          restore();
          return;
        }
        if (current.draft && current.draftKey)
          draftStore(current.draftKey, current.draft);
      }
      if (nextIndex !== null) historyIndex.current = nextIndex;
      else {
        historyIndex.current = 0;
        historyLast.current = 0;
        writeRoute(next,0,true,location,historyScope.current);
      }
      if (renamed) writeRoute(next, historyIndex.current, true, location, historyScope.current);
      historyLocation.current = location;
      setHistoryBounds({index:historyIndex.current,last:historyLast.current});
      setQuery(location.search);
      setGraphState(location.graph);
      setRoute(next);
      setCompare(null);
      setMessage("");
    };
    window.addEventListener("popstate", pop);
    return () => window.removeEventListener("popstate", pop);
  }, []);
  useEffect(() => {
    if (!dirty && !saving && !hasStagedUploads) return;
    const beforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", beforeUnload);
    return () => window.removeEventListener("beforeunload", beforeUnload);
  }, [dirty, saving, hasStagedUploads]);

  useEffect(() => {
    let active = true;
    setDetail(null);
    setRecoveredDetail(null);
    setCreateReceipt(null);
    setSaveFailure(null);
    setNoteError("");
    setAttachmentError("");
    setCompare(null);
    if (!activeKey || !activeDraftKey) {
      setNoteLoading(false);
      setDraft(null);
      setEditing(false);
      return;
    }
    if (route.compose) {
      setNoteLoading(false);
      const restored = draftRead(activeDraftKey);
      const initial: Draft = restored ? {...restored, attachments: restoreUploads(restored.attachments, restored.review_required)} : {
        key:activeKey, title:"", html:BLANK_HTML, markdown:"", notebook_id:route.notebook!,
        client_request_id:requestId(),
      };
      // Legacy compose drafts must also receive a durable key before a request.
      if (!initial.client_request_id) initial.client_request_id = requestId();
      setDraft(initial); setEditing(true); setViewMode("split");
      if (initial.review_required) {
        setSaveFailure("uncertain");
        void recoverCreate(initial, activeDraftKey, () => active);
      }
      return () => { active = false; };
    }
    const created = createdDraft.current;
    createdDraft.current = null;
    if (created && created.note.id === route.note) {
      createdDraft.current = null;
      setDetail(created.note); setDraft(created.draft); setEditing(true); setNoteLoading(false);
      return;
    }
    setNoteLoading(true);
    setDraft(null);
    setEditing(false);
    void request<NoteDetail>(`/api/notes/${encodeURIComponent(route.note!)}`)
      .then((note) => {
        if (!active) return;
        setDetail(note);
        const saved = draftRead(activeDraftKey);
        if (
          saved &&
          saved.key === activeKey &&
          saved.notebook_id === note.notebook_id &&
          (note.editable || !!note.html_text_preview || writeInProgress(note) || saved.review_required)
        ) {
          const staged = writeInProgress(note);
          const restored = {...saved, review_required: staged || saved.review_required,
            attachments: restoreUploads(saved.attachments, staged || saved.review_required)};
          // Persist the recovery latch immediately, including older drafts that
          // predate the preflight review marker.
          if (staged) draftStore(activeDraftKey, restored);
          setDraft(restored);
          if (restored.review_required) {
            setSaveFailure("uncertain");
            if (saved.recovery_acknowledged) { setRecoveredDetail(note); setCompare(note); }
          }
          setEditing(!staged && (note.editable || !!note.html_text_preview));
          setViewMode("split");
          setMessage("이 탭에 남아 있던 편집 내용을 복원했습니다.");
        } else {
          setEditing(note.editable || !!note.html_text_preview);
          setDraft({
            key: activeKey,
            title: note.title,
            html: note.html,
            notebook_id: note.notebook_id,
            version: note.version,
            markdown: note.markdown,
            text_changes: note.html_text_preview ? [] : undefined,
            text_layout:note.html_text_layout, text_blocks:note.html_text_blocks,
          });
        }
      })
      .catch((error) => {
        if (active) handleError(error, setNoteError);
      })
      .finally(() => {
        if (active) setNoteLoading(false);
      });
    return () => {
      active = false;
    };
  }, [
    activeKey,
    activeDraftKey,
    route.compose,
    route.note,
    route.notebook,
    revision,
    handleError,
  ]);

  useEffect(() => {
    if (
      draft &&
      activeDraftKey &&
      draft.key === activeKey &&
      (editing || draft.review_required) &&
      (dirty || draft.review_required || draft.resume_paused || hasStagedUploads)
    ) {
      draftStore(activeDraftKey, draft);
    } else if (draft && activeDraftKey && draft.key === activeKey &&
      !dirty && !saving && !draft.review_required && !draft.resume_paused && !hasStagedUploads && (route.compose || detail)) {
      draftDelete(activeDraftKey);
    }
  }, [activeKey, activeDraftKey, draft, dirty, editing, saving, detail, route.compose, hasStagedUploads]);

  const shelves = useMemo(
    () =>
      Array.from(new Set(notebooks.map((book) => book.stack || ""))).sort(
        (a, b) => a.localeCompare(b, "ko"),
      ),
    [notebooks],
  );
  const notebookById = useMemo(
    () => new Map(notebooks.map((book) => [book.id, book])),
    [notebooks],
  );
  const selectedNotebook = route.notebook
    ? notebookById.get(route.notebook)
    : undefined;
  const selectedShelf = route.shelf;
  const tags = useMemo(
    () => Array.from(new Set(notes.flatMap((n) => n.tags ?? []))).sort(),
    [notes],
  );
  const visibleNotes = useMemo(
    () =>
      sortNotes(
        notes.filter((note) => {
          const book = notebookById.get(note.notebook_id);
          if (route.filter === "trash" ? !note.trashed : note.trashed)
            return false;
          if (route.filter === "favorites" && !note.favorite) return false;
          if (
            route.filter?.startsWith("tag:") &&
            !note.tags?.includes(route.filter.slice(4))
          )
            return false;
          if (route.notebook && note.notebook_id !== route.notebook)
            return false;
          if (
            !route.notebook &&
            selectedShelf !== null &&
            (book?.stack || "") !== selectedShelf
          )
            return false;
          return `${note.title} ${note.excerpt ?? ""} ${(note.tags ?? []).join(" ")}`
            .toLocaleLowerCase()
            .includes(query.trim().toLocaleLowerCase());
        }),
        sortField,
        sortDirection,
      ),
    [
      notes,
      notebookById,
      route.notebook,
      selectedShelf,
      query,
      route.filter,
      sortField,
      sortDirection,
    ],
  );
  const unclassifiedNotes = useEffectEvent(() =>
    visibleNotes.filter(note =>
      !note.locked && note.is_markdown === undefined && noteFormats.get(note.id)?.version !== note.version,
    ),
  );
  useEffect(() => {
    if (listLoading || route.filter === "graph") return;
    const pending = unclassifiedNotes();
    if (!pending.length) return;
    const controller = new AbortController();
    const signal = controller.signal;
    void (async () => {
      for (let offset = 0; offset < pending.length; offset += 8) {
        if (signal.aborted) return;
        const pairs = pending.slice(offset, offset + 8).map(note => [note.id, note.version]);
        const path = "/api/note-formats?" + new URLSearchParams({notes: JSON.stringify(pairs)});
        const read = offset === 0 ? request : readInSession;
        const {formats} = await read<{formats: NoteFormat[]}>(path, {signal});
        if (signal.aborted || !formats.length) continue;
        setNoteFormats(current => {
          const next = new Map(current);
          for (const format of formats) next.set(format.id, format);
          return next;
        });
      }
    })().catch(() => {
      // Keep the list usable. An unconfirmed format is retried when the list is refreshed.
    });
    return () => controller.abort();
  }, [listLoading, route.filter, visibleNotes]);

  function noteHasMarkdown(note: NoteSummary): boolean {
    if (note.locked) return false;
    if (detail?.id === note.id && detail.version === note.version)
      return typeof detail.markdown === "string";
    const format = noteFormats.get(note.id);
    return note.is_markdown ?? (format?.version === note.version && format.is_markdown);
  }
  const listTitle =
    route.filter === "graph"
      ? "전체 그래프"
      : (selectedNotebook?.name ??
        (selectedShelf !== null
          ? selectedShelf || "책장 밖 메모장"
          : route.filter === "favorites"
            ? "즐겨찾기"
            : route.filter === "trash"
              ? "휴지통"
              : route.filter?.startsWith("tag:")
                ? "#" + route.filter.slice(4)
                : "전체 노트"));
  function toggleStack(name: string) {
    setExpandedStacks((current) => {
      const next = current.includes(name)
        ? current.filter((v) => v !== name)
        : [...current, name];
      savePreference("expandedStacks", next);
      return next;
    });
  }
  function selectFilter(filter?: string) {
    navigate({
      shelf: null,
      notebook: null,
      note: null,
      compose: false,
      filter,
    });
  }
  function chooseMode(mode: "source" | "split" | "read") {
    setViewMode(mode);
    savePreference("editorMode", mode);

  }

  const canLeaveReview = !!(draft?.resume_paused || draft?.review_required &&
    ((draft.recovery_acknowledged && recoveredDetail) || (route.compose && createReceipt)));

  async function traverseHistory(direction: -1 | 1) {
    if (saving || writeInFlight.current) return;
    if (navigating.current.attachmentsBlocked && !canLeaveReview) {
      setAttachmentError("이동하려면 진행 중인 첨부파일을 완료하거나 취소하세요.");
      return;
    }
    if (direction === -1 ? historyIndex.current <= 0 : historyIndex.current >= historyLast.current) return;
    if (dirty && !canLeaveReview && (!await saveLatest.current() || saveHasMore.current)) return;
    window.history.go(direction);
  }

  async function navigate(next: Route, replace = false, search?:string): Promise<boolean> {
    if (saving || writeInFlight.current) return false;
    if (navigating.current.attachmentsBlocked && !canLeaveReview) {
      setAttachmentError("이동하려면 진행 중인 첨부파일을 완료하거나 취소하세요.");
      return false;
    }
    if (dirty && !canLeaveReview) {
      if (!await saveLatest.current() || saveHasMore.current) return false;
    }
    commitRoute(next, replace, search);
    setMessage("");
    return true;
  }

  async function save(explicitResume = false): Promise<boolean> {
    if (!draft || !activeDraftKey || writeInFlight.current || saving || saveFailure || composingNow.current ||
        draft.review_required || (draft.resume_paused && (!explicitResume || unresolvedRecoveryLinks)) ||
        navigating.current.attachmentsBlocked) return false;
    if (
      !route.compose &&
      (writeInProgress(detail) || (!detail?.editable && !detail?.html_text_preview) || !dirty)
    )
      return false;
    const isNew = route.compose;
    const manifest = uploadManifest(draft.attachments, draft.markdown, detail?.attachment_bindings);
    const sentUploads = manifest.map(entry => entry.upload_id);
    let sent = draft;
    const sentKey = activeKey!;
    const sentStorageKey = activeDraftKey;
    let mutationStarted = false;
    writeInFlight.current = true;
    setSavingAction("note");
    setNoteError("");
    setCompare(null);
    if (dirty) draftStore(activeDraftKey, draft);
    try {
      const url = isNew
        ? "/api/notes"
        : `/api/notes/${encodeURIComponent(route.note!)}`;
      const mathImages = draft.markdown === undefined ? [] : await exportMath(draft.markdown, session.csrf_token);
      // Persist the unresolved state before the network call, including edits
      // made while the request is pending. Reload must never blindly replay it.
      sent = {...draft, review_required:true, recovery_acknowledged:false, pending_upload_ids: sentUploads,
        ...(isNew ? {client_request_id:draft.client_request_id ?? requestId(),
          create_sent:{title:draft.title,html:draft.html,markdown:draft.markdown}} : {})};
      const held = navigating.current.draft === draft ? sent : {
        ...navigating.current.draft!, review_required:true, recovery_acknowledged:false,
        client_request_id:sent.client_request_id, create_sent:sent.create_sent, pending_upload_ids: sentUploads,
      };
      draftStore(sentStorageKey, held);
      const persisted = draftRead(sentStorageKey);
      if (!persisted?.review_required || (isNew && persisted.client_request_id !== sent.client_request_id))
        throw new Error("편집본을 이 탭에 보관할 수 없어 저장을 중단했습니다. 브라우저 저장소 설정을 확인하세요.");
      changeActiveDraft(() => held);
      mutationStarted = true;
      const next = await request<NoteDetail>(
        url,
        jsonRequest(
          {
            title: draft.title.trim() || "제목 없음",
            ...(isNew ? {client_request_id:sent.client_request_id} : {}),
            ...(draft.text_changes !== undefined
              ? { text_changes: draft.text_changes, text_layout:draft.text_layout }
              : draft.markdown !== undefined
                ? { markdown: draft.markdown, ...(mathImages.length ? { math_images: mathImages } : {}) }
                : { html: draft.html }),
            notebook_id: draft.notebook_id,
            ...(manifest.length ? {draft_id: draft.attachments!.id, uploads: manifest} : {}),
            ...(!isNew
              ? { version: draft.version ?? "unknown-draft-base" }
              : {}),
          },
          { "X-CSRF-Token": session.csrf_token },
          isNew ? "POST" : "PUT",
        ),
      );
      const latest = navigating.current.draft;
      if (navigating.current.activeKey !== sentKey || !latest) return true;
      // held can include edits made while preparing math images for sent.
      const unchanged = latest === sent;
      const attachments = savedAttachments(latest.attachments, sentUploads, isNew ? next : undefined);
      const key = isNew ? `note:${next.id}` : sentKey;
      const rebased: Draft = unchanged ? {
        key, title: next.title, html: next.html, notebook_id: next.notebook_id,
        version: next.version, markdown: next.markdown,
        text_changes: next.html_text_preview ? [] : undefined,
        text_layout:next.html_text_layout, text_blocks:next.html_text_blocks, attachments,
      } : {
        ...latest, key, version: next.version, review_required:false, recovery_acknowledged:false, resume_paused:false,
        attachments, pending_upload_ids: undefined,
        text_layout:next.html_text_layout, text_blocks:next.html_text_blocks,
        html: latest.markdown !== undefined || latest.text_changes !== undefined || latest.html === sent.html ? next.html : latest.html,
        text_changes: latest.text_changes?.filter(change =>
          next.html_text_blocks?.find(block => block.index === change.index)?.text !== change.text),
      };
      const rebasedReferences = attachments ? uploadReferences(rebased.markdown) : new Set<string>();
      saveHasMore.current = rebased.title !== next.title || rebased.html !== next.html || rebased.markdown !== next.markdown || !!rebased.text_changes?.length ||
        !!attachments?.items.some(item => uploadBlocksSave(item, rebasedReferences, false, next.attachment_bindings));
      draftDelete(sentStorageKey);
      if (!unchanged || attachments?.items.some(item => item.phase !== "committed")) draftStore(draftPrefix + key, rebased);
      setSaveFailure(null);
      setDetail(next); setDraft(rebased);
      const summary = {...next, is_markdown: typeof next.markdown === "string"};
      setNotes(notes => notes.some(note => note.id === summary.id)
        ? notes.map(note => note.id === summary.id ? {...note, ...summary} : note) : [...notes, summary]);
      if (isNew) {
        createdDraft.current = {note: next, draft: rebased};
        commitRoute({shelf: route.shelf, notebook: next.notebook_id, note: next.id, compose: false}, true);
      }
      return true;
    } catch (error) {
      const conflict = error instanceof ApiFailure && error.code === "REMOTE_CHANGED";
      const uploadRejected = error instanceof ApiFailure && ["UPLOAD_NOT_READY", "UPLOAD_NOT_FOUND", "INVALID_UPLOAD"].includes(error.code);
      const rejected = uploadRejected || error instanceof ApiFailure &&
        ["MARKDOWN_UNSUPPORTED", "HTML_PATCH_INVALID", "DOCUMENT_READ_ONLY", "INVALID_NOTE", "NAS_SESSION_EXPIRED"].includes(error.code);
      setSaveFailure(conflict ? "conflict" : !mutationStarted || rejected ? "safe" : "uncertain");
      if (mutationStarted && (conflict || rejected)) {
        const latest = navigating.current.draft;
        if (latest && navigating.current.activeKey === sentKey) {
          const attachments = uploadRejected && latest.attachments ? {...latest.attachments,
            items: latest.attachments.items.map(item => sentUploads.includes(item.id)
              ? {...item, phase: "checking" as const} : item),
          } : latest.attachments;
          const held = {...latest, attachments, review_required:false, recovery_acknowledged:false, pending_upload_ids: undefined};
          draftStore(sentStorageKey, held); setDraft(held);
        }
      }
      if (mutationStarted && !conflict && !rejected) {
        const latest = navigating.current.draft;
        if (latest && navigating.current.activeKey === sentKey) {
          const held = {...latest, review_required:true, recovery_acknowledged:false};
          draftStore(sentStorageKey, held); setDraft(held);
        }
      }
      handleError(error, setNoteError);
      if (
        error instanceof ApiFailure &&
        error.code === "REMOTE_CHANGED" &&
        route.note
      ) {
        try {
          setCompare(
            await request<NoteDetail>(
              `/api/notes/${encodeURIComponent(route.note)}`,
            ),
          );
        } catch {
          /* Keep the local draft even if the comparison fetch fails. */
        }
      }
      if (
        error instanceof ApiFailure &&
        ["WRITE_UNCERTAIN", "WRITE_REVIEW_REQUIRED"].includes(error.code)
      ) {
        void loadPending();
      }
      return false;
    } finally {
      writeInFlight.current = false;
      setSavingAction(null);
    }
  }
  saveLatest.current = save;
  useEffect(() => {
    if (!editing || !dirty || saving || composing || saveFailure || !draft || draft.review_required ||
        draft.resume_paused || attachmentsBlocked) return;
    const timer = window.setTimeout(() => { void saveLatest.current(); }, 800);
    return () => window.clearTimeout(timer);
  }, [draft, dirty, editing, saving, composing, saveFailure, attachmentsBlocked]);

  async function recoverCreate(saved: Draft, storageKey: string, active = () => true) {
    if (!saved.client_request_id) return;
    try {
      const receipt = await request<{status:string;note?:NoteDetail;operation_id?:string}>(
        `/api/creates/${encodeURIComponent(saved.client_request_id)}`);
      if (!active() || navigating.current.activeKey !== saved.key ||
          navigating.current.draft?.client_request_id !== saved.client_request_id ||
          !navigating.current.draft.review_required) return;
      setCreateReceipt(receipt);
      if (receipt.status === "reviewed") acknowledgeDraft();
      if (receipt.status !== "completed" || !receipt.note) return;
      const note = receipt.note, latest = navigating.current.draft ?? saved;
      const original = saved.create_sent;
      const unchanged = original && latest.title === original.title && latest.html === original.html && latest.markdown === original.markdown;
      const attachments = savedAttachments(latest.attachments, saved.pending_upload_ids ?? [], note);
      const next: Draft = unchanged ? {
        key:`note:${note.id}`, title:note.title, html:note.html, markdown:note.markdown,
        notebook_id:note.notebook_id, version:note.version, attachments,
      } : {...latest, key:`note:${note.id}`, html:note.html, version:note.version,
        notebook_id:note.notebook_id, review_required:false,recovery_acknowledged:false, attachments, pending_upload_ids: undefined};
      draftDelete(storageKey);
      draftStore(draftPrefix + next.key, next);
      createdDraft.current = {note, draft:next};
      const summary = {...note, is_markdown: typeof note.markdown === "string"};
      setNotes(notes => notes.some(row => row.id === summary.id)
        ? notes.map(row => row.id === summary.id ? {...row, ...summary} : row) : [...notes, summary]);
      setSaveFailure(null);
      commitRoute({shelf:route.shelf,notebook:note.notebook_id,note:note.id,compose:false}, true);
    } catch (error) { if (active()) handleError(error, setNoteError); }
  }

  function restartReviewedCreate() {
    if (!draft || !activeDraftKey || !["reviewed", "absent"].includes(createReceipt?.status ?? "")) return;
    const pause = !!(draft.attachments?.items.length || draft.pending_upload_ids?.length || recoveryUploadReferences(draft.markdown).size);
    if (!window.confirm(pause
      ? "원래 초안은 이 탭에 보관됩니다. 첨부 링크는 이름만 남긴 별도 초안을 열까요? 필요한 파일을 다시 선택한 뒤 저장할 수 있습니다."
      : "원래 초안은 이 탭에 보관됩니다. 별도의 새 노트를 생성할까요?")) return;
    try {
      const next = separateDraft(draft, pause);
      const heldKey = `${activeDraftKey}:held:${draft.client_request_id}`;
      draftStore(heldKey, draft);
      if (!draftRead(heldKey)) throw new Error("원래 초안을 이 탭에 보관할 수 없습니다.");
      draftStore(activeDraftKey, next);
      if (draftRead(activeDraftKey)?.client_request_id !== next.client_request_id)
        throw new Error("새 초안을 이 탭에 보관할 수 없습니다.");
      setDraft(next);
      setCreateReceipt(null); setSaveFailure(null); setNoteError("");
    } catch (error) {
      handleError(error, setNoteError);
    }
  }

  function separateDraft(source: Draft, pause: boolean): Draft {
    return {
      key: `new:${source.notebook_id}`, notebook_id: source.notebook_id,
      title: source.title, html: source.html,
      markdown: source.markdown === undefined ? undefined : recoveryMarkdown(source.markdown, () => true),
      client_request_id: requestId(), resume_paused: pause,
    };
  }

  function copyReviewedNote() {
    if (!draft?.review_required || !draft.recovery_acknowledged || draft.markdown === undefined ||
        saving || writeInFlight.current || composingNow.current) return;
    try {
      const next = separateDraft(draft, true);
      const key = draftPrefix + next.key;
      if (draftRead(key)) throw new Error("이 메모장에 작성 중인 새 노트가 있습니다. 기존 초안을 먼저 확인해 주세요.");
      if (!window.confirm("원래 노트와 편집본을 보관합니다. 첨부 링크는 이름만 남기고 별도의 새 노트를 작성할까요?")) return;
      draftStore(key, next);
      if (draftRead(key)?.client_request_id !== next.client_request_id)
        throw new Error("새 초안을 이 탭에 보관할 수 없습니다.");
      commitRoute({shelf:route.shelf, notebook:next.notebook_id, note:null, compose:true});
    } catch (error) {
      handleError(error, setNoteError);
    }
  }

  function editableRecovery(note: NoteDetail | null, source: Draft): note is NoteDetail {
    return !!note && note.id === route.note && note.notebook_id === source.notebook_id &&
      note.editable && !note.locked && !note.trashed && !writeInProgress(note) &&
      !!note.version && note.markdown !== undefined && source.markdown !== undefined;
  }

  async function resumeReviewedNote() {
    if (!draft?.recovery_acknowledged || !activeDraftKey || !editableRecovery(recoveredDetail, draft) ||
        saving || writeInFlight.current || composingNow.current) return;
    try {
      const fresh = await request<NoteDetail>(`/api/notes/${encodeURIComponent(recoveredDetail.id)}`);
      const current = navigating.current;
      const source = current.draft;
      if (current.draftKey !== activeDraftKey || !source?.review_required || !source.recovery_acknowledged) return;
      setRecoveredDetail(fresh); setCompare(fresh);
      if (!editableRecovery(fresh, source) || fresh.version !== recoveredDetail.version) {
        setNoteError("NAS 확인본이 바뀌었습니다. 최신 내용을 검토한 뒤 다시 선택해 주세요.");
        return;
      }
      if (!window.confirm("최신 NAS 확인본을 기준으로 보관한 편집본을 엽니다. NAS에서 확인되지 않은 첨부 링크는 이름만 남길까요?")) return;
      const next: Draft = {
        ...source, version:fresh.version, html:fresh.html,
        markdown:recoveryMarkdown(source.markdown!, id => !fresh.attachment_bindings?.[id]),
        review_required:false, recovery_acknowledged:false, resume_paused:true, pending_upload_ids:undefined,
        attachments:source.attachments && {...source.attachments,
          items:source.attachments.items.map(item => ({...item, recoveryOnly:true}))},
      };
      const heldKey = `${activeDraftKey}:held:${requestId()}`;
      draftStore(heldKey, source);
      if (!draftRead(heldKey)) throw new Error("원래 초안을 이 탭에 보관할 수 없습니다.");
      draftStore(activeDraftKey, next);
      if (!draftRead(activeDraftKey)?.resume_paused) throw new Error("복구한 초안을 이 탭에 보관할 수 없습니다.");
      setDetail(fresh); setDraft(next); setEditing(true); setViewMode("split");
      setRecoveredDetail(null); setCompare(null); setSaveFailure(null); setNoteError("");
    } catch (error) { handleError(error, setNoteError); }
  }

  function refreshRecoveryUploads() {
    const current = navigating.current.draft;
    current?.attachments?.items.forEach(item => {
      if (item.phase !== "committed" && item.phase !== "discarding") queue.abort(item.id);
    });
    changeActiveDraft(source => {
      const restored = restoreUploads(source.attachments, true);
      if (!restored) return source;
      return {...source, attachments:{...restored, items:restored.items.map((item, index) => {
        const original = source.attachments!.items[index];
        return original.phase === "discarding" ? original : item;
      })}};
    });
  }

  function acknowledgeDraft() {
    const current = navigating.current;
    if (!current.draft?.review_required || current.draft.recovery_acknowledged || !current.draftKey) return;
    refreshRecoveryUploads();
    changeActiveDraft(source => {
      const held = {...source, recovery_acknowledged:true};
      draftStore(current.draftKey!, held);
      return held;
    });
  }

  async function reviewAcknowledged() {
    const current = navigating.current;
    if (!current.draft || !current.draftKey || !current.route.note) return;
    refreshRecoveryUploads();
    try {
      const confirmed = await request<NoteDetail>(`/api/notes/${encodeURIComponent(current.route.note)}`);
      if (navigating.current.activeKey !== current.activeKey) return;
      setRecoveredDetail(confirmed); setCompare(confirmed); setNoteError("");
    } catch (error) { handleError(error, setNoteError); }
  }

  async function acknowledge(operation: WriteOperation) {
    if (
      !window.confirm(
        `NAS에서 '${operation.title}'의 저장 결과를 직접 확인했나요? 확인한 경우에만 작업 보류를 해제합니다.`,
      )
    )
      return;
    try {
      await request(
        `/api/writes/${encodeURIComponent(operation.operation_id)}/ack`,
        jsonRequest({}, { "X-CSRF-Token": session.csrf_token }),
      );
      setMessage("보류된 쓰기 기록을 확인 처리했습니다.");
      await loadPending();
      const current = navigating.current;
      if (current.draft?.review_required && current.draftKey &&
          ((!current.route.compose && operation.note_id === current.route.note) || (current.route.compose && operation.operation_id === createReceipt?.operation_id))) {
        acknowledgeDraft();
        if (current.route.compose) await recoverCreate(current.draft, current.draftKey);
        else await reviewAcknowledged();
      } else if (current.route.compose && current.draft?.review_required && current.draftKey) {
        // The receipt identifies the originating operation even after ack;
        // never infer ownership from a null note_id shared by all creates.
        await recoverCreate(current.draft, current.draftKey);
      }
    } catch (error) {
      handleError(error, setPendingError);
    }
  }

  async function logout() {
    if (saving || writeInFlight.current) return;
    if (!canLeaveReview && (navigating.current.attachmentsBlocked || uploads?.items.some(item =>
      item.phase !== "committed" && !referencedUploads.has(item.id)))) {
      setAttachmentError("로그아웃하려면 진행 중인 첨부파일을 완료하거나 취소하세요.");
      return;
    }
    if (dirty && !canLeaveReview && (!await saveLatest.current() || saveHasMore.current)) return;
    void onLogout()
      .then(() => {
        // Clear ordinary drafts, retaining unresolved/reviewed edits for this tab.
        try {
          for (let i = sessionStorage.length - 1; i >= 0; i--) {
            const key = sessionStorage.key(i);
            if (!key?.startsWith(draftPrefix)) continue;
            const stored = draftRead(key);
            if (!stored?.review_required && !stored?.resume_paused) sessionStorage.removeItem(key);
          }
        } catch {
          /* Session may be disabled. */
        }
      })
      .catch((error) => handleError(error, setNoteError));
  }

  async function openInternalLink(destination: string) {
    try {
      const result = await request<{ note_id: string }>(
        "/api/resolve-note?target=" + encodeURIComponent(destination),
      );
      navigate({
        shelf: null,
        notebook: null,
        note: result.note_id,
        compose: false,
      });
    } catch (error) {
      handleError(error, setNoteError);
    }
  }
  async function applyNoteAction(action: {structure_edit: StructureEdit; text_layout: string}
      | {remove_attachment_id: string} | {restore_version: string}): Promise<string | undefined> {
    if (!detail || !draft || dirty || saving || writeInFlight.current || hasStagedUploads ||
        draft.review_required || draft.resume_paused || composingNow.current)
      return "편집본과 진행 중인 저장을 먼저 확인하세요.";
    writeInFlight.current = true;
    setSavingAction("note-action");
    setNoteError("");
    try {
      const next = await request<NoteDetail>(`/api/notes/${encodeURIComponent(detail.id)}`, jsonRequest({
        title: detail.title, notebook_id: detail.notebook_id, version: detail.version,
        ...action,
      }, {"X-CSRF-Token":session.csrf_token}, "PUT"));
      setDetail(next);
      setDraft({...draft, title:next.title, html:next.html, markdown:next.markdown, version:next.version, notebook_id:next.notebook_id,
        text_changes:next.html_text_preview ? [] : undefined,
        text_layout:next.html_text_layout, text_blocks:next.html_text_blocks});
      setNotes(current => current.map(note => note.id === next.id ? {...note, ...next} : note));
      if (route.notebook && route.notebook !== next.notebook_id)
        commitRoute({...route, shelf:null, notebook:next.notebook_id}, true);
    } catch (error) {
      handleError(error, setNoteError);
      void loadPending();
      return errorText(error);
    } finally {
      writeInFlight.current = false;
      setSavingAction(null);
    }
  }

  async function importMarkdown(files: File[]) {
    if (!files.length || !selectedNotebook || route.compose || saving || writeInFlight.current) return;
    const destination = selectedNotebook.id;
    const key = `new:${destination}`;
    const storageKey = draftPrefix + key;
    if (dirty || hasStagedUploads || draft?.review_required || draft?.resume_paused || draftRead(storageKey)) {
      setMessage("작성하거나 보관 중인 편집본을 먼저 확인한 뒤 가져오세요.");
      return;
    }
    let imported = 0;
    let latest: NoteDetail | undefined;
    let held: Draft | undefined;
    let filename = "";
    writeInFlight.current = true;
    setSavingAction("import");
    setMessage("");
    try {
      for (const file of files) {
        filename = file.name;
        const {title, markdown} = await readMarkdownFile(file);
        const client_request_id = requestId();
        const math_images = await exportMath(markdown, session.csrf_token);
        const source = {title, markdown, html:BLANK_HTML};
        const sent: Draft = {...source, key, notebook_id:destination, client_request_id,
          review_required:true, create_sent:source};
        draftStore(storageKey, sent);
        if (draftRead(storageKey)?.client_request_id !== client_request_id) {
          throw new Error("편집본을 이 탭에 보관할 수 없어 가져오기를 중단했습니다.");
        }
        held = sent;
        latest = await request<NoteDetail>("/api/notes", jsonRequest({
          title, markdown, notebook_id:destination, client_request_id,
          ...(math_images.length ? {math_images} : {}),
        }, {"X-CSRF-Token":session.csrf_token}));
        draftDelete(storageKey);
        held = undefined;
        imported += 1;
      }
      if (latest) commitRoute({shelf: route.shelf, notebook: destination, note: latest.id, compose: false});
      setMessage(`Markdown 노트 ${imported}개를 가져왔습니다.`);
    } catch (error) {
      handleError(error, message => setMessage(`${filename} · ${imported}/${files.length}개 가져옴 · ${message}`));
      if (held) {
        commitRoute({shelf: route.shelf, notebook: destination, note: null, compose: true});
        void loadPending();
      }
    } finally {
      if (imported) await loadLists();
      writeInFlight.current = false;
      setSavingAction(null);
    }
  }

  async function libraryAction(action: LibraryAction) {
    if (saving || writeInFlight.current) throw new Error("진행 중인 저장이 끝난 뒤 다시 시도하세요.");
    if (dirty)
      throw new Error("편집 내용을 저장하거나 취소한 다음 실행하세요.");
    if (action.kind === "notebook" && action.action === "delete" &&
        (hasStagedUploads || draft?.review_required || draft?.resume_paused))
      throw new Error("보관된 편집본과 첨부파일을 먼저 확인하세요.");
    setSavingAction("library");
    setPendingError("");
    try {
      await request(
        "/api/library/action",
        jsonRequest(action, { "X-CSRF-Token": session.csrf_token }),
      );
      if (action.kind === "stack" && action.action === "rename" && action.id && action.name) {
        for (const [old, target] of shelfRenames.current) {
          if (target === action.id) shelfRenames.current.set(old, action.name);
        }
        shelfRenames.current.set(action.id, action.name);
        shelfRenames.current.delete(action.name);
        const current = historyLocation.current;
        if (current.route.shelf === action.id) commitRoute({...current.route, shelf:action.name}, true);
        setExpandedStacks(current => {
          const next = [...new Set(current.map(name => name === action.id ? action.name! : name))];
          savePreference("expandedStacks", next); return next;
        });
      }
      if (action.action === "delete") {
        const current = historyLocation.current.route;
        if (action.kind === "stack") {
          if (current.shelf === action.id) commitRoute({...current, shelf: ""}, true);
          setExpandedStacks(previous => {
            const next = previous.filter(name => name !== action.id);
            savePreference("expandedStacks", next);
            return next;
          });
        } else if (action.kind === "notebook") {
          const removed = notebookById.get(action.id ?? "");
          const notebookRemoved = current.notebook === action.id;
          const shelfRemoved = current.shelf === removed?.stack && !notebooks.some(
            book => book.id !== action.id && book.stack === current.shelf,
          );
          const noteRemoved = notes.some(note => note.id === current.note && note.notebook_id === action.id && !note.trashed);
          if (notebookRemoved || shelfRemoved || noteRemoved) {
            commitRoute({...current, shelf: shelfRemoved ? null : current.shelf,
              notebook: notebookRemoved ? null : current.notebook,
              note: noteRemoved || notebookRemoved ? null : current.note,
              compose: !notebookRemoved && current.compose}, true);
          }
        }
      }
      await Promise.all([loadLists(), loadPending()]);
      if (action.kind === "note") setRevision((n) => n + 1);
    } catch (error) {
      handleError(error, setPendingError);
      void loadPending();
      throw error;
    } finally {
      setSavingAction(null);
    }
  }
  function exportNote() {
    let body: string | undefined;
    try {
      body = draft?.markdown ?? detail?.markdown ?? (draft && detail ? exportHtml(detail, draft) : draft?.html ?? detail?.html);
    } catch (error) { setNoteError(errorText(error)); return; }
    if (body === undefined) return;
    const isMarkdown = (draft?.markdown ?? detail?.markdown) !== undefined;
    const url = URL.createObjectURL(
      new Blob([body], {
        type: isMarkdown
          ? "text/markdown;charset=utf-8"
          : "text/html;charset=utf-8",
      }),
    );
    const link = document.createElement("a");
    link.href = url;
    link.download =
      (draft?.title ?? detail?.title ?? "note").replace(/[\/\\:*?"<>|]/g, "_") +
      (isMarkdown ? ".md" : ".html");
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }
  let reviewDraftBody = draft?.markdown ?? draft?.html ?? "";
  if (draft?.text_changes?.length && detail) {
    try { reviewDraftBody = exportHtml(detail, draft); }
    catch { reviewDraftBody = "원본 위치 확인 필요\n" + JSON.stringify(draft.text_changes, null, 2); }
  }
  const selectedSummary = notes.find((n) => n.id === route.note);
  const previewHtml =
    editing && draft?.text_changes && detail?.html_text_preview
      ? changedHtmlPreview(
          detail.html_text_preview,
          detail.html_text_token!,
          draft.text_changes,
        )
      : (editing || readOnlyRecovery) && draft
        ? draft.html
        : (detail?.html ?? "");
  const previewMarkdown = (editing || readOnlyRecovery) && draft ? draft.markdown : detail?.markdown;
  const renderNotebook = (book: Notebook) => (
    <button
      key={book.id}
      onContextMenu={(e) => {
        e.preventDefault();
        setContextMenu({
          kind: "notebook",
          id: book.id,
          x: e.clientX,
          y: e.clientY,
        });
      }}
      className={`native-nav notebook ${route.notebook === book.id ? "selected" : ""}`}
      onClick={() =>
        navigate({
          shelf: book.stack || "",
          notebook: book.id,
          note: null,
          compose: false,
        })
      }
    >
      <BookOpenText size={15} />
      <span>{book.name || "이름 없는 메모장"}</span>
    </button>
  );
  return (
    <GraphIndexProvider key={JSON.stringify([status.nas_url, session.username])} enabled={libraryReady} revision={graphRevision}>
    <GraphNavigationProvider state={graphState} onChange={changeGraphState}>
    <div className={`native-app ${dark ? "native-dark" : ""} ${sidebarCollapsed ? "sidebar-collapsed" : ""} ${listCollapsed ? "list-collapsed" : ""}`}
      onCompositionStart={() => { composingNow.current = true; setComposing(true); }}
      onCompositionEnd={() => { composingNow.current = false; setComposing(false); }}
      style={{ "--editor-font-size": `${preferences.editorFontSize}px` } as CSSProperties}>
      <header className="native-toolbar">
        <div className="panel-controls" role="group" aria-label="패널 표시">
            <button className="icon-button panel-toggle panel-toggle-sidebar" aria-label={sidebarCollapsed ? "책장 패널 펼치기" : "책장 패널 접기"}
              aria-expanded={!sidebarCollapsed} aria-controls="workspace-sidebar" title={sidebarCollapsed ? "책장 패널 펼치기" : "책장 패널 접기"}
              onClick={() => {setSidebarCollapsed(!sidebarCollapsed); savePreference("sidebarCollapsed", !sidebarCollapsed);}}>
              {sidebarCollapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
            </button>
            <button className="icon-button panel-toggle panel-toggle-list" aria-label={listCollapsed ? "노트 목록 펼치기" : "노트 목록 접기"}
              aria-expanded={!listCollapsed} aria-controls="workspace-note-list" title={listCollapsed ? "노트 목록 펼치기" : "노트 목록 접기"}
              onClick={() => {setListCollapsed(!listCollapsed); savePreference("noteListCollapsed", !listCollapsed);}}>
              {listCollapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
            </button>
        </div>
        <div className="toolbar-sidebar">
          <button
            className="icon-button mobile-menu"
            aria-label="책장 메뉴"
            onClick={() => setSidebarOpen(!sidebarOpen)}
          >
            <Menu size={18} />
          </button>
          <span className="workspace-brand" title="Synology Markdown Note">
            <AppIcon size={24} />
            <b>Markdown Note</b>
          </span>
        </div>
        <div className="toolbar-list">{listTitle}</div>
        <div className="toolbar-actions">
          <div className="toolbar-group">
            <button className="icon-button mobile-list-toggle" aria-label="노트 목록 표시 전환"
              aria-expanded={!listCollapsed} aria-controls="workspace-note-list" title={listCollapsed ? "노트 목록 펼치기" : "노트 목록 접기"}
              onClick={() => {setListCollapsed(!listCollapsed); savePreference("noteListCollapsed", !listCollapsed);}}>
              {listCollapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
            </button>
            <button
              className="icon-button"
              aria-label="이전 화면"
              disabled={saving || historyBounds.index === 0}
              onClick={() => void traverseHistory(-1)}
            >
              <ArrowLeft size={18} />
            </button>
            <button
              className="icon-button"
              aria-label="다음 화면"
              disabled={saving || historyBounds.index >= historyBounds.last}
              onClick={() => void traverseHistory(1)}
            >
              <ArrowRight size={18} />
            </button>
            <button
              className="icon-button"
              aria-label="새 노트"
              disabled={saving || !selectedNotebook}
              title={selectedNotebook ? "새 노트" : "메모장을 선택하세요"}
              onClick={() =>
                selectedNotebook &&
                navigate({
                  shelf: route.shelf,
                  notebook: selectedNotebook.id,
                  note: null,
                  compose: true,
                })
              }
            >
              <FilePlus2 size={19} />
            </button>
            <button className="icon-button" aria-label="Markdown 가져오기"
              title={selectedNotebook ? "Markdown 가져오기" : "메모장을 선택하세요"}
              disabled={saving || !selectedNotebook || route.compose}
              onClick={() => markdownImportInput.current?.click()}>
              <FileUp size={18} />
            </button>
            <input hidden ref={markdownImportInput} type="file" multiple
              accept=".md,.markdown,text/markdown" aria-label="가져올 Markdown 파일 선택"
              onChange={event => {
                const files = Array.from(event.currentTarget.files ?? []);
                event.currentTarget.value = "";
                void importMarkdown(files);
              }} />
            <button
              className="icon-button"
              aria-label="전체 검색"
              title="전체 노트 검색"
              onClick={() => setShowGlobalSearch(true)}
            >
              <Search size={19} />
            </button>
          </div>
          <div className="mode-picker" aria-label="보기 모드">
            {(["source", "split", "read"] as const).map((m, i) => (
              <button
                key={m}
                aria-pressed={viewMode === m}
                onClick={() => chooseMode(m)}
              >
                {["원문", "분할", "읽기"][i]}
              </button>
            ))}
          </div>
          <div className="toolbar-group">
            <button
              className="icon-button"
              aria-label="노트 정보"
              aria-pressed={inspector}
              onClick={() => setInspector(!inspector)}
            >
              <PanelRight size={19} />
            </button>
            <button
              className="icon-button"
              aria-label="새로고침"
              disabled={saving || dirty}
              onClick={() => {
                void loadLists();
                void loadPending();
                setRevision((n) => n + 1);
              }}
            >
              <RefreshCw size={19} />
            </button>
            <button
              className="icon-button"
              title="로그아웃"
              aria-label="로그아웃"
              disabled={saving}
              onClick={logout}
            >
              <LogOut size={18} />
            </button>
          </div>
        </div>
      </header>
      <HttpNasWarning nasUrl={status.nas_url} />
      {!!pending.length && (
        <section
          className="workspace-alert warning"
          aria-label="저장 확인 대기 작업"
        >
          <ShieldAlert size={16} />
          <div>
            <b>NAS 저장 결과 확인 필요 · {pending.length}건</b>
            <p>
              Note Station에서 저장 결과를 직접 확인한 후 보류를 해제하세요.
            </p>
            {pending.map((op) => (
              <button
                key={op.operation_id}
                disabled={
                  saving ||
                  (op.status === "pending" &&
                    Date.now() - op.created * 1000 < 3600000)
                }
                onClick={() => void acknowledge(op)}
              >
                {op.title} · NAS 확인 후 보류 해제
              </button>
            ))}
          </div>
        </section>
      )}
      {pendingError && (
        <p className="workspace-alert error" role="alert">
          {pendingError}
        </p>
      )}
      {message && (
        <div className="workspace-alert" role="status">
          {message}
        </div>
      )}
      <div className={`native-columns ${inspector ? "with-inspector" : ""}`}>
        <aside
          id="workspace-sidebar"
          className={`native-sidebar ${sidebarOpen ? "open" : ""}`}
          aria-label="책장 및 메모장"
        >
          <div className="sidebar-scroll">
            <button
              className={`native-nav ${!route.filter && selectedShelf === null && !route.notebook ? "selected" : ""}`}
              onClick={() => selectFilter()}
            >
              <FileText size={16} />
              <span>전체 노트</span>
            </button>
            <button
              className={`native-nav ${route.filter === "favorites" ? "selected" : ""}`}
              onClick={() => selectFilter("favorites")}
            >
              <Star size={16} />
              <span>즐겨찾기</span>
            </button>
            <button
              className={`native-nav ${route.filter === "graph" ? "selected" : ""}`}
              onClick={() => selectFilter("graph")}
            >
              <Network size={16} />
              <span>전체 그래프</span>
            </button>
            <div className="sidebar-section">책장 · 메모장</div>
            <div className="sidebar-create-actions" role="group" aria-label="책장 및 노트북 추가">
            <button
              className="sidebar-create-button"
              disabled={saving}
              onClick={() =>
                setDialogAction({
                  request: { kind: "stack", action: "create" },
                  title: "새 책장 만들기",
                  mode: "createStack",
                })
              }
            >
              <FolderPlus size={16} />
              <span>책장 만들기</span>
            </button>
            <button
              className="sidebar-create-button"
              disabled={saving}
              onClick={() =>
                setDialogAction({
                  request: { kind: "notebook", action: "create" },
                  title: "메모장 추가",
                  mode: "name",
                })
              }
            >
              <BookPlus size={16} />
              <span>노트북 추가</span>
            </button>
            </div>
            {shelves.filter(Boolean).map((stack) => (
              <div
                key={stack}
                className="stack-group"
                onContextMenu={(e) => {
                  if ((e.target as HTMLElement).closest(".notebook")) return;
                  e.preventDefault();
                  setContextMenu({
                    kind: "stack",
                    id: stack,
                    x: e.clientX,
                    y: e.clientY,
                  });
                }}
              >
                <div
                  className={`stack-row ${selectedShelf === stack && !route.notebook ? "selected" : ""}`}
                >
                  <button
                    className="disclosure"
                    aria-label={`${stack} 책장 ${expandedStacks.includes(stack) ? "접기" : "펼치기"}`}
                    aria-expanded={expandedStacks.includes(stack)}
                    onClick={() => toggleStack(stack)}
                  >
                    {expandedStacks.includes(stack) ? (
                      <ChevronDown size={12} />
                    ) : (
                      <ChevronRight size={12} />
                    )}
                  </button>
                  <button
                    className="native-nav"
                    onClick={() => {
                      if (!expandedStacks.includes(stack)) toggleStack(stack);
                      navigate({
                        shelf: stack,
                        notebook: null,
                        note: null,
                        compose: false,
                      });
                    }}
                  >
                    <Book size={16} />
                    <span>{stack}</span>
                  </button>
                </div>
                {expandedStacks.includes(stack) && (
                  <div className="stack-notebooks">
                    {notebooks
                      .filter((b) => b.stack === stack)
                      .sort((a, b) =>
                        a.name.localeCompare(b.name, "ko", { numeric: true }),
                      )
                      .map(renderNotebook)}
                  </div>
                )}
              </div>
            ))}
            <div className="sidebar-subheading">
              <FolderOpen size={14} />
              책장 밖 메모장
            </div>
            {notebooks
              .filter((b) => !b.stack)
              .sort((a, b) =>
                a.name.localeCompare(b.name, "ko", { numeric: true }),
              )
              .map(renderNotebook)}
            {listLoading && <p className="sidebar-status">불러오는 중…</p>}
            {!!tags.length && (
              <>
                <div className="sidebar-section">태그</div>
                {tags.map((tag) => (
                  <button
                    key={tag}
                    className={`native-nav ${route.filter === "tag:" + tag ? "selected" : ""}`}
                    onClick={() => selectFilter("tag:" + tag)}
                  >
                    <Tag size={14} />
                    <span>{tag}</span>
                  </button>
                ))}
              </>
            )}
            <button
              className={`native-nav trash-nav ${route.filter === "trash" ? "selected" : ""}`}
              onClick={() => selectFilter("trash")}
            >
              <Trash2 size={16} />
              <span>휴지통</span>
            </button>
          </div>
          <div className="account-footer">
            <ServerIcon />
            <div>
              <b>{session.username}</b>
              <p>NAS 연결 · 조회 가능</p>
            </div>
            <button
              className="icon-button"
              aria-label="설정"
              aria-haspopup="dialog"
              aria-expanded={showSettings}
              onClick={() => setShowSettings(true)}
            >
              <Settings size={17} />
            </button>
          </div>
        </aside>
        <section id="workspace-note-list" className="native-list" aria-label="노트 목록">
          {route.filter === "graph" ? <GraphNavigationPanel notebooks={notebooks} onOpenNote={(id) => navigate({shelf:null,notebook:null,note:id,compose:false})} /> : <>
          <div className="list-controls">
            <label className="native-search">
              <Search size={15} />
              <input
                id="library-search"
                aria-label="노트 검색"
                placeholder="노트 검색"
                value={query}
                onChange={(e) => changeQuery(e.target.value)}
              />
              {query && (
                <button aria-label="검색 지우기" onClick={() => changeQuery("")}>
                  <X size={13} />
                </button>
              )}
            </label>
            <div className="list-sort">
              <select
                aria-label="노트 정렬 기준"
                value={sortField}
                onChange={(e) => {
                  setSortField(e.target.value as SortField);
                  savePreference("noteListSortField", e.target.value);
                }}
              >
                <option value="title">제목</option>
                <option value="createdAt">추가 날짜</option>
                <option value="modifiedAt">수정 날짜</option>
              </select>
              <select
                aria-label="노트 정렬 방향"
                value={sortDirection}
                onChange={(e) => {
                  setSortDirection(e.target.value as SortDirection);
                  savePreference("noteListSortDirection", e.target.value);
                }}
              >
                <option value="ascending">오름차순</option>
                <option value="descending">내림차순</option>
              </select>
            </div>
          </div>
          {listError && (
            <div role="alert" className="workspace-alert error">
              {listError}
              <button onClick={() => void loadLists()}>재시도</button>
            </div>
          )}
          <div className="list-scroll">
            {listLoading ? (
              <p className="empty-list">노트를 불러오는 중…</p>
            ) : !visibleNotes.length ? (
              <p className="empty-list">
                {query ? "검색 결과 없음" : "노트가 없습니다"}
              </p>
            ) : (
              visibleNotes.map((note) => (
                <button
                  key={note.id}
                  className={`native-note-row ${route.note === note.id ? "selected" : ""}`}
                  onClick={() =>
                    navigate({ ...route, note: note.id, compose: false })
                  }
                >
                  <div className="note-row-title">
                    {note.favorite && <Star size={12} />}
                    <b>{note.title || "제목 없음"}</b>
                    {noteHasMarkdown(note) && (
                      <span className="md-badge">MD</span>
                    )}
                  </div>
                  <p className="note-excerpt">
                    {note.excerpt?.replace(/<[^>]*>/g, "") ||
                      notebookById.get(note.notebook_id)?.name ||
                      "원본 서식 문서"}
                  </p>
                  <small>
                    {sortField === "createdAt"
                      ? `추가${note.created_at ? "" : "일 없음 · 수정"}: `
                      : ""}
                    {dateLabel(
                      sortField === "createdAt"
                        ? (note.created_at ?? note.modified_at)
                        : note.modified_at,
                    )}
                    {note.locked ? " · 암호화" : ""}
                  </small>
                </button>
              ))
            )}
          </div>
          </>}
          <footer className="native-status">
            {route.filter !== "graph" && <span>{visibleNotes.length}개의 노트</span>}
            <GraphIndexStatus />
          </footer>
        </section>
        <main className="native-detail" aria-label="노트 본문"
          inert={savingAction === "import" || savingAction === "note-action"}>
          {route.filter === "graph" ? (
            <NoteGraph
              notebooks={notebooks}
              onOpenNote={(id) =>
                navigate({
                  shelf: null,
                  notebook: null,
                  note: id,
                  compose: false,
                })
              }
            />
          ) : !activeKey ? (
            <div className="native-empty">
              <AppIcon size={40} />
              <h2>노트를 선택하세요</h2>
              <p>책장과 메모장에서 노트를 선택하세요.</p>
            </div>
          ) : noteLoading ? (
            <div className="native-empty">
              <RefreshCw size={24} className="animate-spin" />
              <p>NAS에서 본문 가져오는 중…</p>
            </div>
          ) : (
            <>
              <div className="editor-heading">
                <div className="editor-title-row">
                  {(editing || readOnlyRecovery) && draft ? (
                    <input
                      id="note-title"
                      readOnly={!editing}
                      aria-label="노트 제목"
                      required
                      maxLength={256}
                      value={draft.title}
                      placeholder="제목"
                      onChange={(e) =>
                        changeActiveDraft(current => ({ ...current, title: e.target.value }))
                      }
                    />
                  ) : (
                    <h1>{detail?.title || "제목 없음"}</h1>
                  )}
                  <div className="editor-tools">
                    {editing && draft?.markdown !== undefined && (
                      <button
                        className="icon-button"
                        aria-label="노트 연결"
                        disabled={saving || viewMode === "read"}
                        onClick={() => setShowLinkPicker(true)}
                      >
                        <Link2 size={17} />
                      </button>
                    )}
                    {detail && (
                      <>
                        <button
                          className="icon-button"
                          aria-label={
                            selectedSummary?.favorite
                              ? "즐겨찾기 해제"
                              : "즐겨찾기"
                          }
                          disabled={saving || dirty}
                          onClick={() =>
                            void libraryAction({
                              kind: "note",
                              id: detail.id,
                              action: "favorite",
                              version: detail.version,
                              value: !selectedSummary?.favorite,
                            }).catch(() => {})
                          }
                        >
                          <Star
                            size={17}
                            fill={
                              selectedSummary?.favorite
                                ? "currentColor"
                                : "none"
                            }
                          />
                        </button>
                        <details className="editor-menu">
                          <summary
                            className="icon-button"
                            aria-label="노트 작업"
                          >
                            ···
                          </summary>
                          <div>
                            <button
                              disabled={saving || dirty}
                              onClick={() =>
                                setDialogAction({
                                  request: {
                                    kind: "note",
                                    id: detail.id,
                                    action: "move",
                                    version: detail.version,
                                  },
                                  title: "노트 이동",
                                  mode: "notebook",
                                  initial: detail.notebook_id,
                                })
                              }
                            >
                              다른 메모장으로 이동…
                            </button>
                            <button
                              disabled={saving || dirty}
                              onClick={() =>
                                setDialogAction({
                                  request: {
                                    kind: "note",
                                    id: detail.id,
                                    action: "tags",
                                    version: detail.version,
                                  },
                                  title: "태그 편집",
                                  mode: "tags",
                                  initial: (
                                    detail.tags ??
                                    selectedSummary?.tags ??
                                    []
                                  ).join(", "),
                                })
                              }
                            >
                              태그 편집…
                            </button>
                            <button onClick={exportNote}>내보내기…</button>
                            <button
                              disabled={saving || dirty}
                              onClick={() => {
                                if (
                                  window.confirm(
                                    detail.trashed
                                      ? "이 노트를 복원할까요?"
                                      : "이 노트를 휴지통으로 이동할까요?",
                                  )
                                )
                                  void libraryAction({
                                    kind: "note",
                                    id: detail.id,
                                    action: detail.trashed
                                      ? "restore"
                                      : "trash",
                                    version: detail.version,
                                  }).catch(() => {});
                              }}
                            >
                              {detail.trashed ? "복원" : "휴지통으로 이동"}
                            </button>
                          </div>
                        </details>
                      </>
                    )}

                  </div>
                </div>
                <p>
                  <BookOpenText size={12} />
                  {notebookById.get(
                    draft?.notebook_id ?? detail?.notebook_id ?? "",
                  )?.name ?? "내 노트"}
                  {detail?.tags?.length
                    ? " · " + detail.tags.map((t) => "#" + t).join(" ")
                    : ""}
                </p>
              </div>
              {noteError && (
                <div className="workspace-alert error" role="alert">
                  {noteError}
                  {saveFailure === "safe" && <button className="native-button" onClick={() => { setSaveFailure(null); setNoteError(""); }}>자동 저장 다시 시도</button>}
                </div>
              )}
              {!route.compose &&
                detail &&
                !detail.editable &&
                !detail.html_text_preview && (
                  <div className="workspace-alert warning">
                    <ShieldAlert size={15} />
                    {readOnlyReasons[detail.read_only_reason ?? ""] ??
                      "이 문서는 읽기 전용입니다."}
                  </div>
                )}
              {savingAction !== "note" && route.compose && draft?.review_required && (
                <div className="workspace-alert warning">
                  <div>
                    <b>새 노트 저장 결과 확인 필요</b>
                    <p>상태: {createReceipt?.status ?? "조회 필요"}. 자동 재전송하지 않습니다. 초안을 보관한 채 다른 화면으로 이동할 수 있습니다.</p>
                    <button className="native-button" onClick={() => activeDraftKey && void recoverCreate(draft, activeDraftKey)}>생성 결과 다시 조회</button>
                    {["reviewed", "absent"].includes(createReceipt?.status ?? "") && <button className="native-button" onClick={restartReviewedCreate}>초안 보관하고 별도 노트 생성</button>}
                  </div>
                </div>
              )}
              {savingAction !== "note" && !route.compose && draft?.review_required && !recoveredDetail && (
                <div className="workspace-alert warning">
                  NAS 확인본을 읽기 전까지 자동 저장을 중단합니다.
                  <button className="native-button" onClick={() => void reviewAcknowledged()}>NAS 확인본 다시 불러오기</button>
                </div>
              )}
              {recoveredDetail && draft && (
                <div className="workspace-alert warning">
                  <div>
                    <b>확인한 NAS 결과와 보관한 편집본을 검토하세요</b>
                    <p>자동 재전송하지 않습니다. 편집본은 이동·로그아웃 후에도 이 탭에 보관됩니다.</p>
                    <strong>{recoveredDetail.title}</strong>
                    {!draft.recovery_acknowledged && <button className="native-button" onClick={() => {
                      const operation = pending.find(operation => operation.note_id === route.note);
                      if (operation) { void acknowledge(operation); return; }
                      if (!window.confirm("NAS에서 현재 저장 결과를 확인했나요? 편집본을 보관하고 자동 재전송하지 않습니다.")) return;
                      acknowledgeDraft();
                    }}>NAS 결과 확인하고 편집본 보관</button>}
                    <div className="conflict-columns">
                      <pre>{recoveredDetail.markdown ?? recoveredDetail.html}</pre>
                      <pre>{draft.title}{"\n"}{reviewDraftBody}</pre>
                    </div>
                    {draft.recovery_acknowledged && draft.markdown !== undefined && (
                      editableRecovery(recoveredDetail, draft) ?
                        <button className="native-button" onClick={() => void resumeReviewedNote()}>보관한 편집본으로 계속</button> :
                        <button className="native-button" onClick={copyReviewedNote}>보관한 본문으로 별도 노트 작성</button>
                    )}
                    <button className="native-button" disabled={writeInProgress(recoveredDetail)} onClick={() => {
                      if (!window.confirm("보관한 편집본을 버리고 확인한 NAS 내용을 사용할까요?")) return;
                      if (activeDraftKey) draftDelete(activeDraftKey);
                      setDraft(null); setEditing(false); setRecoveredDetail(null); setCompare(null);
                      setRevision(value => value + 1);
                    }}>편집본 버리고 NAS 확인본 사용</button>
                  </div>
                </div>
              )}
              {draft?.resume_paused && !draft.review_required && (
                <div className="workspace-alert warning">
                  편집본과 첨부를 확인한 뒤 저장하세요. 자동 저장이 일시 중지되었습니다.
                  {unresolvedRecoveryLinks && <p>해결되지 않은 첨부 링크가 남아 있습니다. 링크를 수정하거나 파일을 다시 선택하세요.</p>}
                  <button className="native-button" disabled={saving || composing || attachmentsBlocked || unresolvedRecoveryLinks || !editing}
                    onClick={() => {
                      if (!route.compose && !dirty) {
                        changeActiveDraft(source => ({...source, resume_paused:false}));
                        return;
                      }
                      void save(true);
                    }}>편집본 저장하고 자동 저장 재개</button>
                </div>
              )}
              {compare && !recoveredDetail && draft && (
                <div className="workspace-alert warning">
                  <div>
                    <b>버전 충돌 · 로컬 편집본을 유지했습니다</b>
                    <p>NAS 버전 {compare.version}</p>
                    <div className="conflict-columns">
                      <pre>{compare.markdown ?? compare.html}</pre>
                      <pre>{draft.markdown ?? draft.html}</pre>
                    </div>
                    <button
                      className="native-button"
                      onClick={() => {
                        if (
                          window.confirm(
                            "로컬 편집 내용을 삭제하고 NAS 최신 버전을 열까요?",
                          )
                        ) {
                          if (activeDraftKey) draftDelete(activeDraftKey);
                          setDraft(null);
                          setEditing(false);
                          setCompare(null);
                          setRevision((n) => n + 1);
                        }
                      }}
                    >
                      로컬 편집 포기하고 NAS 최신 버전 열기
                    </button>
                  </div>
                </div>
              )}
              {detail?.locked ? (
                <div className="native-empty">
                  <ShieldAlert size={30} />
                  <h2>암호화된 노트</h2>
                  <p>공식 앱에서 열어 주세요.</p>
                </div>
              ) : (
                <div className={`editor-panes mode-${viewMode}`}>
                  {viewMode !== "read" && (
                    <section className="source-pane">
                      <div className="pane-label">
                        <Code size={13} />
                        {previewMarkdown !== undefined
                          ? "MARKDOWN"
                          : "HTML 원문"}
                        {canAttach && <>
                          <button type="button" className="native-button attachment-picker"
                            onClick={() => attachmentInput.current?.click()}><Paperclip size={13} /> 파일 추가…</button>
                          <input hidden ref={attachmentInput} type="file" multiple aria-label="첨부할 파일 선택"
                            onChange={event => {
                              const view = editorRef.current?.view;
                              acceptFiles.current(Array.from(event.currentTarget.files ?? []), view?.state.selection.main.head ?? 0);
                              event.currentTarget.value = "";
                            }} />
                        </>}
                      </div>
                      {detail?.html_text_preview &&
                      draft?.text_changes !== undefined ? (
                        <OriginalEditor
                          html={detail.html_text_preview}
                          token={detail.html_text_token!}
                          blocks={detail.html_text_blocks ?? []}
                          changes={draft.text_changes}
                          editable={editing}
                          dark={dark}
                          structureDisabled={saving || dirty || composing || draft.review_required || draft.resume_paused}
                          onStructureEdit={(edit) => {
                            if (detail.html_text_layout)
                              void applyNoteAction({structure_edit:edit, text_layout:detail.html_text_layout});
                          }}
                          onChange={(change) => {
                            const original = detail.html_text_blocks?.find(
                              (b) => b.index === change.index,
                            );
                            setDraft({
                              ...draft,
                              text_changes: [
                                ...draft.text_changes!.filter(
                                  (c) => c.index !== change.index,
                                ),
                                ...(original?.text === change.text
                                  ? []
                                  : [change]),
                              ],
                            });
                          }}
                        />
                      ) : previewMarkdown !== undefined ? (
                        <CodeMirror
                          ref={editorRef}
                          aria-label="Markdown 본문"
                          value={previewMarkdown}
                          extensions={markdownExtensions}
                          theme={dark ? "dark" : "light"}
                          editable={editing}
                          onUpdate={(update) => {
                            if (editing && update.view.hasFocus && (update.selectionSet || update.docChanged))
                              setPreviewLine(update.state.doc.lineAt(update.state.selection.main.head).number);
                            if (editing && update.docChanged) changeActiveDraft(current => {
                              const markdown = update.state.doc.toString();
                              if (current.markdown === markdown) return current;
                              const uploads = current.attachments;
                              const attachments = uploads?.items.some(row => !row.inserted) ? {...uploads,
                                items: uploads.items.map(row => row.inserted ? row
                                  : {...row, position: update.changes.mapPos(Math.min(row.position, update.startState.doc.length), 1)}),
                              } : uploads;
                              return {...current, markdown, attachments};
                            });
                          }}
                          basicSetup={{
                            lineNumbers: preferences.lineNumbers,
                            foldGutter: false,
                            highlightActiveLine: false,
                          }}
                        />
                      ) : (
                        <textarea
                          id="note-html"
                          aria-label="HTML 본문"
                          value={previewHtml}
                          spellCheck={false}
                          readOnly={!editing}
                          onChange={(e) => {
                            if (draft)
                              setDraft({ ...draft, html: e.target.value });
                          }}
                        />
                      )}
                    </section>
                  )}
                  {viewMode !== "source" && (
                    <section className="preview-pane">
                      {viewMode === "split" && (
                        <div className="pane-label">
                          <Eye size={13} />
                          미리보기
                        </div>
                      )}
                      <NotePreview
                        sourceLine={editing && viewMode === "split" ? previewLine : undefined}
                        html={previewHtml}
                        markdown={previewMarkdown}
                        blocks={detail?.blocks}
                        dark={dark}
                        {...mermaidPreferences}
                        noteId={detail?.id}
                        version={detail?.version}
                        attachments={detail?.attachments}
                        bindings={detail?.attachment_bindings}
                        stagedImages={stagedImages}
                        stagedDownloads={stagedDownloads}
                        onOpenLink={(destination) =>
                          void openInternalLink(destination)
                        }
                      />
                    </section>
                  )}
                </div>
              )}
              {attachmentError && <p role="alert" className="attachment-error">{attachmentError}</p>}
              {uploads?.items.length ? <AttachmentQueue uploads={uploads} savingIds={pendingUploadIds}
                busy={saving} reviewing={reviewingUploads} composing={composing} references={referencedUploads}
                cancel={cancelUpload} discard={id => void discardReviewedUpload(id)} retry={id =>
                  patchUpload(uploads.id, id, row => ({...row, phase: "checking", error: undefined}))} /> : null}
              <footer className="native-status editor-status">
                <span>
                  {saveFailure ? "자동 저장 중단 · 편집본 보관됨" : saving ? "NAS에 자동 저장 중…"
                    : draft?.resume_paused ? "자동 저장 일시 중지"
                    : attachmentsBlocked ? "첨부파일 처리 대기 중…" : dirty ? "자동 저장 대기 중…" : route.compose ? "새 노트 작성 중" : "✓ NAS에 자동 저장됨"}
                </span>
                <span>
                  {
                    (
                      draft?.markdown ??
                      draft?.html ??
                      detail?.markdown ??
                      detail?.html ??
                      ""
                    ).length
                  }
                  자 · 버전 {detail?.version ?? "새 노트"}
                </span>
              </footer>
            </>
          )}
        </main>
        {inspector && (
          <aside className="native-inspector" aria-label="노트 정보">
            <h3>노트 정보</h3>
            <div className="inspector-card">
              <p>
                수정 <span>{dateLabel(detail?.modified_at)}</span>
              </p>
              <p>
                추가 <span>{dateLabel(detail?.created_at)}</span>
              </p>
              <p>
                변경 번호 <span>{detail?.version ?? "—"}</span>
              </p>
              <p>
                NAS 메모장{" "}
                <span>
                  {notebookById.get(detail?.notebook_id ?? "")?.name ?? "—"}
                </span>
              </p>
              <p>
                서버 ID <span>{detail?.id ?? "—"}</span>
              </p>
            </div>
            <h3>태그</h3>
            <div className="inspector-card">
              {detail?.tags?.join(" · ") || "태그 없음"}
            </div>
            {detail && !detail.locked && !detail.trashed && <button className="native-button"
              onClick={() => setRevisionNoteId(detail.id)}>수정 이력 조회</button>}
            <h3>첨부파일</h3>
            <div className="inspector-card">
              {detail?.attachments.length
                ? detail.attachments.map((file) => {
                    const protectedFile = file.id === detail.source_file_id ||
                      /^synology-note-(source|math-|upload-)/i.test(file.name) ||
                      Object.keys(detail.math_attachments ?? {}).some(uid => detail.attachment_bindings?.[uid] === file.id);
                    return <div className="inspector-attachment" key={file.id}>
                      <a href={`/api/notes/${encodeURIComponent(detail.id)}/attachments/${encodeURIComponent(file.id)}`}
                        download={file.name}><Paperclip size={14} />{file.name}</a>
                      {!protectedFile && !detail.locked && !detail.trashed && !writeInProgress(detail) &&
                        (detail.editable || detail.html_text_preview) && <button className="icon-button"
                          type="button" aria-label={`${file.name} 제거`} title="첨부파일 제거"
                          disabled={saving || dirty || hasStagedUploads || draft?.review_required || draft?.resume_paused}
                          onClick={() => {
                            if (window.confirm(`‘${file.name}’ 파일을 NAS 노트에서 제거할까요?`))
                              void applyNoteAction({remove_attachment_id:file.id});
                          }}><Trash2 size={14}/></button>}
                    </div>;
                  })
                : "첨부파일 없음"}
            </div>
            <h3>로컬 그래프 · 백링크</h3>
            {showLocalGraph && detail ? (
              <div style={{ height: 420 }}>
                <NoteGraph
                      compact
                  notebooks={notebooks}
                  focusId={detail.id}
                  onOpenNote={(id) =>
                    navigate({
                      shelf: null,
                      notebook: null,
                      note: id,
                      compose: false,
                    })
                  }
                />
              </div>
            ) : (
              <button
                className="native-button"
                disabled={!detail}
                onClick={() => setShowLocalGraph(true)}
              >
                연결 확인
              </button>
            )}
            <h3>화면</h3>
            <button className="native-button" onClick={() => setShowSettings(true)}>화면·편집기 설정…</button>
            <p className="inspector-help">
              원문과 미리보기는 같은 노트 내용을 표시합니다.
            </p>
          </aside>
        )}
      </div>
      {contextMenu && (
        <div
          className="native-context-menu"
          role="menu"
          style={{
            left: Math.min(contextMenu.x, window.innerWidth - 190),
            top: Math.min(contextMenu.y, window.innerHeight - 150),
          }}
          onMouseLeave={() => setContextMenu(null)}
        >
          <button
            onClick={() => {
              setDialogAction({
                request: {
                  kind: contextMenu.kind,
                  id: contextMenu.id,
                  action: "rename",
                },
                title:
                  contextMenu.kind === "stack"
                    ? "책장 이름 변경"
                    : "메모장 이름 변경",
                mode: "name",
                initial:
                  contextMenu.kind === "stack"
                    ? contextMenu.id
                    : notebookById.get(contextMenu.id)?.name,
              });
              setContextMenu(null);
            }}
          >
            이름 변경…
          </button>
          {contextMenu.kind === "notebook" && (
            <button
              onClick={() => {
                setDialogAction({
                  request: {
                    kind: "notebook",
                    id: contextMenu.id,
                    action: "move",
                  },
                  title: "책장으로 이동",
                  mode: "stack",
                  initial: notebookById.get(contextMenu.id)?.stack,
                });
                setContextMenu(null);
              }}
            >
              책장으로 이동…
            </button>
          )}
          <button
            onClick={() => {
              const label = contextMenu.kind === "stack" ? "책장" : "메모장";
              const name = contextMenu.kind === "stack" ? contextMenu.id : notebookById.get(contextMenu.id)?.name;
              setDialogAction({
                request: {kind: contextMenu.kind, id: contextMenu.id, action: "delete"},
                title: name ? `‘${name}’ ${label}을 삭제할까요?` : `${label}을 삭제할까요?`,
                mode: "delete",
              });
              setContextMenu(null);
            }}
          >
            {contextMenu.kind === "stack" ? "책장 삭제…" : "메모장 삭제…"}
          </button>
          <button onClick={() => setContextMenu(null)}>닫기</button>
        </div>
      )}
      {showLinkPicker && (
        <NoteLinkPicker
          notes={notes}
          notebooks={notebooks}
          current={detail?.id}
          onClose={() => setShowLinkPicker(false)}
          onSelect={(note) => {
            const view = editorRef.current?.view;
            if (view) {
              const range = view.state.selection.main;
              const label = range.empty
                ? note.title
                : view.state.doc.sliceString(range.from, range.to);
              const insert = remoteNoteLink(label, note.id);
              view.dispatch({
                changes: { from: range.from, to: range.to, insert },
                selection: { anchor: range.from + insert.length },
              });
              view.focus();
            }
            setShowLinkPicker(false);
          }}
        />
      )}
      {showGlobalSearch && <GlobalSearchDialog notes={notes} notebooks={notebooks} loading={listLoading} searchBody={searchNoteBody}
        onSelect={(id)=>navigate({shelf:null,notebook:null,note:id,compose:false},false,'')}
        onClose={()=>setShowGlobalSearch(false)} />}
      {showSettings && <SettingsDialog preferences={preferences} onChange={setPreferences} onClose={() => setShowSettings(false)} />}
      {detail && revisionNoteId === detail.id && <NoteRevisionDialog key={detail.id}
        noteId={detail.id} currentVersion={detail.version} dark={dark}
        canRestore={!saving && !dirty && !hasStagedUploads && !draft?.review_required &&
          !draft?.resume_paused && !writeInProgress(detail)}
        onRestore={version => applyNoteAction({restore_version:version})}
        onClose={() => setRevisionNoteId(null)} />}
      {dialogAction && (
        <LibraryDialog
          key={JSON.stringify(dialogAction)}
          config={dialogAction}
          notebooks={notebooks}
          busy={saving}
          onSubmit={libraryAction}
          onClose={() => setDialogAction(null)}
        />
      )}
    </div>
    </GraphNavigationProvider>
    </GraphIndexProvider>
  );
}
function ServerIcon() {
  return <FolderOpen size={18} />;
}
