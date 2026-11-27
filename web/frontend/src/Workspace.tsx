import { currentLanguage, t, translate, UiError, type Message } from "./i18n";
import { supportedLanguages } from "./catalogs";
import { editorPhrases } from "./editorPhrases";
import { NasConnectionStatus } from "./NasConnectionStatus";
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
  WebConnectionError,
  backgroundRead,
  errorText,
  jsonRequest,
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
import { annotateFormattedDraft, editFormattedDraft, escapeText, formattedSelection } from "./formattedDraft";
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
type ImportProgress = {filename:string; completed:number; total:number};
type CreateReceipt = {status:string; note?:NoteDetail; operation_id?:string};

function createStatus(status?: string): string {
  switch (status) {
    case "pending": return t("workspace.pendingVerification");
    case "uncertain": return t("workspace.saveResultUncertain");
    case "completed": return t("workspace.saveConfirmed");
    case "reviewed": return t("workspace.reviewed");
    case "absent": return t("workspace.noNoteCreated");
    default: return t("workspace.checkRequired");
  }
}

function confirmedImport({filename, completed, total}: ImportProgress): string {
  const remaining = total - completed - 1;
  return t("workspace.imported", filename, completed + 1, total, remaining > 0
    ? t("workspace.selectRemainingFilesContinue", remaining)
    : t("workspace.importConfirmed"));
}

type Draft = {
  text_changes?: TextChange[];
  formattedWrites?: FormattedWrite[];
  projected?: boolean;
  text_layout?: string;
  text_blocks?: NoteDetail["html_text_blocks"];
  client_request_id?: string;
  attachments?: DraftUploads;
  pending_upload_ids?: string[];
  create_sent?: {title:string;html:string;markdown?:string};
  importProgress?: ImportProgress;
  review_required?: boolean;
  recovery_acknowledged?: boolean;
  resume_paused?: boolean;
  key: string;
  title: string;
  initialTitle?: string;
  html: string;
  notebook_id: string;
  version?: string;
  markdown?: string;
};

type EditorCommand = {historyDirection: "undo" | "redo"} | {structureEdit: StructureEdit};
type FormattedSnapshot = {html:string; title:string; version?:string; writeId?:string};
type FormattedWrite = {id:string; result:FormattedSnapshot} &
  ({changes:TextChange[]; verify:boolean; inputTitle?:string} | {edit:StructureEdit} | {restore:Pick<FormattedSnapshot,"writeId" | "version">});
type FormattedHistory = {id:string; undo:FormattedSnapshot[]; redo:FormattedSnapshot[]};

function appendFormattedWrite(draft: Draft, write: FormattedWrite) {
  return [...(draft.formattedWrites ?? []), write];
}

function markWritten<T extends Pick<FormattedSnapshot,"writeId" | "version">>(snapshot: T, writeId: string, version: string): T {
  return snapshot.writeId === writeId ? {...snapshot, writeId:undefined, version} : snapshot;
}

function formattedTip(note: NoteDetail, draft: Draft): FormattedSnapshot {
  return draft.formattedWrites?.at(-1)?.result ??
    {html:note.html,title:note.title,version:note.version};
}

function recordFormattedEdit(history: FormattedHistory, before: FormattedSnapshot): FormattedHistory {
  return {...history, undo:[...history.undo,before].slice(-30), redo:[]};
}

const defaultUntitledTitles = new Set(supportedLanguages.map(language => translate(language, "common.untitled")));

function formattedDraftTitle(title: string, saved: string): string {
  // A restored draft can be blank even though the NAS already supplied a default title.
  return title.trim() || (defaultUntitledTitles.has(saved) ? saved : t("common.untitled"));
}

function matchesDraftTitle(title: string, saved: string): boolean {
  return formattedDraftTitle(title, saved) === saved;
}

// Every toolbar operation seals earlier typing at its queue position. Later
// typing still edits the live draft, using the operation's projected layout.
function sealFormattedText(note: NoteDetail, draft: Draft) {
  const before = formattedTip(note,draft);
  const title = formattedDraftTitle(draft.title, before.title);
  if (!draft.text_changes || (!draft.text_changes.length && matchesDraftTitle(draft.title, before.title))) return null;
  const id = requestId();
  const result = {html:exportHtml(note,draft),title,writeId:id};
  const write: FormattedWrite = {id,result,changes:draft.text_changes,verify:!!draft.projected,inputTitle:draft.title};
  const changes = new Map(draft.text_changes.map(change => [change.index,change.text]));
  let delta = 0;
  const shifted = (draft.text_blocks ?? note.html_text_blocks)?.map(block => {
    if (block.start === undefined || block.end === undefined) return block;
    const text = changes.get(block.index);
    const start = block.start + delta;
    if (text === undefined) return {...block,start,end:block.end+delta};
    const size = escapeText(text).length;
    delta += size - (block.end - block.start);
    return {...block,start,end:start+size,text};
  });
  return {before, draft:{...draft,html:result.html,text_blocks:shifted,text_changes:[],
    formattedWrites:appendFormattedWrite(draft,write)}};
}

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
      throw new UiError("errors.couldNotVerifyTextPositionOriginalHtmlYour");
    return {...change, start:block.start!, end:block.end!};
  }).sort((a,b) => b.start-a.start);
  for (const change of changes) {
    const text = escapeText(change.text);
    source = source.slice(0, change.start) + text + source.slice(change.end);
  }
  return source;
}

function reviewedFormattedWrites(note: NoteDetail, draft: Draft): FormattedWrite[] | undefined {
  const writes = draft.formattedWrites;
  const head = writes?.[0];
  if (!head || note.markdown !== undefined || !note.html_text_preview || !note.html_text_layout) return;
  if (note.version === draft.version && note.html_text_layout === draft.text_layout) return writes;
  if (note.version === draft.version || note.html !== head.result.html || note.title !== head.result.title) return;
  return writes!.slice(1).map(entry => "restore" in entry
    ? {...entry,restore:markWritten(entry.restore,head.id,note.version)} : entry);
}

