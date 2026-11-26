import { currentLanguage, t } from "./i18n";
export type SortField = "title" | "createdAt" | "modifiedAt";
export type SortDirection = "ascending" | "descending";
export type DatedNote = {
  id: string;
  title: string;
  created_at?: number | null;
  modified_at?: number | null;
};
const sortOptions = { numeric: true, sensitivity: "base" } as const;
const collators = { en: new Intl.Collator("en", sortOptions), ko: new Intl.Collator("ko", sortOptions) };
export function sortNotes<T extends DatedNote>(
  notes: T[],
  field: SortField,
  direction: SortDirection,
): T[] {
  const collator = collators[currentLanguage()];
  return [...notes].sort((a, b) => {
    const cmp =
      field === "title"
        ? collator.compare(a.title, b.title)
        : field === "createdAt"
          ? (a.created_at ?? a.modified_at ?? 0) -
            (b.created_at ?? b.modified_at ?? 0)
          : (a.modified_at ?? 0) - (b.modified_at ?? 0);
    return cmp
      ? cmp * (direction === "ascending" ? 1 : -1)
      : collator.compare(a.title, b.title) || a.id.localeCompare(b.id);
  });
}
export function preference<T>(key: string, fallback: T): T {
  try {
    return (
      JSON.parse(localStorage.getItem("synonote:" + key) ?? "null") ?? fallback
    );
  } catch {
    return fallback;
  }
}
export function savePreference(key: string, value: unknown): void {
  try {
    localStorage.setItem("synonote:" + key, JSON.stringify(value));
  } catch {
    /* memory state remains available */
  }
}
export function dateLabel(value?: number | null): string {
  return value
    ? new Date(value * 1000).toLocaleString(currentLanguage(), {
        month: "numeric",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
      })
    : t("날짜 없음");
}

export function remoteNoteLink(label: string, id: string): string {
  return `[${label.replace(/\\/g, "\\\\").replace(/\[/g, "\\[").replace(/\]/g, "\\]")}](synology-note://remote/${encodeURIComponent(id)})`;
}
