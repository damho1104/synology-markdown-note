import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
  type CSSProperties,
} from "react";
import {
  AlertTriangle,
  ArrowLeft,
  ArrowRight,
  Book,
  BookOpenText,
  ChevronRight,
  FilePlus2,
  FileText,
  FolderOpen,
  LogOut,
  Menu,
  Paperclip,
  Pencil,
  RefreshCw,
  Save,
  Search,
  ShieldAlert,
  Trash2,
  X,
  Star,
  Tag,
  Settings,
  PanelRight,
  ChevronDown,
  Code,
  Eye,
  Network,
  Link2,
} from "lucide-react";
import {
  ApiFailure,
  jsonRequest,
  request,
  type Session,
  type Status,
} from "./api";
import { NoteGraph } from "./NoteGraph";
import {
  LibraryDialog,
  type DialogAction,
  type LibraryAction,
} from "./LibraryDialog";
import {
  OriginalEditor,
  changedHtmlPreview,
  type TextChange,
} from "./OriginalEditor";
import { NoteLinkPicker } from "./NoteLinkPicker";
import { SettingsDialog } from "./SettingsDialog";
import { loadPreferences, savePreferences } from "./preferences";
import CodeMirror, { EditorView, type ReactCodeMirrorRef } from "@uiw/react-codemirror";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { tags as syntaxTags } from "@lezer/highlight";
import { markdown as markdownLanguage } from "@codemirror/lang-markdown";
import { NotePreview } from "./NotePreview";
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
};
type Attachment = { id: string; name: string; ref: string | null };
type NoteDetail = NoteSummary & {
  html_text_preview?: string;
  html_text_token?: string;
  html_text_blocks?: TextChange[];
  attachment_bindings?: Record<string, string>;
  markdown?: string;
  blocks?: { id: string; html: string; label: string }[];
  html: string;
  attachments: Attachment[];
  editable: boolean;
  read_only_reason: string | null;
};
type WriteOperation = {
  operation_id: string;
  target: string;
  note_id: string | null;
  title: string;
  status: string;
  created: number;
};
type Route = {
  shelf: string | null;
  notebook: string | null;
  note: string | null;
  compose: boolean;
  filter?: string;
};
type Draft = {
  text_changes?: TextChange[];
  key: string;
  title: string;
  html: string;
  notebook_id: string;
  version?: string;
  markdown?: string;
};

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
  MATH_EXPORT:
    "수식 이미지 원문은 표시할 수 있습니다. PNG 재생성을 포함한 저장은 아직 검증 중입니다.",
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

