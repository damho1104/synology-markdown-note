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
          a.title.localeCompare(b.title, "ko", { numeric: true }),
        ),
    [notes, query, current, book],
  );
  return (
    <div className="native-modal-backdrop">
      <section
        className="native-modal"
        role="dialog"
        aria-modal="true"
        aria-label="노트 연결"
      >
        <h2>노트 연결</h2>
        <label>
          검색
          <input
            autoFocus
            aria-label="연결할 노트 검색"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
        <select
          aria-label="연결할 메모장"
          value={book}
          onChange={(e) => setBook(e.target.value)}
        >
          <option value="">모든 메모장</option>
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
                {n.title || "제목 없음"}
              </button>
            ))
          ) : (
            <p>검색 결과 없음</p>
          )}
        </div>
        <div className="native-dialog-buttons">
          <button className="native-button" onClick={onClose}>
            취소
          </button>
        </div>
      </section>
    </div>
  );
}
