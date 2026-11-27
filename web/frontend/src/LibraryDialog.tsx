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
      setError(errorText(error, "library.operationFailed"));
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
              ? t("library.thisRemovesStackGroupingAndKeepsItsNotebooks")
              : t("library.thisDeletesNotebookNasAndMovesItsNotes")}</p>
          ) : config.mode === "notebook" ? (
            <label>
              {t("common.notebook")}
              <select
                autoFocus
                value={value}
                required
                onChange={(e) => setValue(e.target.value)}
              >
                <option value="" disabled>
                  {t("common.selectNotebook")}
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
              {t("common.stack")}
              <select
                autoFocus
                value={value}
                onChange={(e) => setValue(e.target.value)}
              >
                <option value="">{t("common.unstackedNotebooks")}</option>
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
              {config.mode === "tags" ? t("library.tagsCommaSeparated") : t("library.name")}
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
              <legend>{t("library.notebooksAddStack")}</legend>
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
              {t("common.cancel")}
            </button>
            <button
              type="submit"
              className="native-button primary"
              disabled={
                busy || (config.mode === "createStack" && !members.length)
              }
            >
              {busy ? t("library.working") : config.mode === "delete" ? t("library.delete") : t("library.confirm")}
            </button>
          </div>
        </form>
      </section>
    </div>
  );
}
