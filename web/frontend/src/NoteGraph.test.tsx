// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  within,
} from "@testing-library/react";
import { NoteGraph } from "./NoteGraph";

const snapshot = {
  nodes: [
    { id: "a", title: "시작", notebook_id: "book1" },
    { id: "b", title: "<script>alert(1)</script>", notebook_id: "book1" },
    { id: "c", title: "이전 노트", notebook_id: "book2" },
    { id: "d", title: "연결 없는 문서", notebook_id: "book2" },
    { id: "e", title: "두 단계", notebook_id: "book1" },
  ],
  edges: [
    { source: "a", target: "b" },
    { source: "c", target: "a" },
    { source: "b", target: "e" },
  ],
  failures: [],
};

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (path: string) => {
      if (path === "/api/auth/me")
        return new Response(
          JSON.stringify({
            username: "test",
            csrf_token: "test",
            remember: true,
          }),
        );
      if (path !== "/api/graph") throw new Error(`Unexpected URL: ${path}`);
      return new Response(JSON.stringify(snapshot));
    }),
  );
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

it("renders real SVG nodes, escapes titles, selects connections and opens a note", async () => {
  const onOpen = vi.fn();
  const { container } = render(<NoteGraph onOpenNote={onOpen} />);
  const graph = await screen.findByRole("group", { name: "노트 관계 그래프" });
  expect(graph.tagName.toLowerCase()).toBe("svg");
  expect(container.querySelector("script")).toBeNull();
  fireEvent.click(within(graph).getByRole("button", { name: "시작" }));
  expect(
    within(screen.getByRole("region", { name: "나가는 링크" })).getByText(
      "<script>alert(1)</script>",
    ),
  ).toBeTruthy();
  expect(
    within(screen.getByRole("region", { name: "백링크" })).getByText(
      "이전 노트",
    ),
  ).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "노트 열기" }));
  expect(onOpen).toHaveBeenLastCalledWith("a");
  fireEvent.doubleClick(
    within(graph).getByRole("button", { name: "<script>alert(1)</script>" }),
  );
  expect(onOpen).toHaveBeenLastCalledWith("b");
  fireEvent.keyDown(within(graph).getByRole("button", { name: "이전 노트" }), {
    key: "Enter",
  });
  expect(onOpen).toHaveBeenLastCalledWith("c");
});

it("searches, zooms, resets and shows isolated nodes on demand", async () => {
  render(<NoteGraph onOpenNote={() => {}} />);
  const graph = await screen.findByRole("group", { name: "노트 관계 그래프" });
  expect(
    within(graph).queryByRole("button", { name: "연결 없는 문서" }),
  ).toBeNull();
  fireEvent.click(screen.getByRole("checkbox", { name: "연결 없는 노트" }));
  expect(
    within(graph).getByRole("button", { name: "연결 없는 문서" }),
  ).toBeTruthy();
  fireEvent.change(
    screen.getByRole("searchbox", { name: "그래프 노트 검색" }),
    { target: { value: "시작" } },
  );
  expect(
    screen.getByRole("region", { name: "검색 결과" }).textContent,
  ).toContain("시작");
  expect(
    screen.getByRole("region", { name: "검색 결과" }).textContent,
  ).not.toContain("이전 노트");
  fireEvent.click(screen.getByRole("button", { name: "확대" }));
  expect(screen.getByLabelText("확대 비율").textContent).toBe("125%");
  fireEvent.click(screen.getByRole("button", { name: "초기화" }));
  expect(screen.getByLabelText("확대 비율").textContent).toBe("100%");
  expect((screen.getByRole("searchbox") as HTMLInputElement).value).toBe("");
});