function writeRoute(route: Route, index: number, replace = false): void {
  const url = new URL(window.location.href);
  for (const key of ["s", "n", "note", "new", "f"])
    url.searchParams.delete(key);
  if (route.shelf) url.searchParams.set("s", route.shelf);
  if (route.notebook) url.searchParams.set("n", route.notebook);
  if (route.note) url.searchParams.set("note", route.note);
  if (route.filter) url.searchParams.set("f", route.filter);
  if (route.compose) url.searchParams.set("new", "1");
  window.history[replace ? "replaceState" : "pushState"](
    { ...window.history.state, __synonote_index: index },
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

function draftDelete(key: string): void {
  try {
    sessionStorage.removeItem(key);
  } catch {
    /* Storage can be unavailable. */
  }
}

function errorText(error: unknown): string {
  return error instanceof Error
    ? error.message
    : "요청 처리 중 오류가 발생했습니다.";
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
  const [listError, setListError] = useState("");
  const [noteError, setNoteError] = useState("");
  const [detail, setDetail] = useState<NoteDetail | null>(null);
  const [noteLoading, setNoteLoading] = useState(false);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [query, setQuery] = useState("");
  const [pending, setPending] = useState<WriteOperation[]>([]);
  const [pendingError, setPendingError] = useState("");
  const [compare, setCompare] = useState<NoteDetail | null>(null);
  const [message, setMessage] = useState("");
  const [sidebarOpen, setSidebarOpen] = useState(false);
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
  const historyIndex = useRef<number>(
    typeof window.history.state?.__synonote_index === "number"
      ? window.history.state.__synonote_index
      : 0,
  );
  const navigating = useRef({
    route,
    draft,
    activeKey: null as string | null,
    draftKey: null as string | null,
    dirty: false,
    saving: false,
  });

  // No NAS credential, cookie token or SID is stored in browser storage.
  const draftPrefix = `synonote:web-draft:${JSON.stringify([status.nas_url, session.username])}:`;
  const activeKey =
    route.compose && route.notebook
      ? `new:${route.notebook}`
      : route.note
        ? `note:${route.note}`
        : null;
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
  navigating.current = {
    route,
    draft,
    activeKey,
    draftKey: activeDraftKey,
    dirty,
    saving,
  };

  function commitRoute(next: Route, replace = false) {
    const index = historyIndex.current + (replace ? 0 : 1);
    writeRoute(next, index, replace);
    historyIndex.current = index;
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

  const loadLists = useCallback(async () => {
    setListLoading(true);
    try {
      const [books, all] = await Promise.all([
        request<{ notebooks: Notebook[] }>("/api/notebooks"),
        request<{ notes: NoteSummary[] }>("/api/notes"),
      ]);
      setNotebooks(books.notebooks);
      setNotes(all.notes);
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
    writeRoute(readRoute(), historyIndex.current, true);
    const pop = (event: PopStateEvent) => {
      const next = readRoute();
      const current = navigating.current;
      const destination =
        next.compose && next.notebook
          ? `new:${next.notebook}`
          : next.note
            ? `note:${next.note}`
            : null;
      const nextIndex =
        typeof event.state?.__synonote_index === "number"
          ? event.state.__synonote_index
          : null;
      const restore = () => {
        if (nextIndex !== null && nextIndex !== historyIndex.current) {
          window.history.go(historyIndex.current - nextIndex);
        } else {
          writeRoute(current.route, historyIndex.current, true);
        }
      };
      if (current.saving) {
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
      setRoute(next);
      setCompare(null);
      setMessage("");
    };
    window.addEventListener("popstate", pop);
    return () => window.removeEventListener("popstate", pop);
  }, []);
  useEffect(() => {
    if (!dirty && !saving) return;
    const beforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", beforeUnload);
    return () => window.removeEventListener("beforeunload", beforeUnload);
  }, [dirty, saving]);

  useEffect(() => {
    let active = true;
    setDetail(null);
    setNoteError("");
    setCompare(null);
    if (!activeKey || !activeDraftKey) {
      setNoteLoading(false);
      setDraft(null);
      setEditing(false);
      return;
    }
    if (route.compose) {
      setNoteLoading(false);
      setDraft(
        draftRead(activeDraftKey) ?? {
          key: activeKey,
          title: "",
          html: BLANK_HTML,
          markdown: "",
          notebook_id: route.notebook!,
        },
      );
      setEditing(true);
      setViewMode("split");
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
          (note.editable || !!note.html_text_preview)
        ) {
          setDraft(saved);
          setEditing(true);
          setViewMode("split");
          setMessage("이 탭에 남아 있던 편집 내용을 복원했습니다.");
        } else {
          setDraft({
            key: activeKey,
            title: note.title,
            html: note.html,
            notebook_id: note.notebook_id,
            version: note.version,
            markdown: note.markdown,
            text_changes: note.html_text_preview ? [] : undefined,
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
      editing &&
      dirty
    ) {
      draftStore(activeDraftKey, draft);
    }
  }, [activeKey, activeDraftKey, draft, dirty, editing]);

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
    if (
      mode !== "read" &&
      !editing &&
      (detail?.editable || detail?.html_text_preview)
    )
      startEdit();
  }

  function navigate(next: Route, replace = false) {
    if (saving) return;
    if (
      activeKey !==
        (next.compose && next.notebook
          ? `new:${next.notebook}`
          : next.note
            ? `note:${next.note}`
            : null) &&
      dirty &&
      !window.confirm(
        "편집 내용은 이 탭에 임시 보관됩니다. 다른 노트로 이동할까요?",
      )
    )
      return;
    if (dirty && draft && activeDraftKey) draftStore(activeDraftKey, draft);
    commitRoute(next, replace);
    setMessage("");
  }

  function startEdit() {
    if (
      !detail ||
      (!detail.editable && !detail.html_text_preview) ||
      !activeKey
    )
      return;
    setDraft({
      key: activeKey,
      title: detail.title,
      html: detail.html,
      notebook_id: detail.notebook_id,
      version: detail.version,
      markdown: detail.markdown,
      text_changes: detail.html_text_preview ? [] : undefined,
    });
    setEditing(true);
    setMessage("");
  }

  function discard() {
    if (saving) return;
    if (dirty && !window.confirm("이 탭의 임시 편집 내용도 삭제할까요?"))
      return;
    if (activeDraftKey) draftDelete(activeDraftKey);
    if (route.compose) {
      setDraft(null);
      setEditing(false);
      commitRoute({ ...route, compose: false }, true);
      setMessage("새 노트 작성을 취소했습니다.");
    } else {
      if (detail && activeKey)
        setDraft({
          key: activeKey,
          title: detail.title,
          html: detail.html,
          notebook_id: detail.notebook_id,
          version: detail.version,
          markdown: detail.markdown,
          text_changes: detail.html_text_preview ? [] : undefined,
        });
      setEditing(false);
      setMessage("편집을 취소했습니다.");
    }
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draft || !activeDraftKey || saving || !draft.title.trim()) return;
    if (
      !route.compose &&
      ((!detail?.editable && !detail?.html_text_preview) || !dirty)
    )
      return;
    const isNew = route.compose;
    setSaving(true);
    setNoteError("");
    setCompare(null);
    if (dirty) draftStore(activeDraftKey, draft);
    try {
      const url = isNew
        ? "/api/notes"
        : `/api/notes/${encodeURIComponent(route.note!)}`;
      const next = await request<NoteDetail>(
        url,
        jsonRequest(
          {
            title: draft.title.trim(),
            ...(draft.text_changes !== undefined
              ? { text_changes: draft.text_changes }
              : draft.markdown !== undefined
                ? { markdown: draft.markdown }
                : { html: draft.html }),
            notebook_id: draft.notebook_id,
            ...(!isNew
              ? { version: draft.version ?? "unknown-draft-base" }
              : {}),
          },
          { "X-CSRF-Token": session.csrf_token },
          isNew ? "POST" : "PUT",
        ),
      );
      draftDelete(activeDraftKey);
      setEditing(false);
      setMessage("NAS에 저장하고 최신 버전을 확인했습니다.");
      if (isNew) {
        setDraft(null);
        commitRoute(
          {
            shelf: route.shelf,
            notebook: next.notebook_id,
            note: next.id,
            compose: false,
          },
          true,
        );
      } else {
        setDetail(next);
        setDraft({
          key: activeKey!,
          title: next.title,
          html: next.html,
          notebook_id: next.notebook_id,
          version: next.version,
          markdown: next.markdown,
          text_changes: next.html_text_preview ? [] : undefined,
        });
      }
      await Promise.all([loadLists(), loadPending()]);
    } catch (error) {
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
    } finally {
      setSaving(false);
    }
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
    } catch (error) {
      handleError(error, setPendingError);
    }
  }

  function logout() {
    if (saving) return;
    if (dirty && !window.confirm("임시 편집 내용을 삭제하고 로그아웃할까요?"))
      return;
    void onLogout()
      .then(() => {
        // Logout also clears local drafts for this NAS account.
        try {
          for (let i = sessionStorage.length - 1; i >= 0; i--) {
            const key = sessionStorage.key(i);
            if (key?.startsWith(draftPrefix)) sessionStorage.removeItem(key);
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
  async function libraryAction(action: LibraryAction) {
    if (saving) return;
    if (dirty)
      throw new Error("편집 내용을 저장하거나 취소한 다음 실행하세요.");
    setSaving(true);
    setPendingError("");
    try {
      await request(
        "/api/library/action",
        jsonRequest(action, { "X-CSRF-Token": session.csrf_token }),
      );
      await Promise.all([loadLists(), loadPending()]);
      if (action.kind === "note") setRevision((n) => n + 1);
    } catch (error) {
      handleError(error, setPendingError);
      void loadPending();
      throw error;
    } finally {
      setSaving(false);
    }
  }
  function exportNote() {
    const body =
      draft?.markdown ?? detail?.markdown ?? draft?.html ?? detail?.html;
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
  const selectedSummary = notes.find((n) => n.id === route.note);
  const previewHtml =
    editing && draft?.text_changes && detail?.html_text_preview
      ? changedHtmlPreview(
          detail.html_text_preview,
          detail.html_text_token!,
          draft.text_changes,
        )
      : editing && draft
        ? draft.html
        : (detail?.html ?? "");
  const previewMarkdown = editing && draft ? draft.markdown : detail?.markdown;
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
    <div className={`native-app ${dark ? "native-dark" : ""}`}
      style={{ "--editor-font-size": `${preferences.editorFontSize}px` } as CSSProperties}>
      <header className="native-toolbar">
        <div className="toolbar-sidebar">
          <button
            className="icon-button mobile-menu"
            aria-label="책장 메뉴"
            onClick={() => setSidebarOpen(!sidebarOpen)}
          >
            <Menu size={18} />
          </button>
          <b>Note Station</b>
        </div>
        <div className="toolbar-list">{listTitle}</div>
        <div className="toolbar-actions">
          <div className="toolbar-group">
            <button
              className="icon-button"
              aria-label="이전 화면"
              disabled={saving}
              onClick={() => window.history.back()}
            >
              <ArrowLeft size={18} />
            </button>
            <button
              className="icon-button"
              aria-label="다음 화면"
              disabled={saving}
              onClick={() => window.history.forward()}
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
            <button
              className="icon-button"
              aria-label="전체 검색"
              onClick={() => document.getElementById("library-search")?.focus()}
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
              disabled={saving}
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
      {status.nas_url?.startsWith("http://") && (
        <div className="workspace-alert warning">
          <AlertTriangle size={14} />
          NAS 연결이 HTTP입니다. 계정 정보와 노트가 암호화되지 않습니다.
        </div>
      )}
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
            <button
              className="native-nav"
              disabled={saving}
              onClick={() =>
                setDialogAction({
                  request: { kind: "stack", action: "create" },
                  title: "새 책장 만들기",
                  mode: "createStack",
                })
              }
            >
              <Book size={16} />
              <span>책장 만들기</span>
            </button>
            <button
              className="native-nav"
              disabled={saving}
              onClick={() =>
                setDialogAction({
                  request: { kind: "notebook", action: "create" },
                  title: "메모장 추가",
                  mode: "name",
                })
              }
            >
              <FilePlus2 size={16} />
              <span>노트북 추가</span>
            </button>
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
        <section className="native-list" aria-label="노트 목록">
          <div className="list-controls">
            <label className="native-search">
              <Search size={15} />
              <input
                id="library-search"
                aria-label="노트 검색"
                placeholder="노트 검색"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
              {query && (
                <button aria-label="검색 지우기" onClick={() => setQuery("")}>
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
                    {(note.excerpt?.includes("```") ||
                      (note.id === detail?.id &&
                        detail?.markdown !== undefined)) && (
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
          <footer className="native-status">
            {visibleNotes.length}개의 노트
          </footer>
        </section>
        <main className="native-detail" aria-label="노트 본문">
          {route.filter === "graph" ? (
            <NoteGraph
              key={"graph-" + revision}
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
              <BookOpenText size={40} />
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
                  {editing && draft ? (
                    <input
                      id="note-title"
                      aria-label="노트 제목"
                      required
                      maxLength={256}
                      disabled={saving}
                      value={draft.title}
                      placeholder="제목"
                      onChange={(e) =>
                        setDraft({ ...draft, title: e.target.value })
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

                    {!editing &&
                      (detail?.editable || detail?.html_text_preview) && (
                        <button
                          className="native-button"
                          onClick={() => {
                            setViewMode("split");
                            startEdit();
                          }}
                        >
                          <Pencil size={13} />
                          편집
                        </button>
                      )}
                    {editing && (
                      <>
                        <button
                          className="native-button primary"
                          disabled={
                            saving ||
                            !draft?.title.trim() ||
                            (!route.compose && !dirty)
                          }
                          onClick={() =>
                            void save({
                              preventDefault() {},
                            } as FormEvent<HTMLFormElement>)
                          }
                        >
                          <Save size={13} />
                          {saving ? "NAS 저장 중…" : "NAS에 저장"}
                        </button>
                        <button
                          className="native-button"
                          disabled={saving}
                          onClick={discard}
                        >
                          취소
                        </button>
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
              {compare && draft && (
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
                      </div>
                      {detail?.html_text_preview &&
                      draft?.text_changes !== undefined ? (
                        <OriginalEditor
                          html={detail.html_text_preview}
                          token={detail.html_text_token!}
                          blocks={detail.html_text_blocks ?? []}
                          changes={draft.text_changes}
                          editable={editing && !saving}
                          dark={dark}
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
                          extensions={editorExtensions}
                          theme={dark ? "dark" : "light"}
                          editable={editing && !saving}
                          onChange={(value) => {
                            if (draft && editing && !saving)
                              setDraft({ ...draft, markdown: value });
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
                          disabled={saving}
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
                        html={previewHtml}
                        markdown={previewMarkdown}
                        blocks={detail?.blocks}
                        dark={dark}
                        {...mermaidPreferences}
                        noteId={detail?.id}
                        version={detail?.version}
                        attachments={detail?.attachments}
                        bindings={detail?.attachment_bindings}
                        onOpenLink={(destination) =>
                          void openInternalLink(destination)
                        }
                      />
                    </section>
                  )}
                </div>
              )}
              <footer className="native-status editor-status">
                <span>
                  {saving
                    ? "NAS 저장 중…"
                    : dirty
                      ? "이 탭에 임시 저장됨"
                      : "✓ 저장됨"}
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
            <h3>첨부파일</h3>
            <div className="inspector-card">
              {detail?.attachments.length
                ? detail.attachments.map((file) => (
                    <a
                      key={file.id}
                      href={`/api/notes/${encodeURIComponent(detail.id)}/attachments/${encodeURIComponent(file.id)}`}
                      download={file.name}
                    >
                      <Paperclip size={14} />
                      {file.name}
                    </a>
                  ))
                : "첨부파일 없음"}
            </div>
            <h3>로컬 그래프 · 백링크</h3>
            {showLocalGraph && detail ? (
              <div style={{ height: 420 }}>
                <NoteGraph
                  key={"graph-" + revision}
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
      {showSettings && <SettingsDialog preferences={preferences} onChange={setPreferences} onClose={() => setShowSettings(false)} />}
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
  );
}
function ServerIcon() {
  return <FolderOpen size={18} />;
}
