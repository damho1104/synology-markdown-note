import { t, UiError, type Message } from "./i18n";
export type Status = {
  configured: boolean;
  nas_url: string | null;
  source: "environment" | "database" | "setup";
  read_only: boolean;
};
export type Session = {
  username: string;
  remember: boolean;
  csrf_token: string;
};

const messages: Record<string, Message> = {
  DUPLICATE_NOTEBOOK_NAME: "errors.notebookWithThatNameAlreadyExists",
  DUPLICATE_STACK_NAME: "errors.stackWithThatNameAlreadyExists",
  NOTEBOOK_NOT_FOUND: "errors.notebookNotFoundRefreshList",
  STACK_NOT_FOUND: "errors.stackNotFoundRefreshList",

  INVALID_NOTE_LINK: "errors.thisNoteLinkUnsupported",
  NOTE_LINK_NOT_FOUND: "errors.linkedNoteCouldNotBeFound",
  AMBIGUOUS_NOTE_LINK:
    "errors.severalNotesHaveSameDocumentIdSoLink",
  HTML_PATCH_INVALID:
    "errors.couldNotVerifyOriginalTextChangeReopenLatest",
  MARKDOWN_UNSUPPORTED:
    "errors.couldNotVerifyEquationImageAttachmentOrPreserved",
  SECURE_COOKIE_REQUIRES_HTTPS:
    "errors.secureLoginCookiesRequireHttpsUseHttpsOr",
  LOGIN_COOKIE_MISSING:
    "errors.browserDidNotRetainLoginCookieForHttp",
  INVALID_NAS_URL:
    "errors.enterHttpOrHttpsNasAddressWithoutCredentials",
  NAS_HTTP_BLOCKED:
    "errors.httpConnectionsNasRequireNasAllowPrivateTrue",
  NAS_ADDRESS_BLOCKED:
    "errors.nasAddressUnreachableForPrivateNasAskYour",
  NAS_UNAVAILABLE:
    "errors.couldNotReachNasCheckAddressPortCertificate",
  NAS_API_ERROR: "errors.nasReturnedUnexpectedNoteStationApiResponse",
  INVALID_SETUP_CODE: "errors.setupCodeDoesNotMatch",
  ALREADY_CONFIGURED: "errors.nasAddressAlreadyConfiguredForThisInstallation",
  AUTH_FAILED: "errors.checkYourUsernamePasswordAndAuthenticationDetails",
  OTP_REQUIRED: "errors.enterNasTwoFactorAuthenticationCode",
  TOO_MANY_ATTEMPTS: "errors.tooManyAuthenticationAttemptsTryAgainLater",
  RELOGIN_REQUIRED: "errors.nasNeedsAuthenticateYouAgainSignAgain",
  LOGIN_REQUIRED: "errors.yourSessionHasExpiredSignAgain",
  INVALID_NAS_CONFIGURATION: "errors.addressNasUrlInvalid",
  LOCAL_STORE_ERROR:
    "errors.serverCouldNotOpenItsEncryptedStorageContact",
  ORIGIN_REQUIRED:
    "errors.securityCheckFailedCheckWebAddressAndWeb",
  CSRF_REQUIRED:
    "errors.requestAuthorizationExpiredRefreshPageAndSignAgain",
  REMOTE_CHANGED:
    "errors.thisNoteWasChangedByAnotherClientYour",
  DOCUMENT_READ_ONLY:
    "errors.thisNoteReadOnlyProtectItsSourceAttachments",
  WRITE_UNCERTAIN:
    "errors.couldNotVerifyWhetherNasSavedChangesRequest",
  WRITE_REVIEW_REQUIRED:
    "errors.saveNeedsVerificationCheckContentsOnNas",
  UPLOAD_SIZE_MISMATCH: "errors.uploadedFileSizeDoesNotMatchSelectedFile",
  ATTACHMENT_TOO_LARGE: "errors.attachmentsMayBeUp50Mb",
  ATTACHMENT_NOT_FOUND: "errors.attachmentNotFoundReopenNote",
  ATTACHMENT_IN_USE: "errors.thisAttachmentUsedNoteBodyRemoveItsReference",
  ATTACHMENT_PROTECTED: "errors.appManagesThisAttachmentForNoteRecovery",
  REVISION_NOT_FOUND: "errors.revisionNotFoundReopenRevisionList",
  REVISION_ATTACHMENTS_UNAVAILABLE: "errors.couldNotVerifyAttachmentsForOlderVersionCurrent",
  UPLOAD_NOT_READY: "errors.temporaryFileNotReadySaveCheckItsUpload",
  JSON_REQUIRED: "errors.requestFormatInvalid",
  INVALID_ID: "errors.itemIdInvalid",
  INVALID_NOTE: "errors.noteDataInvalid",
  INVALID_UPLOAD: "errors.attachmentRequestInvalid",
  NAS_NOT_CONFIGURED: "errors.nasAddressHasNotBeenConfigured",
  NAS_SESSION_EXPIRED: "errors.nasSessionExpiredSignAgain",
  OPERATION_NOT_FOUND: "errors.saveOperationCouldNotBeFound",
  SETUP_REQUIRED: "errors.completeNasSetupBeforeSigning",
  UPLOAD_BODY_REQUIRED: "errors.selectFileUpload",
  UPLOAD_INCOMPLETE: "errors.uploadDidNotCompleteCheckItsStatus",
  UPLOAD_NOT_FOUND: "errors.temporaryAttachmentCouldNotBeFound",
  VERSION_REQUIRED: "errors.noteVersionRequiredReopenLatestNote",
};

