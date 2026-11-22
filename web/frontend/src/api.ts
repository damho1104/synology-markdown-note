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

const messages: Record<string, string> = {
  DUPLICATE_NOTEBOOK_NAME: "같은 이름의 메모장이 이미 있습니다.",
  DUPLICATE_STACK_NAME: "같은 이름의 책장이 이미 있습니다.",
  NOTEBOOK_NOT_FOUND: "메모장을 찾을 수 없습니다. 목록을 새로고침하세요.",
  STACK_NOT_FOUND: "책장을 찾을 수 없습니다. 목록을 새로고침하세요.",

  INVALID_NOTE_LINK: "지원하지 않는 노트 링크입니다.",
  NOTE_LINK_NOT_FOUND: "연결된 노트를 찾을 수 없습니다.",
  AMBIGUOUS_NOTE_LINK:
    "같은 문서 ID가 여러 노트에 있어 안전하게 연결할 수 없습니다.",
  HTML_PATCH_INVALID:
    "원본 텍스트 변경을 검증하지 못했습니다. 최신 노트를 다시 열어 주세요.",
  MARKDOWN_UNSUPPORTED:
    "수식 이미지 또는 첨부·보존 블록을 검증하지 못했습니다. 원문을 유지했습니다.",
  SECURE_COOKIE_REQUIRES_HTTPS:
    "HTTP 접속에서는 현재 Secure 로그인 쿠키를 사용할 수 없습니다. HTTPS로 접속하거나, 신뢰하는 내부망에서 HTTP를 사용하려면 서버의 WEB_COOKIE_SECURE=false 설정 후 웹 컨테이너를 재생성하세요.",
  LOGIN_COOKIE_MISSING:
    "브라우저가 로그인 쿠키를 유지하지 못했습니다. HTTP 접속이라면 WEB_COOKIE_SECURE=false 설정 후 컨테이너를 재생성하세요. HTTPS 접속이라면 브라우저의 쿠키 차단과 프록시 설정을 확인하세요.",
  INVALID_NAS_URL:
    "NAS 주소는 사용자 정보·쿼리 없이 HTTP 또는 HTTPS 주소로 입력하세요.",
  NAS_HTTP_BLOCKED:
    "HTTP NAS 연결은 NAS_ALLOW_PRIVATE=true일 때만 허용됩니다. 관리자 설정을 확인하세요.",
  NAS_ADDRESS_BLOCKED:
    "해당 NAS 주소에 연결할 수 없습니다. 사설망 NAS라면 관리자가 NAS_ALLOW_PRIVATE를 확인해야 합니다.",
  NAS_UNAVAILABLE:
    "NAS와 통신하지 못했습니다. 주소·포트·인증서·방화벽을 확인하세요.",
  NAS_API_ERROR: "NAS가 예상한 Note Station API 응답을 반환하지 않았습니다.",
  INVALID_SETUP_CODE: "초기 설정 코드가 일치하지 않습니다.",
  ALREADY_CONFIGURED: "이 설치의 NAS 주소는 이미 설정되어 있습니다.",
  AUTH_FAILED: "사용자 이름이나 비밀번호, 인증 정보를 확인하세요.",
  OTP_REQUIRED: "NAS의 2단계 인증 코드를 입력하세요.",
  TOO_MANY_ATTEMPTS: "인증 시도가 너무 많습니다. 잠시 후 다시 시도하세요.",
  RELOGIN_REQUIRED: "NAS 재인증이 필요합니다. 다시 로그인하세요.",
  LOGIN_REQUIRED: "로그인 세션이 만료되었습니다. 다시 로그인하세요.",
  INVALID_NAS_CONFIGURATION: "NAS_URL 환경변수의 주소가 올바르지 않습니다.",
  LOCAL_STORE_ERROR:
    "서버의 암호화 저장소를 열 수 없습니다. 관리자에게 문의하세요.",
  ORIGIN_REQUIRED:
    "보안 확인에 실패했습니다. 웹 주소와 WEB_PUBLIC_ORIGIN 설정을 확인하세요.",
  CSRF_REQUIRED:
    "요청 인증이 만료되었습니다. 페이지를 새로고침하고 다시 로그인하세요.",
  REMOTE_CHANGED:
    "다른 클라이언트에서 노트를 수정했습니다. 현재 편집본을 보존했습니다.",
  DOCUMENT_READ_ONLY:
    "원문·첨부·문서 형식을 보호하기 위해 이 노트는 읽기 전용입니다.",
  WRITE_UNCERTAIN:
    "NAS가 저장했는지 확인할 수 없습니다. 자동 재전송하지 않습니다.",
  WRITE_REVIEW_REQUIRED:
    "저장 결과 확인이 필요한 작업이 있습니다. NAS에서 내용을 확인하세요.",
  UPLOAD_SIZE_MISMATCH: "전송한 파일의 크기가 선택한 파일과 일치하지 않습니다.",
  ATTACHMENT_TOO_LARGE: "첨부파일은 50 MB까지 추가할 수 있습니다.",
  ATTACHMENT_NOT_FOUND: "첨부파일을 찾을 수 없습니다. 노트를 다시 열어 주세요.",
  ATTACHMENT_IN_USE: "본문에서 사용 중인 첨부파일입니다. 먼저 본문의 참조를 제거하세요.",
  ATTACHMENT_PROTECTED: "노트 복원에 사용하는 첨부파일은 앱에서 관리합니다.",
  REVISION_NOT_FOUND: "해당 수정 이력을 찾을 수 없습니다. 이력 목록을 다시 열어 주세요.",
  UPLOAD_NOT_READY: "임시 파일을 아직 저장에 사용할 수 없습니다. 업로드 상태를 확인하세요.",
  JSON_REQUIRED: "요청 형식이 올바르지 않습니다.",
};

