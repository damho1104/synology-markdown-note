import { expect, it } from "vitest";
import { sortNotes } from "./library";
const notes = [
  { id: "b", title: "노트 10", created_at: null, modified_at: 30 },
  { id: "a", title: "노트 2", created_at: 10, modified_at: 40 },
  { id: "c", title: "노트 1", created_at: 20, modified_at: 20 },
];
it("defaults to newest modified first like the Mac app", () => {
  expect(sortNotes(notes, "modifiedAt", "descending").map((n) => n.id)).toEqual(
    ["a", "b", "c"],
  );
});
it("uses modified date when a legacy note has no creation date", () => {
  expect(sortNotes(notes, "createdAt", "ascending").map((n) => n.id)).toEqual([
    "a",
    "c",
    "b",
  ]);
});
it("uses natural title sorting", () => {
  expect(sortNotes(notes, "title", "ascending").map((n) => n.id)).toEqual([
    "c",
    "a",
    "b",
  ]);
});