export function apiErrorMessage(code: string): string | undefined {
  return Object.hasOwn(messages, code) ? t(messages[code]) : undefined;
}

export class ApiFailure extends Error {
  constructor(
    public code: string,
    public status: number,
  ) {
    super(apiErrorMessage(code) ?? t("errors.requestFailed", String(status)));
    this.name = "ApiFailure";
  }
}

export class WebConnectionError extends UiError {
  constructor() {
    super("errors.webUnavailable");
  }
}

export function errorText(error: unknown, fallback: Message = "errors.unexpected"): string {
  if (error instanceof ApiFailure) return apiErrorMessage(error.code) ?? t("errors.requestFailed", String(error.status));
  return error instanceof UiError ? error.message : t(fallback);
}

export const SESSION_EXPIRED_EVENT = "synonote:session-expired";
export function notifySessionExpired(): void {
  if (typeof window !== "undefined") window.dispatchEvent(new Event(SESSION_EXPIRED_EVENT));
}

async function rawRequest<T>(path: string, init: RequestInit = {}, notifyOnUnauthorized = true): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, {
      credentials: "same-origin",
      cache: "no-store",
      ...init,
    });
  } catch (error) {
    if (init.signal?.aborted) throw error;
    throw new WebConnectionError();
  }
  if (!response.ok) {
    if (notifyOnUnauthorized && !init.signal?.aborted && response.status === 401 &&
        !["/api/auth/login", "/api/auth/logout"].includes(path))
      notifySessionExpired();
    const data = await response.json().catch(() => null);
    const code = typeof data?.error === "string" ? data.error : data?.detail;
    throw new ApiFailure(typeof code === "string" ? code : "REQUEST_FAILED", response.status);
  }
  return response.json() as Promise<T>;
}

export function jsonRequest(
  body: unknown,
  headers: Record<string, string> = {},
  method = "POST",
): RequestInit {
  return {
    method,
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  };
}

let sessionCheck: Promise<unknown> | null = null;
export async function request<T>(
  path: string,
  init: RequestInit = {},
  beforeSend?: () => void,
): Promise<T> {
  if (
    !path.startsWith("/api/auth/") &&
    !["/api/status", "/api/setup", "/api/health", "/api/ready"].includes(path)
  ) {
    // A rotated cookie must reach the browser before parallel NAS reads begin.
    // Share this boundary so concurrent list/pending/graph requests cannot revoke
    // each other's still-in-flight cookie. Only reads are repeated here.
    if (!sessionCheck) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 60_000);
      sessionCheck = rawRequest("/api/auth/me", { signal: controller.signal }).finally(() => {
        clearTimeout(timeout);
        sessionCheck = null;
      });
    }
    await sessionCheck;
    if (init.signal?.aborted) throw new DOMException("Aborted", "AbortError");
  }
  beforeSend?.();
  return rawRequest<T>(path, init);
}


// The server authenticates and expires the session, but does not renew its idle deadline.
export async function backgroundRead<T>(path: string, signal: AbortSignal): Promise<T> {
  const init = {method: "GET", signal, headers: {"X-Synonote-Background": "1"}};
  try {
    return await rawRequest<T>(path, init, false);
  } catch (error) {
    if (!(error instanceof ApiFailure) || error.status !== 401 || signal.aborted) throw error;
    // An active request may have rotated the cookie while this read was in flight.
    return rawRequest<T>(path, init);
  }
}
