import { marked } from "marked";
import { ApiFailure, request } from "./api";

export const MAX_ATTACHMENT_BYTES = 50_000_000;
export const MAX_QUEUED_ATTACHMENTS = 20;
export const UPLOAD_CONCURRENCY = 2;
const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/;

export type UploadTarget = { notebook_id: string } & (
  { note_id: string; client_request_id?: never } |
  { client_request_id: string; note_id?: never }
);
export type UploadMetadata = {
  upload_id: string;
  name: string;
  size: number;
  sha256: string;
  mime: string;
  image: boolean;
  status: "ready" | "pinned" | "committed" | "receiving";
};
type UploadPhase = "queued" | "uploading" | "checking" | "ready" | "committed" |
  "failed" | "uncertain" | "missing" | "canceling" | "cancelFailed";
export type DraftUpload = {
  id: string;
  name: string;
  phase: UploadPhase;
  target: UploadTarget;
  position: number;
  inserted: boolean;
  insertedText?: string;
  metadata?: UploadMetadata;
  error?: string;
};
export type DraftUploads = { id: string; items: DraftUpload[] };

export function uploadPath(draftId: string, id: string, target: UploadTarget, content = false) {
  const query = new URLSearchParams({notebook_id: target.notebook_id});
  if (target.note_id !== undefined) query.set("note_id", target.note_id);
  else query.set("client_request_id", target.client_request_id);
  return `/api/drafts/${draftId}/uploads/${id}${content ? "/content" : ""}?${query}`;
}

async function lookup(path: string, signal: AbortSignal) {
  // A timed-out PUT can still be receiving bytes on the server.
  for (let attempt = 0; attempt < 5; attempt++) {
    const metadata = await request<UploadMetadata>(path, {signal}).catch(error => {
      if (error instanceof ApiFailure && error.status === 404) return null;
      throw error;
    });
    if (metadata?.status !== "receiving") return metadata;
    if (attempt < 4) await new Promise<void>(resolve => window.setTimeout(resolve, 1000));
  }
  throw new Error("서버가 아직 파일을 받고 있습니다. 잠시 후 다시 확인하세요.");
}

function confirmedUpload(item: DraftUpload, metadata: UploadMetadata): DraftUpload {
  if (metadata.upload_id !== item.id || !["ready", "pinned", "committed"].includes(metadata.status) ||
      !/^[0-9a-f]{64}$/.test(metadata.sha256) || typeof metadata.image !== "boolean" || typeof metadata.name !== "string")
    throw new Error("서버의 첨부 확인 정보가 올바르지 않습니다.");
  if (metadata.status === "pinned") return {...item, phase: "uncertain", metadata,
    error: "NAS 저장 결과를 확인해야 합니다."};
  return {...item, phase: metadata.status === "committed" ? "committed" : "ready", metadata, error: undefined};
}

export async function transferUpload(draftId: string, item: DraftUpload, file: File | undefined,
  csrf: string, signal: AbortSignal): Promise<DraftUpload> {
  const path = uploadPath(draftId, item.id, item.target);
  if (item.phase === "checking") {
    const found = await lookup(path, signal);
    if (found) return confirmedUpload(item, found);
  }
  if (!file) return {...item, phase: "missing", error: "임시 파일을 찾을 수 없습니다. 취소한 뒤 파일을 다시 선택하세요."};
  try {
    const metadata = await request<UploadMetadata>(path, {
      method: "PUT", signal, body: file,
      headers: {
        "Content-Type": "application/octet-stream",
        "X-CSRF-Token": csrf,
        "X-Upload-Name": encodeURIComponent(file.name),
        "X-Upload-Size": String(file.size),
      },
    });
    if (metadata.status !== "receiving") return confirmedUpload(item, metadata);
  } catch (error) {
    if (signal.aborted) throw error;
    if (error instanceof ApiFailure && error.status < 500 && ![408, 409, 425, 429].includes(error.status))
      return {...item, phase: "failed", error: error.message};
  }
  const found = await lookup(path, signal);
  return found ? confirmedUpload(item, found) : {...item, phase: "failed", error: "전송을 확인하지 못했습니다. 다시 시도하세요."};
}

export function uploadMarkdown(metadata: UploadMetadata) {
  const name = metadata.name.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/[\\\[\]`*_~<>!&]/g, "\\$&");
  return `${metadata.image ? "!" : ""}[${name}](attachment://${metadata.upload_id})`;
}

export function uploadInsertion(markdown: string, bookmark: number, metadata: UploadMetadata) {
  let position = Math.max(0, Math.min(bookmark, markdown.length));
  const link = uploadMarkdown(metadata);
  // Leading YAML must remain at the start of the note.
  const frontMatter = /^\uFEFF?---(?:\r?\n)[\s\S]*?^(?:---|\.\.\.)(?:\r?\n|$)/m.exec(markdown);
  if (frontMatter?.index === 0 && position < frontMatter[0].length) {
    position = frontMatter[0].length;
    return {position, text: `${frontMatter[0].endsWith("\n") ? "\n" : "\n\n"}${link}\n\n`};
  }
  if (position === 0 || markdown[position - 1] === "\n") {
    const kind = marked.lexer(markdown.slice(position))[0]?.type;
    if (kind && ["heading", "list", "blockquote", "code", "hr", "table", "html"].includes(kind))
      return {position, text: link + "\n\n"};
  }
  return {position, text: link};
}

export function uploadReferences(markdown: string | undefined): Set<string> {
  const references = new Set<string>();
  if (!markdown || !/attachment:\/\//i.test(markdown)) return references;
  marked.walkTokens(marked.lexer(markdown), token => {
    if ((token.type === "image" || token.type === "link") && token.href.toLowerCase().startsWith("attachment://")) {
      const id = token.href.slice(13).toLowerCase();
      if (UUID.test(id)) references.add(id);
    }
  });
  return references;
}

export function uploadManifest(uploads: DraftUploads | undefined, markdown: string | undefined,
  bindings: Record<string, string> | undefined) {
  const references = uploadReferences(markdown);
  return uploads?.items.flatMap(item => references.has(item.id) && !bindings?.[item.id] &&
    item.phase === "ready" && item.metadata
    ? [{upload_id: item.id, sha256: item.metadata.sha256}]
    : []) ?? [];
}

export function restoreUploads(uploads: DraftUploads | undefined): DraftUploads | undefined {
  if (!uploads) return undefined;
  return {...uploads, items: uploads.items.map(item => item.phase === "committed" ? item : {
    ...item, phase: item.phase === "canceling" || item.phase === "cancelFailed" ? "cancelFailed" : "checking",
  })};
}
