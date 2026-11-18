import { type DraftUploads, uploadPath } from "./attachmentUploads";

const labels = {
  queued: "전송 대기", uploading: "웹 서버로 전송 중…", checking: "임시 파일 확인 중…",
  ready: "웹 서버에 임시 보관됨", committed: "NAS에 저장됨", failed: "전송 실패",
  uncertain: "전송 결과 확인 필요", missing: "파일 다시 선택 필요",
  canceling: "취소 중…", cancelFailed: "취소 결과 확인 필요",
  reviewed: "확인 처리된 임시 파일 · 7일간 다운로드 가능", discarding: "임시 파일 정리 중…",
};

export function AttachmentQueue({uploads, savingIds, busy, reviewing, composing, references, retry, cancel, discard}: {
  uploads: DraftUploads;
  savingIds: ReadonlySet<string>;
  busy: boolean;
  reviewing: boolean;
  composing: boolean;
  references: ReadonlySet<string>;
  retry: (id: string) => void;
  cancel: (id: string) => void;
  discard: (id: string) => void;
}) {
  return <ul className="attachment-queue" aria-label="첨부파일 업로드">
    {uploads.items.map(item => {
      const protectedUpload = item.metadata?.status === "pinned" || item.metadata?.status === "reviewed";
      const recoveryOnly = reviewing || item.recoveryOnly || protectedUpload;
      const discardable = item.phase === "reviewed" || (item.phase === "missing" && recoveryOnly);
      return <li key={item.id}>
      <span className="attachment-queue-name">
        {item.phase === "ready" || item.phase === "reviewed"
          ? <a href={uploadPath(uploads.id, item.id, item.target, true)} download={item.name}>{item.name}</a>
          : item.name}
      </span>
      <span role="status">
        {savingIds.has(item.id) && busy ? "NAS에 저장 중…" : labels[item.phase]}
        {item.phase === "ready" && item.inserted && !references.has(item.id) && " · 본문에서 사용하지 않음"}
        {item.error && <> · {item.error}</>}
      </span>
      {["failed", "uncertain"].includes(item.phase) &&
        <button type="button" className="native-button" disabled={busy || composing}
          onClick={() => retry(item.id)}>{recoveryOnly ? "첨부 상태 확인" : "다시 시도"}</button>}
      {discardable && <button type="button" className="native-button" disabled={busy || composing}
        onClick={() => discard(item.id)}>{item.phase === "missing" ? "만료된 첨부 표시 지우기" : "임시 파일 버리기"}</button>}
      {!recoveryOnly && !["committed", "canceling", "discarding"].includes(item.phase) &&
        <button type="button" className="native-button" disabled={busy || composing || savingIds.has(item.id)}
          onClick={() => cancel(item.id)}>{item.phase === "cancelFailed" ? "취소 다시 시도" : "취소"}</button>}
    </li>;
    })}
  </ul>;
}
