import { useEffect, useRef } from "react";
import { ApiFailure, errorText, jsonRequest, request } from "./api";
import { transferUpload, UPLOAD_CONCURRENCY, uploadPath, type DraftUpload, type DraftUploads } from "./attachmentUploads";

export type UploadPatch = (draftId: string, uploadId: string,
  update: (item: DraftUpload) => DraftUpload | null) => void;

export function useUploadQueue(uploads: DraftUploads | undefined, csrf: string,
  holdTransfers: boolean, reviewing: boolean, patch: UploadPatch) {
  const files = useRef(new Map<string, File>());
  const jobs = useRef(new Map<string, AbortController>());
  const draftId = uploads?.id;
  useEffect(() => {
    const activeJobs = jobs.current;
    const activeFiles = files.current;
    return () => {
      for (const job of activeJobs.values()) job.abort();
      activeJobs.clear();
      // Enqueue can supply the next draft's files before this effect cleans up.
      for (const [id] of activeFiles)
        if (id.startsWith(draftId + "/")) activeFiles.delete(id);
    };
  }, [draftId]);

  useEffect(() => {
    if (!uploads) return;
    for (const item of uploads.items) {
      if (jobs.current.has(item.id)) continue;
      const canceling = item.phase === "canceling";
      const lookupOnly = reviewing || !!item.recoveryOnly;
      if (lookupOnly ? item.phase !== "checking" :
        !canceling && (holdTransfers || (item.phase !== "queued" && item.phase !== "checking"))) continue;
      if (jobs.current.size >= UPLOAD_CONCURRENCY) break;
      const controller = new AbortController();
      const { signal } = controller;
      const fileKey = `${uploads.id}/${item.id}`;
      jobs.current.set(item.id, controller);
      if (item.phase === "queued")
        patch(uploads.id, item.id, current => ({...current, phase: "uploading"}));
      const run = async () => {
        try {
          if (canceling) {
            await request(uploadPath(uploads.id, item.id, item.target),
              {...jsonRequest({}, {"X-CSRF-Token": csrf}, "DELETE"), signal});
            return null;
          }
          return await transferUpload(uploads.id, item, files.current.get(fileKey), csrf, signal, lookupOnly);
        } catch (error) {
          if (canceling && error instanceof ApiFailure && error.status === 404) return null;
          return {...item, phase: canceling ? "cancelFailed" : "uncertain",
            error: errorText(error, "attachments.couldNotVerifyAttachmentRequest")} satisfies DraftUpload;
        }
      };
      void run().then(result => {
        if (jobs.current.get(item.id) !== controller) return;
        jobs.current.delete(item.id);
        if (signal.aborted) {
          // Wake the queue so the remote DELETE can follow the aborted PUT.
          patch(uploads.id, item.id, current => ({...current}));
          return;
        }
        if (!result || (!lookupOnly && result.metadata)) files.current.delete(fileKey);
        patch(uploads.id, item.id, current => {
          if (!canceling && current.phase === "canceling") return {...current};
          return result && {...current, phase: result.phase, metadata: result.metadata, error: result.error,
            recoveryOnly: current.recoveryOnly || result.recoveryOnly};
        });
      });
    }
  }, [uploads, csrf, holdTransfers, reviewing, patch]);

  return {files: files.current, abort: (id: string) => jobs.current.get(id)?.abort()};
}
