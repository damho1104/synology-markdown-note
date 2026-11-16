import { useEffect, useState } from "react";
import { AlertTriangle, X } from "lucide-react";

const STORAGE_KEY = "synonote:http-nas-warning";
type WarningState = { url: string | null; dismissed: boolean };

export function HttpNasWarning({ nasUrl }: { nasUrl: string | null }) {
  const [state, setState] = useState<WarningState>(() => {
    try {
      const stored = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? "null");
      if (stored?.url === nasUrl && typeof stored.dismissed === "boolean") return stored;
    } catch { /* Keep the warning usable when storage is unavailable. */ }
    return { url: nasUrl, dismissed: false };
  });
  useEffect(() => {
    const current = state.url === nasUrl ? state : { url: nasUrl, dismissed: false };
    if (current !== state) setState(current);
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(current)); } catch { /* Apply in memory. */ }
  }, [nasUrl, state]);

  if (!nasUrl?.startsWith("http://") || (state.url === nasUrl && state.dismissed)) return null;
  return (
    <div className="workspace-alert warning http-nas-warning" role="region" aria-label="NAS HTTP 연결 경고">
      <AlertTriangle size={14} aria-hidden="true" />
      <span>NAS 연결이 HTTP입니다. 계정 정보와 노트가 암호화되지 않습니다.</span>
      <button type="button" className="icon-button" aria-label="NAS HTTP 연결 경고 닫기"
        onClick={() => setState({ url: nasUrl, dismissed: true })}>
        <X size={14} aria-hidden="true" />
      </button>
    </div>
  );
}