export class ApiFailure extends Error {
  constructor(
    public code: string,
    public status: number,
  ) {
    super(messages[code] ?? `요청에 실패했습니다 (${status}).`);
    this.name = "ApiFailure";
  }
}

export function errorText(error: unknown): string {
  return error instanceof Error ? error.message : "요청 처리 중 오류가 발생했습니다.";
}

export const SESSION_EXPIRED_EVENT = "synonote:session-expired";
export function notifySessionExpired(): void {
  if (typeof window !== "undefined") window.dispatchEvent(new Event(SESSION_EXPIRED_EVENT));
}

async function rawRequest<T>(path: string, init: RequestInit = {}): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, {
      credentials: "same-origin",
      cache: "no-store",
      ...init,
    });
  } catch {
    throw new Error("웹 서버에 연결할 수 없습니다. 네트워크를 확인하세요.");
  }
  if (!response.ok) {
    if (response.status === 401 && !["/api/auth/login", "/api/auth/logout"].includes(path))
      notifySessionExpired();
    const data = (await response.json().catch(() => ({}))) as {
      error?: string;
      detail?: string;
    };
    throw new ApiFailure(
      data.error ?? data.detail ?? "REQUEST_FAILED",
      response.status,
    );
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
): Promise<T> {
  if (
    !path.startsWith("/api/auth/") &&
    !["/api/status", "/api/setup", "/api/health", "/api/ready"].includes(path)
  ) {
    // A rotated cookie must reach the browser before parallel NAS reads begin.
    // Share this boundary so concurrent list/pending/graph requests cannot revoke
    // each other's still-in-flight cookie. Only reads are repeated here.
    if (!sessionCheck)
      sessionCheck = rawRequest("/api/auth/me").finally(() => {
        sessionCheck = null;
      });
    await sessionCheck;
    if (init.signal?.aborted) throw new DOMException("Aborted", "AbortError");
  }
  return rawRequest<T>(path, init);
}


/** Continue a sequential read after request() has completed the session boundary.
 * The server still authenticates every request; avoid a redundant /auth/me per
 * graph indexing batch. Do not use for independent or concurrent mutations. */
export function readInSession<T>(path: string, init: RequestInit = {}): Promise<T> {
  return rawRequest<T>(path, {...init, method: "GET"});
}