it("follows focusId and lets selection switch to a local neighborhood", async () => {
  const { rerender } = render(<NoteGraph focusId="a" onOpenNote={() => {}} />);
  const graph = await screen.findByRole("group", { name: "노트 관계 그래프" });
  expect(within(graph).queryByRole("button", { name: "두 단계" })).toBeNull();
  expect(within(graph).getAllByRole("button")).toHaveLength(3);
  fireEvent.click(screen.getByRole("button", { name: "전체 그래프" }));
  expect(within(graph).getByRole("button", { name: "두 단계" })).toBeTruthy();
  fireEvent.click(
    within(graph).getByRole("button", { name: "<script>alert(1)</script>" }),
  );
  fireEvent.click(screen.getByRole("button", { name: "연결만 보기" }));
  expect(within(graph).queryByRole("button", { name: "이전 노트" })).toBeNull();
  rerender(<NoteGraph focusId="c" onOpenNote={() => {}} />);
  expect(within(graph).getAllByRole("button")).toHaveLength(2);
  expect(within(graph).getByRole("button", { name: "이전 노트" })).toBeTruthy();
});

it("displays partial read failures alongside usable data", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            ...snapshot,
            failures: [{ id: "b", error: "NAS_UNAVAILABLE" }],
          }),
        ),
    ),
  );
  render(<NoteGraph onOpenNote={() => {}} />);
  expect((await screen.findByRole("alert")).textContent).toContain("b");
  expect(screen.getByRole("alert").textContent).toContain("NAS_UNAVAILABLE");
  expect(screen.getByRole("group", { name: "노트 관계 그래프" })).toBeTruthy();
});

it("reports request failure and retries only on user request", async () => {
  const fetcher = vi
    .fn()
    .mockResolvedValueOnce(
      new Response(JSON.stringify({ error: "RELOGIN_REQUIRED" }), {
        status: 401,
      }),
    )
    .mockResolvedValueOnce(new Response(JSON.stringify(snapshot)));
  vi.stubGlobal(
    "fetch",
    vi.fn(async (path: string) =>
      path === "/api/auth/me"
        ? new Response(JSON.stringify({ username: "test" }))
        : fetcher(),
    ),
  );
  render(<NoteGraph onOpenNote={() => {}} />);
  expect((await screen.findByRole("alert")).textContent).toContain("재인증");
  expect(fetcher).toHaveBeenCalledTimes(1);
  fireEvent.click(screen.getByRole("button", { name: "다시 시도" }));
  expect(
    await screen.findByRole("group", { name: "노트 관계 그래프" }),
  ).toBeTruthy();
});

it("renders an empty state for an empty graph", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(JSON.stringify({ nodes: [], edges: [], failures: [] })),
    ),
  );
  render(<NoteGraph onOpenNote={() => {}} />);
  expect(await screen.findByText("표시할 노트가 없습니다")).toBeTruthy();
});

it("keeps hit targets separate in a large connected graph", async () => {
  const nodes = Array.from({ length: 200 }, (_, i) => ({
    id: String(i),
    title: `노트 ${i}`,
    notebook_id: "book",
  }));
  const edges = nodes
    .slice(1)
    .map((node) => ({ source: "0", target: node.id }));
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () => new Response(JSON.stringify({ nodes, edges, failures: [] })),
    ),
  );
  render(<NoteGraph onOpenNote={() => {}} />);
  const graph = await screen.findByRole("group", { name: "노트 관계 그래프" });
  const targets = within(graph)
    .getAllByRole("button")
    .map((node) => {
      const [x, y] = node
        .getAttribute("transform")!
        .match(/-?\d+(?:\.\d+)?/g)!
        .map(Number);
      const radius = Number(node.querySelector("circle")!.getAttribute("r"));
      return { x, y, radius };
    });
  expect(targets).toHaveLength(200);
  for (let i = 0; i < targets.length; i++) {
    for (let j = i + 1; j < targets.length; j++) {
      const a = targets[i],
        b = targets[j];
      expect(Math.hypot(a.x - b.x, a.y - b.y)).toBeGreaterThan(
        a.radius + b.radius,
      );
    }
  }
});
