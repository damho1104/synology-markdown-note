import { storedErrorText, t } from "./i18n";
import { type DraftUploads, uploadPath } from "./attachmentUploads";

const labels = {
  queued: "attachments.queued", uploading: "attachments.uploadingWebServer", checking: "attachments.checkingTemporaryFile",
  ready: "attachments.temporarilyStoredOnWebServer", committed: "attachments.savedNas", failed: "attachments.uploadFailed",
  uncertain: "attachments.uploadNeedsVerification", missing: "attachments.selectFileAgain",
  canceling: "attachments.canceling", cancelFailed: "attachments.cancellationNeedsVerification",
  reviewed: "attachments.reviewedFileRetention", discarding: "attachments.removingTemporaryFile",
} as const;

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
  return <ul className="attachment-queue" aria-label={t("attachments.attachmentUploads")}>
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
        {savingIds.has(item.id) && busy ? t("attachments.savingNas") : t(labels[item.phase])}
        {item.phase === "ready" && item.inserted && !references.has(item.id) && " " + t("attachments.unusedNoteBody")}
        {item.error && <> · {storedErrorText(item.error)}</>}
      </span>
      {["failed", "uncertain"].includes(item.phase) &&
        <button type="button" className="native-button" disabled={busy || composing}
          onClick={() => retry(item.id)}>{recoveryOnly ? t("attachments.checkAttachmentStatus") : t("common.tryAgain")}</button>}
      {discardable && <button type="button" className="native-button" disabled={busy || composing}
        onClick={() => discard(item.id)}>{item.phase === "missing" ? t("attachments.clearExpiredAttachment") : t("attachments.discardTemporaryFile")}</button>}
      {!recoveryOnly && !["committed", "canceling", "discarding"].includes(item.phase) &&
        <button type="button" className="native-button" disabled={busy || composing || savingIds.has(item.id)}
          onClick={() => cancel(item.id)}>{item.phase === "cancelFailed" ? t("attachments.retryCancellation") : t("common.cancel")}</button>}
    </li>;
    })}
  </ul>;
}