function formattedRecoveryChanges(note: NoteDetail, draft: Draft): TextChange[] | undefined {
  if (draft.formattedWrites?.length || draft.text_changes === undefined || note.markdown !== undefined ||
      !note.html_text_preview || !note.html_text_layout) return undefined;
  if (!draft.text_changes.length) return [];
  if (draft.html === note.html && draft.text_layout === note.html_text_layout) return draft.text_changes;
  try {
    // A partially confirmed attachment save may already have written the body.
    // Only recover against a different layout if the whole body matches.
    if (exportHtml(note, draft) === note.html) return [];
  } catch {
    // Leave the draft in review when its source offsets cannot be trusted.
  }
  return undefined;
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
const readOnlyReasons: Record<string, Message> = {
  AMBIGUOUS_SOURCE:
    "workspace.severalMarkdownSourcesMatchNoteBodyEditableSource",
  WRITE_IN_PROGRESS:
    "workspace.nasHasUnfinishedMarkdownSaveReviewPendingSaves",
  LOCKED: "workspace.encryptedNotesCanBeEditedOfficialApp",
  TRASHED: "workspace.notesTrashCannotBeEdited",
  ATTACHMENTS:
    "workspace.thisNoteContainsAttachmentsOrMarkdownSourceMetadata",
  COMPLEX_HTML:
    "workspace.thisNoteContainsComplexHtmlFormattingOrInternal",
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
  if (route.shelf !== null) url.searchParams.set("s", route.shelf);
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
    throw new UiError("errors.someAttachmentLinksUnresolvedReplaceThoseLinksBody");
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
  const listRequestVersion = useRef(0);
  const listMutationVersion = useRef(0);
  const [libraryReady, setLibraryReady] = useState(false);
  const graphRevision = useMemo(() => JSON.stringify(notes.map(note => [note.id, note.version, note.locked, note.trashed])), [notes]);
  const [listError, setListError] = useState("");
  const [nasConnected, setNasConnected] = useState(false);
  const nasFailureGeneration = useRef(0);
  const [noteError, setNoteError] = useState("");
  const [noteActionNotice, setNoteActionNotice] = useState("");
  const [detail, setDetail] = useState<NoteDetail | null>(null);
  const [formatHistory, setFormatHistory] = useState<FormattedHistory>();
  const [formatSelection,setFormatSelection] = useState<ReturnType<typeof formattedSelection>>();
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
    editorPhrases(),
    EditorView.contentAttributes.of({"aria-label": t("workspace.markdownBody")}),
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
  const historyRoutes = useRef<Route[]>([route]);
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
  useEffect(() => {
    setPreviewLine(undefined);
    setNoteActionNotice("");
    setFormatHistory(undefined);
    setFormatSelection(undefined);
  }, [activeKey]);
  const activeDraftKey = activeKey ? draftPrefix + activeKey : null;
  const original = detail && !route.compose ? detail : null;
  const dirty = !!(
    draft &&
    activeKey === draft.key &&
    (route.compose
      ? (draft.title.trim().length > 0 && draft.title !== draft.initialTitle) ||
        draft.html !== BLANK_HTML ||
        !!draft.markdown
      : original &&
        ((draft.text_changes === undefined ? original.title !== draft.title : !matchesDraftTitle(draft.title, original.title)) ||
          original.html !== draft.html ||
          original.markdown !== draft.markdown ||
           !!draft.text_changes?.length || !!draft.formattedWrites?.length ||
           (draft.text_changes !== undefined && !!draft.attachments?.items.some(item =>
             item.phase !== "committed" && !item.recoveryOnly && item.phase !== "reviewed"))))
  );
  const readOnlyRecovery = !!(draft?.review_required && activeKey === draft.key && !editing);
  const reviewingUploads = !!(draft?.review_required && savingAction !== "note");
  const uploads = activeKey === draft?.key ? draft?.attachments : undefined;
  const referencedUploads = useMemo(() => uploads ? uploadReferences(draft?.markdown) : new Set<string>(),
    [uploads, draft?.markdown]);
  const hasStagedUploads = !!uploads?.items.some(item => item.phase !== "committed");
  const noteActionsDisabled = composing || !!saveFailure || !!draft?.resume_paused || reviewingUploads || hasStagedUploads;
  const currentHistory = detail && formatHistory?.id === detail.id ? formatHistory : undefined;
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
    if (next.attachments || next.formattedWrites?.length) draftStore(current.draftKey, next);
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
  const canAttachFormatted = !!(editing && !reviewingUploads && !route.compose && detail?.html_text_preview &&
    !detail.locked && !detail.trashed && draft?.key === activeKey && draft.text_changes !== undefined);
  const canAttach = canAttachFormatted || !!(editing && !reviewingUploads && draft?.key === activeKey &&
     draft.markdown !== undefined && (route.compose || (detail?.editable && !detail.locked && !detail.trashed)));
  const acceptFiles = useRef<(files: File[], position: number) => void>(() => {});
  acceptFiles.current = (files, position) => {
    if (!canAttach) return;
    const errors: string[] = [];
    changeActiveDraft(current => {
      if (current.markdown === undefined && current.text_changes === undefined) return current;
      const target: UploadTarget = route.compose
        ? {notebook_id: current.notebook_id, client_request_id: current.client_request_id!}
        : {notebook_id: current.notebook_id, note_id: route.note!};
      const attachments = current.attachments ?? {id: requestId(), items: []};
      const items = [...attachments.items];
      let count = items.filter(item => item.phase !== "committed").length;
      for (const file of files) {
        if (!file.size || file.size > MAX_ATTACHMENT_BYTES) {
          errors.push(`${file.name}: ${file.size ? t("workspace.exceeds50Mb") : t("workspace.fileEmpty")}`);
          continue;
        }
        if (count >= MAX_QUEUED_ATTACHMENTS) {
          errors.push(t("workspace.youCanAddUpTemporaryAttachments", MAX_QUEUED_ATTACHMENTS));
          break;
        }
        const id = requestId();
        count++;
        queue.files.set(`${attachments.id}/${id}`, file);
        items.push({id, target, name: file.name, phase: "queued", position, inserted: current.markdown === undefined});
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
        setAttachmentError(t("workspace.removeLinkThisAttachmentNoteBodyBeforeCanceling"));
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
    const action = item.phase === "missing" ? t("workspace.clearExpiredAttachment") : t("workspace.discardTemporaryFileOnWebServer");
    if (!window.confirm(`${item.name}: ${action}${linked ? " " + t("workspace.attachmentLinksNoteBodyWillBecomeFilenames") : ""}`)) return;
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
          ? t("workspace.removeRemainingAttachmentLinksOrSelectFilesAgain") : "");
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
    if (!replace) {
      historyLast.current = index;
      historyRoutes.current.length = index;
    }
    historyRoutes.current[index] = next.route;
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
    setCompare(null);
  }

  const markNasUnavailable = useCallback(() => {
    nasFailureGeneration.current += 1;
    setNasConnected(false);
  }, []);

  const handleError = useCallback(
    (error: unknown, setter: (text: string) => void) => {
      setter(errorText(error));
      if (error instanceof WebConnectionError ||
          (error instanceof ApiFailure && ["NAS_UNAVAILABLE", "NAS_ADDRESS_BLOCKED"].includes(error.code)))
        markNasUnavailable();
      if (error instanceof ApiFailure && error.status === 401)
        onSessionExpired();
    },
    [markNasUnavailable, onSessionExpired],
  );
  const searchNoteBody = useCallback((query: string, signal: AbortSignal) =>
    request<BodySearchResult>("/api/search/body", {
      ...jsonRequest({query}, {"X-CSRF-Token": session.csrf_token}), signal,
    }), [session.csrf_token]);

  const loadLists = useCallback(async (background?: AbortSignal) => {
    const failureGeneration = nasFailureGeneration.current;
    const version = background ? listRequestVersion.current : ++listRequestVersion.current;
    const mutation = listMutationVersion.current;
    // A background snapshot must not replace a newer foreground load or local write.
    const isCurrent = () => version === listRequestVersion.current &&
      (!background || (!background.aborted && !writeInFlight.current && mutation === listMutationVersion.current));
    const controller = new AbortController();
    const {signal} = controller;
    const abort = () => controller.abort();
    const timeout = window.setTimeout(abort, 60_000);
    background?.addEventListener("abort", abort);
    if (!background) setListLoading(true);
    const read = <T,>(path: string) => background ? backgroundRead<T>(path, signal) : request<T>(path, {signal});
    try {
      const [books, all] = await Promise.all([
        read<{ notebooks: Notebook[] }>("/api/notebooks"),
        read<{ notes: NoteSummary[] }>("/api/notes"),
      ]);
      if (!isCurrent()) return;
      setNotebooks(books.notebooks);
      setNotes(all.notes);
      setLibraryReady(true);
      setListError("");
      if (failureGeneration === nasFailureGeneration.current) setNasConnected(true);
    } catch (error) {
      if (isCurrent()) {
        markNasUnavailable();
        handleError(signal.aborted ? new UiError("errors.requestForNasListsTimedOut") : error, setListError);
      }
    } finally {
      window.clearTimeout(timeout);
      background?.removeEventListener("abort", abort);
      abort();
      if (!background && version === listRequestVersion.current) setListLoading(false);
    }
  }, [handleError, markNasUnavailable]);

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

  const refreshListsInBackground = useEffectEvent(async (signal: AbortSignal) => {
    if (listLoading || saving || writeInFlight.current) return false;
    await loadLists(signal);
    return true;
  });
  useEffect(() => {
    const interval = preferences.listRefreshMinutes * 60_000;
    let nextRefresh = performance.now() + interval;
    let timer: number;
    let stopped = false;
    let inFlight: AbortController | undefined;
    function schedule(minimumDelay = 0) {
      window.clearTimeout(timer);
      if (stopped || document.hidden || inFlight) return;
      const remaining = Math.ceil(nextRefresh - performance.now());
      // Browsers limit any single timer to a signed 32-bit delay.
      timer = window.setTimeout(refreshWhenDue, Math.min(2_147_483_647, Math.max(minimumDelay, remaining)));
    }
    async function refreshWhenDue() {
      if (stopped || document.hidden) return;
      if (performance.now() >= nextRefresh) {
        const controller = new AbortController();
        inFlight = controller;
        let attempted = false;
        try {
          attempted = await refreshListsInBackground(controller.signal);
        } finally {
          inFlight = undefined;
          if (attempted && !controller.signal.aborted) nextRefresh = performance.now() + interval;
          schedule(attempted ? 0 : 1_000);
        }
        return;
      }
      schedule();
    }
    function updateVisibility() {
      if (document.hidden) inFlight?.abort();
      schedule();
    }
    document.addEventListener("visibilitychange", updateVisibility);
    schedule();
    return () => {
      stopped = true;
      document.removeEventListener("visibilitychange", updateVisibility);
      window.clearTimeout(timer);
      inFlight?.abort();
    };
  }, [preferences.listRefreshMinutes]);
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
        if (current.attachmentsBlocked) setAttachmentError(t("workspace.finishOrCancelAttachmentUploadsBeforeLeaving"));
        restore();
        return;
      }
      if (current.activeKey !== destination && current.dirty) {
        if (
          !window.confirm(t("workspace.yourDraftWillBeKeptThisTabLeave"))
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
        historyRoutes.current = [next];
        writeRoute(next,0,true,location,historyScope.current);
      }
      historyRoutes.current[historyIndex.current] = next;
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
      const newNoteTitle = t("workspace.newNote");
      const initial: Draft = restored ? {...restored, attachments: restoreUploads(restored.attachments, restored.review_required)} : {
        key:activeKey, title:newNoteTitle, initialTitle:newNoteTitle, html:BLANK_HTML, markdown:"", notebook_id:route.notebook!,
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
    const failureGeneration = nasFailureGeneration.current;
    void request<NoteDetail>(`/api/notes/${encodeURIComponent(route.note!)}`)
      .then((note) => {
        if (!active) return;
        if (failureGeneration === nasFailureGeneration.current) setNasConnected(true);
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
          setMessage(t("workspace.restoredDraftSavedThisTab"));
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
        (a, b) => a.localeCompare(b, currentLanguage()),
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
        const {formats} = await backgroundRead<{formats: NoteFormat[]}>(path, signal);
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
      ? t("common.fullGraph")
      : (selectedNotebook?.name ??
        (selectedShelf !== null
          ? selectedShelf || t("common.unstackedNotebooks")
          : route.filter === "favorites"
            ? t("workspace.favorites")
            : route.filter === "trash"
              ? t("workspace.trash")
              : route.filter?.startsWith("tag:")
                ? "#" + route.filter.slice(4)
                : t("workspace.allNotes")));
  const mobilePage = route.note || route.compose ? "editor" : route.filter === "graph" ? "graph"
    : route.notebook || route.filter ? "notes" : selectedShelf !== null ? "notebooks" : "shelves";
  const mobileTitle = mobilePage === "shelves" ? t("common.stack")
    : mobilePage === "editor" && !route.notebook && !route.filter ? t("workspace.note") : listTitle;
  const mobileParentLabel = mobilePage === "editor" ? t("workspace.backNoteList")
    : mobilePage === "notes" && route.notebook ? t("workspace.backNotebooks") : t("workspace.backStacks");
  async function goToMobileParent() {
    const parent: Route = {shelf:null, notebook:null, note:null, compose:false};
    if (mobilePage === "editor") {
      parent.shelf = route.shelf;
      parent.notebook = route.notebook;
      parent.filter = route.filter;
      if (!parent.notebook && !parent.filter) {
        const id = detail?.id === route.note ? detail.notebook_id : notes.find(note => note.id === route.note)?.notebook_id;
        parent.notebook = id ?? null;
        if (!id) parent.filter = "all";
      }
    } else if (mobilePage === "notes" && route.notebook) {
      parent.shelf = selectedShelf ?? selectedNotebook?.stack ?? "";
    }
    const previous = historyRoutes.current[historyIndex.current - 1];
    if (previous && previous.shelf === parent.shelf && previous.notebook === parent.notebook &&
        previous.note === parent.note && previous.compose === parent.compose && previous.filter === parent.filter) {
      await traverseHistory(-1);
    } else {
      await navigate(parent, true, "");
    }
  }
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
      setAttachmentError(t("workspace.finishOrCancelAttachmentUploadsBeforeLeaving"));
      return;
    }
    if (direction === -1 ? historyIndex.current <= 0 : historyIndex.current >= historyLast.current) return;
    if (dirty && !canLeaveReview && (!await saveLatest.current() || saveHasMore.current)) return;
    window.history.go(direction);
  }

  async function navigate(next: Route, replace = false, search?:string): Promise<boolean> {
    if (saving || writeInFlight.current) return false;
    if (navigating.current.attachmentsBlocked && !canLeaveReview) {
      setAttachmentError(t("workspace.finishOrCancelAttachmentUploadsBeforeLeaving"));
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
    let writing = navigating.current.draft ?? draft;
    if (detail && !writing.formattedWrites?.length && writing.text_changes !== undefined) {
      try {
        const sealed = sealFormattedText(detail,writing);
        if (sealed) {
          writing = sealed.draft;
          changeActiveDraft(() => writing);
          setFormatHistory(recordFormattedEdit(currentHistory ?? {id:detail.id,undo:[],redo:[]},sealed.before));
        }
      } catch (error) {
        setSaveFailure("safe");
        handleError(error,setNoteError);
        return false;
      }
    }
    const head = writing.formattedWrites?.[0];
    const restore = head && "restore" in head ? head.restore : undefined;
    if (restore && !restore.version) {
      setSaveFailure("safe");
      setNoteError(t("workspace.couldNotVerifyNasVersionRestoreYourDraft"));
      return false;
    }
    const manifest = head && !("changes" in head) ? [] :
      uploadManifest(writing.attachments, writing.markdown, detail?.attachment_bindings, writing.text_changes !== undefined);
    const sentUploads = manifest.map(entry => entry.upload_id);
    let sent = writing;
    const sentKey = activeKey!;
    const sentStorageKey = activeDraftKey;
    let mutationStarted = false;
    writeInFlight.current = true;
    setSavingAction("note");
    setNoteError("");
    setCompare(null);
    if (dirty) draftStore(activeDraftKey, writing);
    try {
      const url = isNew
        ? "/api/notes"
        : `/api/notes/${encodeURIComponent(route.note!)}`;
      const mathImages = writing.markdown === undefined ? [] : await exportMath(writing.markdown, session.csrf_token);
      // Persist the unresolved state before the network call, including edits
      // made while the request is pending. Reload must never blindly replay it.
      sent = {...writing, review_required:true, recovery_acknowledged:false, pending_upload_ids: sentUploads,
        ...(isNew ? {client_request_id:writing.client_request_id ?? requestId(),
          create_sent:{title:writing.title,html:writing.html,markdown:writing.markdown}} : {})};
      const fallbackTitle = isNew ? (writing.initialTitle ?? t("workspace.newNote"))
        : writing.text_changes !== undefined && detail ? formattedDraftTitle("", detail.title)
        : t("common.untitled");
      const next = await request<NoteDetail>(
        url,
        jsonRequest(
          {
            title: head?.result.title ?? (writing.title.trim() || fallbackTitle),
            ...(isNew ? {client_request_id:sent.client_request_id} : {}),
            ...(restore ? {restore_version:restore.version}
              : head && "edit" in head ? {structure_edit:head.edit, text_layout:writing.text_layout,
                expected_html:head.result.html}
              : writing.text_changes !== undefined ? {
                  text_changes: head && "changes" in head ? head.changes : writing.text_changes,
                  text_layout:writing.text_layout,
                  ...(head && "changes" in head && head.verify ? {expected_html:head.result.html} : {}),
                }
              : writing.markdown !== undefined
                ? { markdown: writing.markdown, ...(mathImages.length ? { math_images: mathImages } : {}) }
                : { html: writing.html }),
            notebook_id: writing.notebook_id,
            ...(manifest.length ? {draft_id: writing.attachments!.id, uploads: manifest} : {}),
            ...(!isNew
              ? { version: writing.version ?? "unknown-draft-base" }
              : {}),
          },
          { "X-CSRF-Token": session.csrf_token },
          isNew ? "POST" : "PUT",
        ),
        () => {
          const latest = navigating.current.draft;
          const held = !latest || latest === writing ? sent : {
            ...latest, review_required:true, recovery_acknowledged:false,
            client_request_id:sent.client_request_id, create_sent:sent.create_sent, pending_upload_ids: sentUploads,
          };
          draftStore(sentStorageKey, held);
          const persisted = draftRead(sentStorageKey);
          if (!persisted?.review_required || (isNew && persisted.client_request_id !== sent.client_request_id) ||
              (head && (persisted.formattedWrites?.[0]?.id !== head.id ||
                persisted.formattedWrites?.at(-1)?.id !== held.formattedWrites?.at(-1)?.id)))
            throw new UiError("errors.yourDraftCouldNotBeStoredThisTab");
          changeActiveDraft(() => held);
          mutationStarted = true;
        },
      );
      const latest = navigating.current.draft;
      if (navigating.current.activeKey !== sentKey || !latest) return true;
      if (head && (latest.formattedWrites?.[0]?.id !== head.id || next.html !== head.result.html ||
          next.title !== head.result.title)) throw new ApiFailure("WRITE_UNCERTAIN",409);
      const remaining = head ? latest.formattedWrites!.slice(1).map(entry => "restore" in entry
        ? {...entry,restore:markWritten(entry.restore,head.id,next.version)} : entry) : undefined;
      // held can include edits made while preparing math images for sent.
      const unchanged = latest === sent;
      const attachments = savedAttachments(latest.attachments, sentUploads, isNew ? next : undefined);
      const key = isNew ? `note:${next.id}` : sentKey;
      const rebased: Draft = head ? {
        ...latest, version:next.version, review_required:false, recovery_acknowledged:false, resume_paused:false,
        attachments, pending_upload_ids:undefined, formattedWrites:remaining,
        text_layout:next.html_text_layout,
        title:"changes" in head && latest.title === head.inputTitle ? next.title : latest.title,
        // Keep the projected editor and text coordinates while later edits
        // depend on it. The latest verified response becomes the base version.
        ...(remaining?.length || latest.text_changes?.length ? {} : {
          projected:false, text_blocks:next.html_text_blocks, html:next.html,
        }),
      } : unchanged ? {
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
      const titlePending = head ? !matchesDraftTitle(rebased.title, next.title) : rebased.title !== next.title;
      saveHasMore.current = titlePending || rebased.html !== next.html || rebased.markdown !== next.markdown || !!rebased.text_changes?.length || !!remaining?.length ||
        !!attachments?.items.some(item => uploadBlocksSave(item, rebasedReferences, false, next.attachment_bindings));
      draftDelete(sentStorageKey);
      if (!unchanged || saveHasMore.current || attachments?.items.some(item => item.phase !== "committed")) draftStore(draftPrefix + key, rebased);
      setSaveFailure(null);
      if (head) {
        setFormatHistory(history => history?.id === next.id ? {...history,
          undo:history.undo.map(snapshot => markWritten(snapshot,head.id,next.version)),
          redo:history.redo.map(snapshot => markWritten(snapshot,head.id,next.version)),
        } : history);
      }
      setDetail(next); setDraft(rebased);
      const summary = {...next, is_markdown: typeof next.markdown === "string"};
      listMutationVersion.current += 1;
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
    if (draft.formattedWrites?.length) {
      void saveLatest.current();
      return;
    }
    const timer = window.setTimeout(() => { void saveLatest.current(); }, 800);
    return () => window.clearTimeout(timer);
  }, [draft, dirty, editing, saving, composing, saveFailure, attachmentsBlocked]);

  async function recoverCreate(saved: Draft, storageKey: string, active = () => true) {
    if (!saved.client_request_id) return;
    try {
      const receipt = await request<CreateReceipt>(
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
      listMutationVersion.current += 1;
      setNotes(notes => notes.some(row => row.id === summary.id)
        ? notes.map(row => row.id === summary.id ? {...row, ...summary} : row) : [...notes, summary]);
      setSaveFailure(null);
      commitRoute({shelf:route.shelf,notebook:note.notebook_id,note:note.id,compose:false}, true);
      if (saved.importProgress) setMessage(confirmedImport(saved.importProgress));
    } catch (error) { if (active()) handleError(error, setNoteError); }
  }

  function restartReviewedCreate() {
    if (!draft || !activeDraftKey || !["reviewed", "absent"].includes(createReceipt?.status ?? "")) return;
    const pause = !!(draft.attachments?.items.length || draft.pending_upload_ids?.length || recoveryUploadReferences(draft.markdown).size);
    if (!window.confirm(pause
      ? t("workspace.originalDraftStaysThisTabOpenSeparateDraft")
      : t("workspace.originalDraftStaysThisTabCreateSeparateNote"))) return;
    try {
      const next = separateDraft(draft, pause);
      const heldKey = `${activeDraftKey}:held:${draft.client_request_id}`;
      draftStore(heldKey, draft);
      if (!draftRead(heldKey)) throw new UiError("errors.couldNotKeepOriginalDraftThisTab");
      draftStore(activeDraftKey, next);
      if (draftRead(activeDraftKey)?.client_request_id !== next.client_request_id)
        throw new UiError("errors.couldNotKeepNewDraftThisTab");
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
      if (draftRead(key)) throw new UiError("errors.reviewExistingNewNoteDraftThisNotebookBefore");
      if (!window.confirm(t("workspace.originalNoteAndDraftWillBeKeptCreate"))) return;
      draftStore(key, next);
      if (draftRead(key)?.client_request_id !== next.client_request_id)
        throw new UiError("errors.couldNotKeepNewDraftThisTab");
      commitRoute({shelf:route.shelf, notebook:next.notebook_id, note:null, compose:true});
    } catch (error) {
      handleError(error, setNoteError);
    }
  }

  function editableRecovery(note: NoteDetail, source: Draft): boolean {
    return note.id === route.note && note.notebook_id === source.notebook_id &&
      !note.locked && !note.trashed && !writeInProgress(note) && !!note.version &&
      (source.markdown !== undefined ? note.editable && note.markdown !== undefined
        : reviewedFormattedWrites(note,source) !== undefined || formattedRecoveryChanges(note, source) !== undefined);
  }

  async function resumeReviewedNote() {
    if (!draft?.recovery_acknowledged || !activeDraftKey || !recoveredDetail || !editableRecovery(recoveredDetail, draft) ||
        saving || writeInFlight.current || composingNow.current) return;
    try {
      const fresh = await request<NoteDetail>(`/api/notes/${encodeURIComponent(recoveredDetail.id)}`);
      const current = navigating.current;
      const source = current.draft;
      if (current.draftKey !== activeDraftKey || !source?.review_required || !source.recovery_acknowledged) return;
      setRecoveredDetail(fresh); setCompare(fresh);
      if (!editableRecovery(fresh, source) || fresh.version !== recoveredDetail.version) {
        setNoteError(t("workspace.nasCopyHasChangedReviewLatestContentsAnd"));
        return;
      }
      const formatted = source.markdown === undefined;
      if (!window.confirm(formatted
        ? t("workspace.openSavedDraftUsingVerifiedNasCopyPreviously")
        : t("workspace.draftWillOpenUsingLatestVerifiedNasCopy"))) return;
      const remaining = reviewedFormattedWrites(fresh,source);
      const needsProjection = !!remaining && (!!remaining.length || !!source.text_changes?.length);
      const next: Draft = {
        ...source, version:fresh.version, html:needsProjection ? source.html : fresh.html,
        ...(remaining ? {
          formattedWrites:remaining, projected:needsProjection && source.projected,
          text_layout:fresh.html_text_layout,
          text_blocks:needsProjection ? source.text_blocks : fresh.html_text_blocks,
        } : formatted ? {
          text_changes:formattedRecoveryChanges(fresh, source),
          text_layout:fresh.html_text_layout, text_blocks:fresh.html_text_blocks,
        } : {markdown:recoveryMarkdown(source.markdown!, id => !fresh.attachment_bindings?.[id])}),
        review_required:false, recovery_acknowledged:false, resume_paused:true, pending_upload_ids:undefined,
        attachments:source.attachments && {...source.attachments,
          items:source.attachments.items.map(item => ({...item, recoveryOnly:true}))},
      };
      const heldKey = `${activeDraftKey}:held:${requestId()}`;
      draftStore(heldKey, source);
      if (!draftRead(heldKey)) throw new UiError("errors.couldNotKeepOriginalDraftThisTab");
      draftStore(activeDraftKey, next);
      if (!draftRead(activeDraftKey)?.resume_paused) throw new UiError("errors.couldNotKeepRecoveredDraftThisTab");
      if (remaining) {
        const confirmed = source.formattedWrites?.[0];
        if (confirmed && fresh.version !== source.version)
          setFormatHistory(history => history?.id === fresh.id ? {...history,
            undo:history.undo.map(snapshot => markWritten(snapshot,confirmed.id,fresh.version)),
            redo:history.redo.map(snapshot => markWritten(snapshot,confirmed.id,fresh.version)),
          } : history);
      }
      setDetail(fresh); setDraft(next); setEditing(true);
      if (!formatted) setViewMode("split");
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
        t("workspace.haveYouVerifiedSaveResultForOnNas", operation.title),
      )
    )
      return;
    try {
      await request(
        `/api/writes/${encodeURIComponent(operation.operation_id)}/ack`,
        jsonRequest({}, { "X-CSRF-Token": session.csrf_token }),
      );
      setMessage(t("workspace.markedPendingWriteAsReviewed"));
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
      setAttachmentError(t("workspace.finishOrCancelAttachmentUploadsBeforeSigningOut"));
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
  async function applyNoteAction(action: {remove_attachment_id: string} | {restore_version: string}): Promise<string | undefined> {
    if (!detail || !draft || dirty || saving || writeInFlight.current || hasStagedUploads ||
        draft.review_required || draft.resume_paused || composingNow.current)
      return t("common.reviewDraftAndAnyPendingSaveFirst");
    writeInFlight.current = true;
    setSavingAction("note-action");
    setNoteError("");
    try {
      const next = await request<NoteDetail>(`/api/notes/${encodeURIComponent(detail.id)}`, jsonRequest({
        title: detail.title, notebook_id: detail.notebook_id, version: detail.version,
        ...action,
      }, {"X-CSRF-Token":session.csrf_token}, "PUT"));
      if (next.version !== detail.version) setFormatHistory(undefined);
      setDetail(next);
      setDraft({...draft, title:next.title, html:next.html, markdown:next.markdown, version:next.version, notebook_id:next.notebook_id,
        text_changes:next.html_text_preview ? [] : undefined,
        text_layout:next.html_text_layout, text_blocks:next.html_text_blocks});
      listMutationVersion.current += 1;
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
  function queueNoteAction(command: EditorCommand) {
    const current = navigating.current.draft;
    if (!detail || !current || current.key !== activeKey || detail.id !== route.note ||
        !editing || noteActionsDisabled || composingNow.current) return;
    setNoteActionNotice("");
    try {
      let history = currentHistory ?? {id:detail.id,undo:[],redo:[]};
      const sealed = sealFormattedText(detail,current);
      const before = sealed?.draft ?? current;
      if (sealed) history = recordFormattedEdit(history,sealed.before);
      const tip = formattedTip(detail,before);
      const id = requestId();
      let write: FormattedWrite;
      let focus: ReturnType<typeof formattedSelection>;
      const token = "local-" + id;
      let preview;
      if ("structureEdit" in command) {
        const blocks = before.text_blocks?.filter((block): block is typeof block & {start:number;end:number} =>
          block.start !== undefined && block.end !== undefined);
        const updated = editFormattedDraft(tip.html,command.structureEdit,blocks?.length ? blocks : undefined);
        if (updated.html === tip.html) return;
        write = {id,result:{html:updated.html,title:tip.title,writeId:id},edit:command.structureEdit};
        preview = annotateFormattedDraft(updated.html,token);
        if (updated.focus) focus = formattedSelection(preview.blocks,updated.html,updated.focus);
        history = recordFormattedEdit(history,tip);
      } else {
        const direction = command.historyDirection;
        const target = history[direction].at(-1);
        if (!target) {
          setNoteActionNotice(direction === "undo" ? t("workspace.noEditsUndo") : t("workspace.noEditsRedo"));
          return;
        }
        write = {id,result:{html:target.html,title:target.title,writeId:id},
          restore:{version:target.version,writeId:target.writeId}};
        preview = annotateFormattedDraft(target.html,token);
        const other = direction === "undo" ? "redo" : "undo";
        history = {...history,[direction]:history[direction].slice(0,-1),[other]:[...history[other],tip].slice(-30)};
      }
      setFormatHistory(history);
      setFormatSelection(focus);
      changeActiveDraft(() => ({...before,html:write.result.html,title:write.result.title,
        text_blocks:preview.blocks,text_changes:[],projected:true,formattedWrites:appendFormattedWrite(before,write)}));
    } catch (error) {
      setNoteActionNotice(errorText(error));
    }
  }

  async function importMarkdown(files: File[]) {
    if (!files.length || !selectedNotebook || route.compose || saving || writeInFlight.current) return;
    const destination = selectedNotebook.id;
    const key = `new:${destination}`;
    const storageKey = draftPrefix + key;
    if (dirty || hasStagedUploads || draft?.review_required || draft?.resume_paused || draftRead(storageKey)) {
      setMessage(t("workspace.reviewYourCurrentOrSavedDraftBeforeImporting"));
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
          review_required:true, create_sent:source,
          importProgress:{filename, completed:imported, total:files.length}};
        latest = await request<NoteDetail>("/api/notes", jsonRequest({
          title, markdown, notebook_id:destination, client_request_id,
          ...(math_images.length ? {math_images} : {}),
        }, {"X-CSRF-Token":session.csrf_token}), () => {
          draftStore(storageKey, sent);
          if (draftRead(storageKey)?.client_request_id !== client_request_id) {
            throw new UiError("errors.importStoppedBecauseDraftCouldNotBeKept");
          }
          held = sent;
        });
        draftDelete(storageKey);
        held = undefined;
        imported += 1;
      }
      if (latest) commitRoute({shelf: route.shelf, notebook: destination, note: latest.id, compose: false});
      setMessage(t("workspace.markdownNotesImported", imported));
    } catch (error) {
      const rejected = error instanceof ApiFailure && [400, 401, 403, 413, 422].includes(error.status);
      if (held && rejected) {
        draftDelete(storageKey);
        held = undefined;
      }
      if (held) {
        const receipt = await request<CreateReceipt>(`/api/creates/${encodeURIComponent(held.client_request_id!)}`)
          .catch(() => null);
        if (receipt?.status === "completed" && receipt.note) {
          const recovered = receipt.note;
          draftDelete(storageKey);
          imported += 1;
          createdDraft.current = {note:recovered, draft:{key:`note:${recovered.id}`, title:recovered.title,
            html:recovered.html, markdown:recovered.markdown, notebook_id:recovered.notebook_id, version:recovered.version}};
          commitRoute({shelf:route.shelf, notebook:recovered.notebook_id, note:recovered.id, compose:false});
          setMessage(confirmedImport(held.importProgress!));
          return;
        }
        setMessage(t("workspace.checkingIfNoteWasCreatedOnNas", filename));
        commitRoute({shelf: route.shelf, notebook: destination, note: null, compose: true});
        void loadPending();
      } else {
        handleError(error, message => setMessage(t("workspace.imported", filename, imported, files.length, message)));
      }
    } finally {
      if (imported) await loadLists();
      writeInFlight.current = false;
      setSavingAction(null);
    }
  }

  async function libraryAction(action: LibraryAction) {
    if (saving || writeInFlight.current) throw new UiError("errors.waitForCurrentSaveFinishThenTryAgain");
    if (dirty)
      throw new UiError("errors.saveOrDiscardYourEditsBeforeContinuing");
    if (action.kind === "notebook" && action.action === "delete" &&
        (hasStagedUploads || draft?.review_required || draft?.resume_paused))
      throw new UiError("errors.reviewSavedDraftAndAttachmentsFirst");
    listMutationVersion.current += 1;
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
    catch { reviewDraftBody = t("workspace.verifySourcePosition") + JSON.stringify(draft.text_changes, null, 2); }
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
  const formattedNote = !!detail?.html_text_preview && previewMarkdown === undefined;
  const displayedMode = formattedNote ? "source" : viewMode;
  const localPreview = useMemo(() => draft?.projected
    ? annotateFormattedDraft(draft.html,"local-" + (draft.formattedWrites?.at(-1)?.id ?? draft.version))
    : undefined, [draft?.projected,draft?.html,draft?.formattedWrites,draft?.version]);
  const bodyAttachmentPath = useCallback((reference: string) => {
    if (!detail) return undefined;
    const key = reference.toLowerCase();
    const files = detail.attachments.filter(file => file.id.toLowerCase() === key || file.ref?.toLowerCase() === key);
    return files.length === 1
      ? `/api/notes/${encodeURIComponent(detail.id)}/attachments/${encodeURIComponent(files[0].id)}`
      : undefined;
  }, [detail]);
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
      <span>{book.name || t("workspace.unnamedNotebook")}</span>
    </button>
  );
  return (
    <GraphIndexProvider key={JSON.stringify([status.nas_url, session.username])} enabled={libraryReady} revision={graphRevision}>
    <GraphNavigationProvider state={graphState} onChange={changeGraphState}>
    <div className={`native-app ${dark ? "native-dark" : ""} ${sidebarCollapsed ? "sidebar-collapsed" : ""} ${listCollapsed ? "list-collapsed" : ""}`}
      onCompositionStart={() => { composingNow.current = true; setComposing(true); }}
      onCompositionEnd={() => { composingNow.current = false; setComposing(false); }}
      style={{ "--editor-font-size": `${preferences.editorFontSize}px` } as CSSProperties}>
      <header className="native-toolbar" data-mobile-page={mobilePage}>
        <div className="panel-controls" role="group" aria-label={t("workspace.panelVisibility")}>
            <button className="icon-button panel-toggle panel-toggle-sidebar" aria-label={sidebarCollapsed ? t("workspace.expandStackPanel") : t("workspace.collapseStackPanel")}
              aria-expanded={!sidebarCollapsed} aria-controls="workspace-sidebar" title={sidebarCollapsed ? t("workspace.expandStackPanel") : t("workspace.collapseStackPanel")}
              onClick={() => {setSidebarCollapsed(!sidebarCollapsed); savePreference("sidebarCollapsed", !sidebarCollapsed);}}>
              {sidebarCollapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
            </button>
            <button className="icon-button panel-toggle panel-toggle-list" aria-label={listCollapsed ? t("workspace.expandNoteList") : t("workspace.collapseNoteList")}
              aria-expanded={!listCollapsed} aria-controls="workspace-note-list" title={listCollapsed ? t("workspace.expandNoteList") : t("workspace.collapseNoteList")}
              onClick={() => {setListCollapsed(!listCollapsed); savePreference("noteListCollapsed", !listCollapsed);}}>
              {listCollapsed ? <PanelLeftOpen size={18} /> : <PanelLeftClose size={18} />}
            </button>
        </div>
        <div className="toolbar-sidebar">
          {mobilePage !== "shelves" && <button className="icon-button mobile-parent"
            aria-label={mobileParentLabel} title={mobileParentLabel} disabled={saving}
            onClick={() => void goToMobileParent()}>
            <ArrowLeft size={18} />
          </button>}
          <span className="mobile-page-title">{mobileTitle}</span>
          <span className="workspace-brand" title="Synology Markdown Note">
            <AppIcon size={24} />
            <b>Markdown Note</b>
          </span>
        </div>
        <div className="toolbar-list">{listTitle}</div>
        <div className="toolbar-actions">
          <div className="toolbar-group">
            <button
              className="icon-button desktop-history"
              aria-label={t("workspace.previousScreen")}
              disabled={saving || historyBounds.index === 0}
              onClick={() => void traverseHistory(-1)}
            >
              <ArrowLeft size={18} />
            </button>
            <button
              className="icon-button desktop-history"
              aria-label={t("workspace.nextScreen")}
              disabled={saving || historyBounds.index >= historyBounds.last}
              onClick={() => void traverseHistory(1)}
            >
              <ArrowRight size={18} />
            </button>
            <button
              className="icon-button notebook-action"
              aria-label={t("workspace.newNote")}
              disabled={saving || !selectedNotebook}
              title={selectedNotebook ? t("workspace.newNote") : t("common.selectNotebook")}
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
            <button className="icon-button notebook-action" aria-label={t("workspace.importMarkdown")}
              title={selectedNotebook ? t("workspace.importMarkdown") : t("common.selectNotebook")}
              disabled={saving || !selectedNotebook || route.compose}
              onClick={() => markdownImportInput.current?.click()}>
              <FileUp size={18} />
            </button>
            <input hidden ref={markdownImportInput} type="file" multiple
              accept=".md,.markdown,text/markdown" aria-label={t("workspace.selectMarkdownFilesImport")}
              onChange={event => {
                const files = Array.from(event.currentTarget.files ?? []);
                event.currentTarget.value = "";
                void importMarkdown(files);
              }} />
            <button
              className="icon-button"
              aria-label={t("workspace.globalSearch")}
              title={t("common.searchAllNotes")}
              onClick={() => {
                setShowGlobalSearch(true);
                void loadLists();
              }}
            >
              <Search size={19} />
            </button>
          </div>
          {!formattedNote && <div className="mode-picker" aria-label={t("workspace.viewMode")}>
            {(["source", "split", "read"] as const).map((m, i) => (
              <button
                key={m}
                aria-pressed={viewMode === m}
                onClick={() => chooseMode(m)}
              >
                {[t("workspace.source"), t("workspace.split"), t("workspace.reading")][i]}
              </button>
            ))}
          </div>}
          <div className="toolbar-group">
            <button
              className="icon-button note-info-action"
              aria-label={t("workspace.noteInformation")}
              aria-pressed={inspector}
              onClick={() => setInspector(!inspector)}
            >
              <PanelRight size={19} />
            </button>
            <button
              className="icon-button"
              aria-label={t("workspace.refresh")}
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
              title={t("workspace.signOut")}
              aria-label={t("workspace.signOut")}
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
          aria-label={t("workspace.writesPendingVerification")}
        >
          <ShieldAlert size={16} />
          <div>
            <b>{t("workspace.nasWritesVerify", pending.length)}</b>
            <p>
              {t("workspace.verifySaveResultNoteStationBeforeClearingHold")}
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
                {op.title}{" "}{t("workspace.clearHoldAfterCheckingNas")}
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
      <div className={`native-columns ${inspector ? "with-inspector" : ""}`} data-mobile-page={mobilePage}>
        <aside
          id="workspace-sidebar"
          className="native-sidebar"
          data-mobile-unfiled={selectedShelf === "" ? "" : undefined}
          aria-label={t("workspace.stacksAndNotebooks")}
        >
          <div className="sidebar-scroll">
            <button
              className={`native-nav mobile-shelves-only ${(!route.filter || route.filter === "all") && selectedShelf === null && !route.notebook ? "selected" : ""}`}
              onClick={() => selectFilter(window.matchMedia?.("(max-width: 800px)").matches ? "all" : undefined)}
            >
              <FileText size={16} />
              <span>{t("workspace.allNotes")}</span>
            </button>
            <button
              className={`native-nav mobile-shelves-only ${route.filter === "favorites" ? "selected" : ""}`}
              onClick={() => selectFilter("favorites")}
            >
              <Star size={16} />
              <span>{t("workspace.favorites")}</span>
            </button>
            <button
              className={`native-nav mobile-shelves-only ${route.filter === "graph" ? "selected" : ""}`}
              onClick={() => selectFilter("graph")}
            >
              <Network size={16} />
              <span>{t("common.fullGraph")}</span>
            </button>
            <div className="sidebar-section mobile-shelves-only">{t("workspace.stacksNotebooks")}</div>
            <div className="sidebar-create-actions mobile-shelves-only" role="group" aria-label={t("workspace.addStackOrNotebook")}>
            <button
              className="sidebar-create-button"
              disabled={saving}
              onClick={() =>
                setDialogAction({
                  request: { kind: "stack", action: "create" },
                  title: t("workspace.createNewStack"),
                  mode: "createStack",
                })
              }
            >
              <FolderPlus size={16} />
              <span>{t("workspace.createStack")}</span>
            </button>
            <button
              className="sidebar-create-button"
              disabled={saving}
              onClick={() =>
                setDialogAction({
                  request: { kind: "notebook", action: "create" },
                  title: t("workspace.addNotebook"),
                  mode: "name",
                })
              }
            >
              <BookPlus size={16} />
              <span>{t("workspace.addNotebookShortcut")}</span>
            </button>
            </div>
            {shelves.filter(Boolean).map((stack) => (
              <div
                key={stack}
                className="stack-group"
                data-selected-shelf={selectedShelf === stack ? "" : undefined}
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
                    aria-label={expandedStacks.includes(stack) ? t("workspace.collapseStack", stack) : t("workspace.expandStack", stack)}
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
                {(expandedStacks.includes(stack) || mobilePage === "notebooks" && selectedShelf === stack) && (
                  <div className={`stack-notebooks ${expandedStacks.includes(stack) ? "" : "mobile-only"}`}>
                    {notebooks
                      .filter((b) => b.stack === stack)
                      .sort((a, b) =>
                        a.name.localeCompare(b.name, currentLanguage(), { numeric: true }),
                      )
                      .map(renderNotebook)}
                  </div>
                )}
              </div>
            ))}
            <button className="native-nav mobile-only mobile-shelves-only" onClick={() =>
              void navigate({shelf:"",notebook:null,note:null,compose:false})}>
              <FolderOpen size={16} />
              <span>{t("common.unstackedNotebooks")}</span>
            </button>
            <div className="unfiled-notebooks">
              <div className="sidebar-subheading">
                <FolderOpen size={14} />
                {t("common.unstackedNotebooks")}
              </div>
              {notebooks.filter(book => !book.stack).sort((a, b) =>
                a.name.localeCompare(b.name, currentLanguage(), {numeric:true})).map(renderNotebook)}
            </div>
            {mobilePage === "notebooks" && !listLoading && !notebooks.some(book => (book.stack || "") === selectedShelf) &&
              <p className="sidebar-status mobile-only">{t("workspace.thereNoNotebooksThisStack")}</p>}
            {listLoading && <p className="sidebar-status">{t("workspace.loading")}</p>}
            {!!tags.length && (
              <>
                <div className="sidebar-section mobile-shelves-only">{t("workspace.tags")}</div>
                {tags.map((tag) => (
                  <button
                    key={tag}
                    className={`native-nav mobile-shelves-only ${route.filter === "tag:" + tag ? "selected" : ""}`}
                    onClick={() => selectFilter("tag:" + tag)}
                  >
                    <Tag size={14} />
                    <span>{tag}</span>
                  </button>
                ))}
              </>
            )}
            <button
              className={`native-nav trash-nav mobile-shelves-only ${route.filter === "trash" ? "selected" : ""}`}
              onClick={() => selectFilter("trash")}
            >
              <Trash2 size={16} />
              <span>{t("workspace.trash")}</span>
            </button>
          </div>
          <div className="account-footer">
            <div>
              <b>{session.username}</b>
              <p>{nasConnected ? t("workspace.nasConnectedAvailable") : t("common.disconnectedNas")}</p>
            </div>
            <button
              className="icon-button"
              aria-label={t("common.settings")}
              aria-haspopup="dialog"
              aria-expanded={showSettings}
              onClick={() => setShowSettings(true)}
            >
              <Settings size={17} />
            </button>
          </div>
        </aside>
        <section id="workspace-note-list" className="native-list" aria-label={t("workspace.noteList")}>
          {route.filter === "graph" ? <GraphNavigationPanel notebooks={notebooks} onOpenNote={(id) => navigate({shelf:null,notebook:null,note:id,compose:false})} /> : <>
          <div className="list-controls">
            <label className="native-search">
              <Search size={15} />
              <input
                id="library-search"
                aria-label={t("workspace.searchNotes")}
                placeholder={t("workspace.searchNotes")}
                value={query}
                onChange={(e) => changeQuery(e.target.value)}
              />
              {query && (
                <button aria-label={t("workspace.clearSearch")} onClick={() => changeQuery("")}>
                  <X size={13} />
                </button>
              )}
            </label>
            <div className="list-sort">
              <select
                aria-label={t("workspace.sortNotesBy")}
                value={sortField}
                onChange={(e) => {
                  setSortField(e.target.value as SortField);
                  savePreference("noteListSortField", e.target.value);
                }}
              >
                <option value="title">{t("workspace.title")}</option>
                <option value="createdAt">{t("workspace.dateAdded")}</option>
                <option value="modifiedAt">{t("workspace.dateModified")}</option>
              </select>
              <select
                aria-label={t("workspace.noteSortOrder")}
                value={sortDirection}
                onChange={(e) => {
                  setSortDirection(e.target.value as SortDirection);
                  savePreference("noteListSortDirection", e.target.value);
                }}
              >
                <option value="ascending">{t("workspace.ascending")}</option>
                <option value="descending">{t("workspace.descending")}</option>
              </select>
            </div>
          </div>
          {listError && (
            <div role="alert" className="workspace-alert error">
              {listError}
              <button onClick={() => void loadLists()}>{t("workspace.retry")}</button>
            </div>
          )}
          <div className="list-scroll">
            {listLoading ? (
              <p className="empty-list">{t("common.loadingNotes")}</p>
            ) : !visibleNotes.length ? (
              <p className="empty-list">
                {query ? t("common.noResults") : t("workspace.noNotes")}
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
                    <b>{note.title || t("common.untitled")}</b>
                    {noteHasMarkdown(note) && (
                      <span className="md-badge">MD</span>
                    )}
                  </div>
                  <p className="note-excerpt">
                    {note.excerpt?.replace(/<[^>]*>/g, "") ||
                      notebookById.get(note.notebook_id)?.name ||
                      t("workspace.richTextNote")}
                  </p>
                  <small>
                    {sortField === "createdAt"
                      ? (note.created_at ? t("workspace.dateAddedLabel") : t("workspace.dateAddedUnavailableModified")) + " "
                      : ""}
                    {dateLabel(
                      sortField === "createdAt"
                        ? (note.created_at ?? note.modified_at)
                        : note.modified_at,
                    )}
                    {note.locked ? " " + t("workspace.encrypted") : ""}
                  </small>
                </button>
              ))
            )}
          </div>
          </>}
          <footer className="native-status">
            {route.filter !== "graph" && <span>{t("workspace.notes", visibleNotes.length)}</span>}
            <GraphIndexStatus />
          </footer>
        </section>
        <main className="native-detail" aria-label={t("workspace.noteBody")}
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
              <h2>{t("workspace.selectNote")}</h2>
              <p>{t("workspace.selectNoteStackOrNotebook")}</p>
            </div>
          ) : noteLoading ? (
            <div className="native-empty">
              <RefreshCw size={24} className="animate-spin" />
              <p>{t("workspace.loadingNoteBodyNas")}</p>
            </div>
          ) : (
            <>
              <div className="editor-heading">
                <div className="editor-title-row">
                  {(editing || readOnlyRecovery) && draft ? (
                    <input
                      id="note-title"
                      readOnly={!editing}
                      aria-label={t("workspace.noteTitle")}
                      required
                      maxLength={256}
                      value={draft.title}
                      placeholder={t("workspace.title")}
                      onChange={(e) =>
                        changeActiveDraft(current => ({ ...current, title: e.target.value }))
                      }
                    />
                  ) : (
                    <h1>{detail?.title || t("common.untitled")}</h1>
                  )}
                  <div className="editor-tools">
                    {editing && draft?.markdown !== undefined && (
                      <button
                        className="icon-button"
                        aria-label={t("common.linkNote")}
                        disabled={saving || displayedMode === "read"}
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
                              ? t("workspace.removeFavorites")
                              : t("workspace.favorites")
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
                            aria-label={t("workspace.noteActions")}
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
                                  title: t("workspace.moveNote"),
                                  mode: "notebook",
                                  initial: detail.notebook_id,
                                })
                              }
                            >
                              {t("workspace.moveAnotherNotebook")}
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
                                  title: t("workspace.editTags"),
                                  mode: "tags",
                                  initial: (
                                    detail.tags ??
                                    selectedSummary?.tags ??
                                    []
                                  ).join(", "),
                                })
                              }
                            >
                              {t("workspace.editTagsAction")}
                            </button>
                            <button onClick={exportNote}>{t("workspace.export")}</button>
                            <button
                              disabled={saving || dirty}
                              onClick={() => {
                                if (
                                  window.confirm(
                                    detail.trashed
                                      ? t("workspace.restoreThisNote")
                                      : t("workspace.moveThisNoteTrash"),
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
                              {detail.trashed ? t("workspace.restore") : t("workspace.moveTrash")}
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
                  )?.name ?? t("workspace.myNotes")}
                  {detail?.tags?.length
                    ? " · " + detail.tags.map((t) => "#" + t).join(" ")
                    : ""}
                </p>
              </div>
              {noteError && (
                <div className="workspace-alert error" role="alert">
                  {noteError}
                  {saveFailure === "safe" && <button className="native-button" onClick={() => { setSaveFailure(null); setNoteError(""); }}>{t("workspace.retryAutosave")}</button>}
                </div>
              )}
              {noteActionNotice && <div className="workspace-alert" role="status">{noteActionNotice}</div>}
              {!route.compose &&
                detail &&
                !detail.editable &&
                !detail.html_text_preview && (
                  <div className="workspace-alert warning">
                    <ShieldAlert size={15} />
                    {t(detail.read_only_reason && Object.hasOwn(readOnlyReasons, detail.read_only_reason)
                      ? readOnlyReasons[detail.read_only_reason] : "workspace.thisDocumentReadOnly")}
                  </div>
                )}
              {savingAction !== "note" && route.compose && draft?.review_required && (
                <div className="workspace-alert warning">
                  <div>
                    <b>{t("workspace.newNoteSaveNeedsVerification")}</b>
                    <p>{t("workspace.statusDraftKeptAsYouNavigateAndWill", createStatus(createReceipt?.status))}</p>
                    <button className="native-button" onClick={() => activeDraftKey && void recoverCreate(draft, activeDraftKey)}>{t("workspace.checkCreationResultAgain")}</button>
                    {["reviewed", "absent"].includes(createReceipt?.status ?? "") && <button className="native-button" onClick={restartReviewedCreate}>{t("workspace.keepDraftAndCreateSeparateNote")}</button>}
                  </div>
                </div>
              )}
              {savingAction !== "note" && !route.compose && draft?.review_required && !recoveredDetail && (
                <div className="workspace-alert warning">
                  {t("workspace.reloadVerifiedNasCopyCompareItWithYour")}
                  <button className="native-button" onClick={() => void reviewAcknowledged()}>{t("workspace.reloadVerifiedNasCopy")}</button>
                </div>
              )}
              {recoveredDetail && draft && (
                <div className="workspace-alert warning">
                  <div>
                    <b>{t("workspace.reviewVerifiedNasResultAndYourSavedDraft")}</b>
                    <p>{t("workspace.yourDraftStaysThisTabWhenYouNavigate")}</p>
                    <strong>{recoveredDetail.title}</strong>
                    {!draft.recovery_acknowledged && <button className="native-button" onClick={() => {
                      const operation = pending.find(operation => operation.note_id === route.note);
                      if (operation) { void acknowledge(operation); return; }
                      if (!window.confirm(t("workspace.haveYouVerifiedSaveResultOnNasThis"))) return;
                      acknowledgeDraft();
                    }}>{t("workspace.markNasResultReviewedAndKeepDraft")}</button>}
                    <div className="conflict-columns">
                      <pre>{recoveredDetail.markdown ?? recoveredDetail.html}</pre>
                      <pre>{draft.title}{"\n"}{reviewDraftBody}</pre>
                    </div>
                    {draft.recovery_acknowledged && (
                      editableRecovery(recoveredDetail, draft) ?
                        <button className="native-button" onClick={() => void resumeReviewedNote()}>{t("workspace.continueWithSavedDraft")}</button> :
                        draft.markdown !== undefined ?
                          <button className="native-button" onClick={copyReviewedNote}>{t("workspace.createSeparateNoteWithSavedBody")}</button> :
                          draft.text_changes !== undefined && recoveredDetail.html_text_layout &&
                          <p>{t("workspace.nasBodyHasChangedSoSavedEditPosition")}</p>
                    )}
                    <button className="native-button" disabled={writeInProgress(recoveredDetail)} onClick={() => {
                      if (!window.confirm(t("workspace.discardYourSavedDraftAndUseVerifiedNas"))) return;
                      if (activeDraftKey) draftDelete(activeDraftKey);
                      setDraft(null); setEditing(false); setRecoveredDetail(null); setCompare(null);
                      setRevision(value => value + 1);
                    }}>{t("workspace.discardDraftAndUseVerifiedNasCopy")}</button>
                  </div>
                </div>
              )}
              {draft?.resume_paused && !draft.review_required && (
                <div className="workspace-alert warning">
                  {t("workspace.reviewDraftAndAttachmentsBeforeSavingAutosavePaused")}
                  {unresolvedRecoveryLinks && <p>{t("workspace.someAttachmentLinksUnresolvedEditLinksOrSelect")}</p>}
                  <button className="native-button" disabled={saving || composing || attachmentsBlocked || unresolvedRecoveryLinks || !editing}
                    onClick={() => {
                      if (!route.compose && !dirty) {
                        changeActiveDraft(source => ({...source, resume_paused:false}));
                        return;
                      }
                      void save(true);
                    }}>{t("workspace.saveDraftAndResumeAutosave")}</button>
                </div>
              )}
              {compare && !recoveredDetail && draft && (
                <div className="workspace-alert warning">
                  <div>
                    <b>{t("workspace.versionConflictYourDraftWasKept")}</b>
                    <p>{t("workspace.nasVersion")}{" "}{compare.version}</p>
                    <div className="conflict-columns">
                      <pre>{compare.markdown ?? compare.html}</pre>
                      <pre>{draft.markdown ?? draft.html}</pre>
                    </div>
                    <button
                      className="native-button"
                      onClick={() => {
                        if (
                          window.confirm(
                            t("workspace.discardLocalEditsAndOpenLatestNasVersion"),
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
                      {t("workspace.discardEditsAction")}
                    </button>
                  </div>
                </div>
              )}
              {detail?.locked ? (
                <div className="native-empty">
                  <ShieldAlert size={30} />
                  <h2>{t("workspace.encryptedNote")}</h2>
                  <p>{t("workspace.openOfficialApp")}</p>
                </div>
              ) : (
                <div className={`editor-panes mode-${displayedMode}`}>
                  {displayedMode !== "read" && (
                    <section className="source-pane">
                      {!formattedNote && <div className="pane-label">
                        <Code size={13} />
                        {previewMarkdown !== undefined
                          ? "MARKDOWN"
                          : t("workspace.htmlSource")}
                        {canAttach && <>
                          <button type="button" className="native-button attachment-picker"
                            onClick={() => attachmentInput.current?.click()}><Paperclip size={13} />{" "}{t("workspace.addFiles")}</button>
                          <input hidden ref={attachmentInput} type="file" multiple aria-label={t("workspace.chooseFilesAttach")}
                            onChange={event => {
                              const view = editorRef.current?.view;
                              acceptFiles.current(Array.from(event.currentTarget.files ?? []), view?.state.selection.main.head ?? 0);
                              event.currentTarget.value = "";
                            }} />
                        </>}
                      </div>}
                      {detail?.html_text_preview &&
                      draft?.text_changes !== undefined ? (
                        <>
                        {canAttachFormatted && <input hidden ref={attachmentInput} type="file" multiple
                          aria-label={t("workspace.chooseFilesAttach")} onChange={event=>{
                            acceptFiles.current(Array.from(event.currentTarget.files ?? []),0);
                            event.currentTarget.value="";
                          }}/>}
                        <OriginalEditor
                          html={localPreview?.html ?? detail.html_text_preview}
                          token={localPreview?.token ?? detail.html_text_token!}
                          blocks={draft.text_blocks ?? detail.html_text_blocks ?? []}
                          changes={reviewingUploads && !localPreview ? formattedRecoveryChanges(detail, draft) ?? [] : draft.text_changes}
                          restoreSelection={formatSelection}
                          editable={editing && !reviewingUploads}
                          dark={dark}
                          structureDisabled={noteActionsDisabled}
                          onAttach={canAttachFormatted ? () => attachmentInput.current?.click() : undefined}
                          attachmentPath={bodyAttachmentPath}
                          canUndo={!!currentHistory?.undo.length || !!draft.text_changes.length ||
                            !matchesDraftTitle(draft.title, formattedTip(detail,draft).title)}
                          canRedo={!!currentHistory?.redo.length && !draft.text_changes.length &&
                            matchesDraftTitle(draft.title, formattedTip(detail,draft).title)}
                          onUndo={() => queueNoteAction({historyDirection: "undo"})}
                          onRedo={() => queueNoteAction({historyDirection: "redo"})}
                          onStructureEdit={(edit) => queueNoteAction({structureEdit: edit})}
                          onChange={(change) => changeActiveDraft(current => {
                            const original = (current.text_blocks ?? detail.html_text_blocks)?.find(
                              block => block.index === change.index);
                            return {...current,text_changes:[
                              ...(current.text_changes ?? []).filter(entry => entry.index !== change.index),
                              ...(original?.text === change.text ? [] : [change]),
                            ]};
                          })}
                        />
                        </>
                      ) : previewMarkdown !== undefined ? (
                        <CodeMirror
                          ref={editorRef}
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
                          aria-label={t("workspace.htmlBody")}
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
                  {displayedMode !== "source" && (
                    <section className="preview-pane">
                      {viewMode === "split" && (
                        <div className="pane-label">
                          <Eye size={13} />
                          {t("workspace.preview")}
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
                  {saveFailure ? t("workspace.autosaveStoppedDraftKept") : saving ? t("workspace.savingNas")
                    : draft?.resume_paused ? t("workspace.autosavePaused")
                    : attachmentsBlocked ? t("workspace.waitingForAttachments") : dirty ? t("workspace.waitingAutosave") : route.compose ? t("workspace.writingNewNote") : t("workspace.savedNas")}
                </span>
                <span>
                  {t("workspace.charactersVersion",
                    (draft?.markdown ?? draft?.html ?? detail?.markdown ?? detail?.html ?? "").length,
                    detail?.version ?? t("workspace.newNote"),
                  )}
                </span>
              </footer>
            </>
          )}
        </main>
        {inspector && (
          <aside className="native-inspector" aria-label={t("workspace.noteInformation")}>
            <h3>{t("workspace.noteInformation")}</h3>
            <div className="inspector-card">
              <p>
                {t("workspace.modified")}{" "}<span>{dateLabel(detail?.modified_at)}</span>
              </p>
              <p>
                {t("workspace.added")}{" "}<span>{dateLabel(detail?.created_at)}</span>
              </p>
              <p>
                {t("workspace.revisionNumber")}{" "}<span>{detail?.version ?? "—"}</span>
              </p>
              <p>
                {t("workspace.nasNotebook")}{" "}
                <span>
                  {notebookById.get(detail?.notebook_id ?? "")?.name ?? "—"}
                </span>
              </p>
              <p>
                {t("workspace.serverId")}{" "}<span>{detail?.id ?? "—"}</span>
              </p>
            </div>
            <h3>{t("workspace.tags")}</h3>
            <div className="inspector-card">
              {detail?.tags?.join(" · ") || t("workspace.noTags")}
            </div>
            {detail && !detail.locked && !detail.trashed && <button className="native-button"
              onClick={() => setRevisionNoteId(detail.id)}>{t("workspace.viewRevisionHistory")}</button>}
            <h3>{t("workspace.attachments")}</h3>
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
                          type="button" aria-label={t("workspace.remove", file.name)} title={t("workspace.removeAttachment")}
                          disabled={saving || dirty || hasStagedUploads || draft?.review_required || draft?.resume_paused}
                          onClick={() => {
                            if (window.confirm(t("workspace.removeNasNote", file.name)))
                              void applyNoteAction({remove_attachment_id:file.id});
                          }}><Trash2 size={14}/></button>}
                    </div>;
                  })
                : t("workspace.noAttachments")}
            </div>
            <h3>{t("workspace.localGraphBacklinks")}</h3>
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
                {t("workspace.viewConnections")}
              </button>
            )}
            <h3>{t("workspace.display")}</h3>
            <button className="native-button" onClick={() => setShowSettings(true)}>{t("workspace.displayAndEditorSettings")}</button>
            <p className="inspector-help">
              {t("workspace.sourceAndPreviewShowSameNoteContent")}
            </p>
          </aside>
        )}
      </div>
      <NasConnectionStatus connected={nasConnected} />
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
                    ? t("workspace.renameStack")
                    : t("workspace.renameNotebook"),
                mode: "name",
                initial:
                  contextMenu.kind === "stack"
                    ? contextMenu.id
                    : notebookById.get(contextMenu.id)?.name,
              });
              setContextMenu(null);
            }}
          >
            {t("workspace.rename")}
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
                  title: t("workspace.moveStack"),
                  mode: "stack",
                  initial: notebookById.get(contextMenu.id)?.stack,
                });
                setContextMenu(null);
              }}
            >
              {t("workspace.moveToStackAction")}
            </button>
          )}
          <button
            onClick={() => {
              const label = contextMenu.kind === "stack" ? t("common.stack") : t("common.notebook");
              const name = contextMenu.kind === "stack" ? contextMenu.id : notebookById.get(contextMenu.id)?.name;
              setDialogAction({
                request: {kind: contextMenu.kind, id: contextMenu.id, action: "delete"},
                title: name ? t("workspace.delete", name, label) : t("workspace.deleteThis", label),
                mode: "delete",
              });
              setContextMenu(null);
            }}
          >
            {contextMenu.kind === "stack" ? t("workspace.deleteStack") : t("workspace.deleteNotebook")}
          </button>
          <button onClick={() => setContextMenu(null)}>{t("common.close")}</button>
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
