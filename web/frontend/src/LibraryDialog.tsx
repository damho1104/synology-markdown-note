import { errorText } from "./api";
import { t } from "./i18n";
import { useState } from "react";
export type LibraryAction = {
  kind: "note" | "notebook" | "stack";
  action:
    "favorite" | "tags" | "trash" | "restore" | "move" | "create" | "rename" | "delete";
  id?: string;
  version?: string;
  value?: string | boolean | string[];
  name?: string;
};
export type DialogAction = {
  request: LibraryAction;
  title: string;
  mode: "name" | "notebook" | "stack" | "tags" | "createStack" | "delete";
  initial?: string;
};
export function LibraryDialog({
  config,
  notebooks,
  busy,
  onSubmit,
  onClose,
}: {
  config: DialogAction;
  notebooks: { id: string; name: string; stack: string }[];
  busy: boolean;
  onSubmit: (action: LibraryAction) => Promise<void>;
  onClose: () => void;
}) {
  const [value, setValue] = useState(config.initial ?? "");
  const [members, setMembers] = useState<string[]>([]);
  const [error, setError] = useState("");
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setError("");
    try {
      const request = { ...config.request };
      if (config.mode === "name" || config.mode === "createStack")
        request.name = value.trim();
      else if (config.mode === "tags")
        request.value = Array.from(
          new Set(
            value
              .split(",")
              .map((v) => v.trim())
              .filter(Boolean),
          ),
        );
      else if (config.mode !== "delete") request.value = value;
      if (config.mode === "createStack") request.value = members;
      await onSubmit(request);
      onClose();
    } catch (error) {
      setError(errorText(error, "작업에 실패했습니다."));
    }
  }
  return (
    <div className="native-modal-backdrop">
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="library-dialog-title"
        className="native-modal"
      >
        <h2 id="library-dialog-title">{config.title}</h2>
        <form onSubmit={(e) => void submit(e)}>
          {config.mode === "delete" ? (
            <p>{config.request.kind === "stack"
              ? t("책장 분류를 해제합니다. 메모장과 노트는 그대로 남습니다.")
              : t("NAS에서 메모장을 삭제하고 포함된 노트를 휴지통으로 이동합니다.")}</p>
          ) : config.mode === "notebook" ? (
            <label>
              {t("메모장")}
              <select
                autoFocus
                value={value}
                required
                onChange={(e) => setValue(e.target.value)}
              >
                <option value="" disabled>
                  {t("메모장을 선택하세요")}
                </option>
                {notebooks.map((b) => (
                  <option key={b.id} value={b.id}>
                    {b.stack ? b.stack + " / " : ""}
                    {b.name}
                  </option>
                ))}
              </select>
            </label>
          ) : config.mode === "stack" ? (
            <label>
              {t("책장")}
              <select
                autoFocus
                value={value}
                onChange={(e) => setValue(e.target.value)}
              >
                <option value="">{t("책장 밖 메모장")}</option>
                {Array.from(
                  new Set(notebooks.map((b) => b.stack).filter(Boolean)),
                )
                  .sort()
                  .map((s) => (
                    <option key={s} value={s}>
                      {s}
                    </option>
                  ))}
              </select>
            </label>
          ) : (
            <label>
              {config.mode === "tags" ? t("태그 (쉼표로 구분)") : t("이름")}
              <input
                autoFocus
                value={value}
                maxLength={256}
                required={config.mode !== "tags"}
                onChange={(e) => setValue(e.target.value)}
              />
            </label>
          )}
          {config.mode === "createStack" && (
            <fieldset>
              <legend>{t("책장에 넣을 메모장")}</legend>
              {notebooks.map((book) => (
                <label key={book.id} className="native-checkbox">
                  <input
                    type="checkbox"
                    checked={members.includes(book.id)}
                    onChange={(e) =>
                      setMembers(
                        e.target.checked
                          ? [...members, book.id]
                          : members.filter((id) => id !== book.id),
                      )
                    }
                  />
                  {book.name}
                </label>
              ))}
            </fieldset>
          )}
          {error && (
            <p role="alert" className="native-dialog-error">
              {error}
            </p>
          )}
          <div className="native-dialog-buttons">
            <button
              type="button"
              className="native-button"
              disabled={busy}
              onClick={onClose}
            >
              {t("취소")}
            </button>
            <button
              type="submit"
              className="native-button primary"
              disabled={
                busy || (config.mode === "createStack" && !members.length)
              }
            >
              {busy ? t("처리 중…") : config.mode === "delete" ? t("삭제") : t("확인")}
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}
