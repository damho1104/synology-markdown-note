import { currentLanguage, t } from "./i18n";
import { useEffect, useId, useRef, useState } from "react";
import { errorText, request } from "./api";
import { NotePreview } from "./NotePreview";

type Revision = {version: string; modified_at: number};
type Preview = {version: string; title: string; html: string};

export function NoteRevisionDialog({noteId, currentVersion, dark, canRestore, onRestore, onClose}: {
  noteId: string;
  currentVersion: string;
  dark: boolean;
  canRestore: boolean;
  onRestore: (version: string) => Promise<string | undefined>;
  onClose: () => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const [revisions,setRevisions] = useState<Revision[]>();
  const [selection,setSelection] = useState<{version:string}>();
  const selected = selection?.version ?? "";
  const [preview,setPreview] = useState<Preview>();
  const [error,setError] = useState("");
  const [restoring,setRestoring] = useState(false);
  const [confirming,setConfirming] = useState(false);
  const path = `/api/notes/${encodeURIComponent(noteId)}/revisions`;

  useEffect(() => {
    const element = dialog.current!;
    const previous = document.activeElement;
    if (typeof element.showModal === "function") element.showModal();
    else element.setAttribute("open", "");
    return () => {
      if (element.open && typeof element.close === "function") element.close();
      if (previous instanceof HTMLElement && previous.isConnected) previous.focus();
    };
  }, []);
  useEffect(() => {
    const controller = new AbortController();
    void request<{revisions:Revision[]}>(path, {signal:controller.signal})
      .then(result => { if (!controller.signal.aborted) setRevisions(result.revisions); })
      .catch(failure => { if (!controller.signal.aborted) setError(errorText(failure)); });
    return () => controller.abort();
  }, [path]);
  useEffect(() => {
    if (!selected) return;
    const controller = new AbortController();
    void request<Preview>(`${path}?version=${encodeURIComponent(selected)}`, {signal:controller.signal})
      .then(result => { if (!controller.signal.aborted) setPreview(result); })
      .catch(failure => { if (!controller.signal.aborted) setError(errorText(failure)); });
    return () => controller.abort();
  }, [path, selected, selection]);

  async function restore() {
    if (!preview || !canRestore || restoring) return;
    setRestoring(true);
    setError("");
    const failure = await onRestore(preview.version);
    setRestoring(false);
    if (failure) { setConfirming(false); setError(failure); }
    else onClose();
  }

  return <dialog ref={dialog} className="native-settings-dialog note-revision-dialog" aria-labelledby={titleId}
    onCancel={event => {event.preventDefault(); if (!restoring) onClose();}}>
    <header>
      <h2 id={titleId}>{t("노트 수정 이력")}</h2>
      <button type="button" className="native-button" disabled={restoring} onClick={onClose}>{t("닫기")}</button>
    </header>
    {error && <p role="alert">{error}</p>}
    {!revisions && !error && <p role="status">{t("NAS 수정 이력을 불러오는 중…")}</p>}
    {revisions?.length === 0 && <p>{t("NAS에 표시할 수정 이력이 없습니다.")}</p>}
    {!!revisions?.length && <ul className="note-revision-list">
      {revisions.map(revision => <li key={revision.version}>
        <button type="button" className="native-button" aria-pressed={selected === revision.version}
          disabled={restoring} onClick={() => {
            if (selected === revision.version && preview) return;
            setError(""); setConfirming(false); setSelection({version:revision.version});
          }}>
          {t("{0} · 버전 {1}", new Date(revision.modified_at * 1000).toLocaleString(currentLanguage()), revision.version)}
          {revision.version === currentVersion && " " + t("· 현재")}
        </button>
      </li>)}
    </ul>}
    {selected && preview?.version !== selected && !error && <p role="status">{t("과거 버전을 불러오는 중…")}</p>}
    {preview?.version === selected && <section>
      <h3>{preview.title || t("제목 없음")}</h3>
      <div className="note-revision-preview"><NotePreview html={preview.html} dark={dark} /></div>
      {!canRestore && !restoring && <p>{t("편집본과 진행 중인 저장을 먼저 확인하세요.")}</p>}
      {preview.version !== currentVersion && (confirming ? <div className="note-revision-confirm">
        <p>{t("이전 버전의 제목과 내용으로 현재 노트를 바꿀까요?")}</p>
        <button type="button" className="native-button" disabled={restoring}
          onClick={() => setConfirming(false)}>{t("취소")}</button>
        <button type="button" className="native-button" disabled={!canRestore || restoring}
          onClick={() => void restore()}>{restoring ? t("복원 중…") : t("복원 확인")}</button>
      </div> : <button type="button" className="native-button"
        disabled={!canRestore} onClick={() => setConfirming(true)}>{t("이 버전으로 복원")}</button>)}
    </section>}
  </dialog>;
}
