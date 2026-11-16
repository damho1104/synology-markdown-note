// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { HttpNasWarning } from "./HttpNasWarning";
beforeEach(() => localStorage.clear());
afterEach(() => { cleanup(); vi.restoreAllMocks(); });
const close = () => fireEvent.click(screen.getByRole("button", { name: "NAS HTTP 연결 경고 닫기" }));
it("remembers dismissal across remounts for the same NAS", () => {
  const view = render(<HttpNasWarning nasUrl="http://nas.example:5000" />);
  expect(screen.getByRole("region")).toBeTruthy();
  close();
  expect(screen.queryByRole("region")).toBeNull();
  view.unmount();
  render(<HttpNasWarning nasUrl="http://nas.example:5000" />);
  expect(screen.queryByRole("region")).toBeNull();
});
it("resets dismissal whenever the NAS address changes, including a return to an earlier address", () => {
  const view = render(<HttpNasWarning nasUrl="http://one.example" />);
  close();
  view.rerender(<HttpNasWarning nasUrl="http://one.example:5000" />);
  expect(screen.getByRole("region")).toBeTruthy();
  close();
  view.rerender(<HttpNasWarning nasUrl="http://one.example" />);
  expect(screen.getByRole("region")).toBeTruthy();
});
it("never warns for HTTPS and resets the old HTTP dismissal when the protocol changes", () => {
  const view = render(<HttpNasWarning nasUrl="http://nas.example" />);
  close();
  view.rerender(<HttpNasWarning nasUrl="https://nas.example" />);
  expect(screen.queryByRole("region")).toBeNull();
  view.rerender(<HttpNasWarning nasUrl="http://nas.example" />);
  expect(screen.getByRole("region")).toBeTruthy();
});
it("still closes in memory if browser storage is blocked", () => {
  vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => { throw new Error("blocked"); });
  vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new Error("blocked"); });
  const view = render(<HttpNasWarning nasUrl="http://nas.example" />);
  close();
  expect(screen.queryByRole("region")).toBeNull();
  view.rerender(<HttpNasWarning nasUrl="http://other.example" />);
  expect(screen.getByRole("region")).toBeTruthy();
});
