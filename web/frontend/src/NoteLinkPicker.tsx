import { currentLanguage, t } from "./i18n";
import { useMemo, useState } from "react";
export function NoteLinkPicker({
  notes,
  notebooks,
  current,
  onSelect,
  onClose,
}: {
  notes: {
    id: string;
    title: string;
    notebook_id: string;
    locked: boolean;
    trashed: boolean;
  }[];
  notebooks: { id: string; name: string }[];
  current?: string;
  onSelect: (note: { id: string; title: string }) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const [book, setBook] = useState("");
  const rows = useMemo(
    () =>
      notes
        .filter(
          (n) =>
            n.id !== current &&
            !n.locked &&
            !n.trashed &&
            (!book || n.notebook_id === book) &&
            n.title.toLowerCase().includes(query.toLowerCase()),
        )
        .sort((a, b) =>
          a.title.localeCompare(b.title, currentLanguage(), { numeric: true }),
        ),
    [notes, query, current, book],
  );
  return (
    <div className="native-modal-backdrop">
      <section
        className="native-modal"
        role="dialog"
        aria-modal="true"
        aria-label={t("common.linkNote")}
      >
        <h2>{t("common.linkNote")}</h2>
        <label>
          {t("search.search")}
          <input
            autoFocus
            aria-label={t("search.searchForNoteLink")}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
        <select
          aria-label={t("search.notebookLink")}
          value={book}
          onChange={(e) => setBook(e.target.value)}
        >
          <option value="">{t("common.allNotebooks")}</option>
          {notebooks.map((b) => (
            <option value={b.id} key={b.id}>
              {b.name}
            </option>
          ))}
        </select>
        <div style={{ maxHeight: 280, overflow: "auto", marginTop: 12 }}>
          {rows.length ? (
            rows.map((n) => (
              <button
                className="native-nav"
                key={n.id}
                onClick={() => onSelect(n)}
              >
                {n.title || t("common.untitled")}
              </button>
            ))
          ) : (
            <p>{t("common.noResults")}</p>
          )}
        </div>
        <div className="native-dialog-buttons">
          <button className="native-button" onClick={onClose}>
            {t("common.cancel")}
          </button>
        </div>
      </section>
    </div>
  );
}
