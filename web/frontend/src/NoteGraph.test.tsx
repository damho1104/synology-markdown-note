// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import {
  cleanup,
  fireEvent,
  render,
  screen,
  within,
  waitFor,
} from "@testing-library/react";
import { NoteGraph, mergeGraph } from "./NoteGraph";
import { GraphIndexProvider } from "./GraphIndex";
import { GraphNavigationProvider, GraphNavigationPanel } from "./GraphNavigation";

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
      if (path.split("?")[0] !== "/api/graph") throw new Error(`Unexpected URL: ${path}`);
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
  const beforeRetry = vi.mocked(fetch).mock.calls.length;
  fireEvent.click(screen.getByRole('button', {name:'다시 시도'}));
  await waitFor(() => expect(vi.mocked(fetch).mock.calls.length).toBeGreaterThan(beforeRetry));
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

it("shows initial nodes and indexing progress while bounded batches are still pending", async () => {
  let finish: (response: Response) => void = () => {};
  const fetcher = vi.fn(async (path: string) => {
    if (path === '/api/auth/me') return new Response(JSON.stringify({username:'test'}));
    if (path === '/api/graph?summary=true') return new Response(JSON.stringify({...snapshot,edges:[],entries:[],pending:snapshot.nodes.map(n => n.id)}));
    return new Promise<Response>(resolve => {finish = resolve});
  });
  vi.stubGlobal('fetch', fetcher);
  render(<NoteGraph onOpenNote={() => {}} />);
  const graph = await screen.findByRole('group', {name:'노트 관계 그래프'});
  expect(within(graph).getAllByRole('button')).toHaveLength(5);
  expect(screen.getByRole('status', {name:'그래프 인덱싱 상태'}).textContent).toContain('0/5');
  expect(fetcher).toHaveBeenCalledTimes(3);
  finish(new Response(JSON.stringify({entries:snapshot.nodes.map(n => ({id:n.id,links:n.id === 'a' ? [{kind:'title',target:'이전 노트'}] : []}))})));
  await waitFor(() => expect(screen.queryByRole('status', {name:'그래프 인덱싱 상태'})).toBeNull());
  expect(within(graph).getAllByRole('button')).toHaveLength(2);
});

it("uses persisted graph entries without any note-body request when all versions are indexed", async () => {
  const entries = snapshot.nodes.map(n => ({id:n.id,links:snapshot.edges.filter(e => e.source === n.id).map(e => ({kind:'remote',target:e.target}))}));
  const fetcher = vi.fn(async (path: string) => new Response(JSON.stringify(path === '/api/auth/me' ? {username:'test'} : {...snapshot,entries,pending:[]})));
  vi.stubGlobal('fetch', fetcher);
  render(<NoteGraph onOpenNote={() => {}} />);
  await screen.findByRole('group', {name:'노트 관계 그래프'});
  await waitFor(() => expect(screen.queryByRole('status', {name:'그래프 인덱싱 상태'})).toBeNull());
  expect(fetcher.mock.calls.filter(([path]) => path !== '/api/auth/me')).toHaveLength(1);
});

it("resolves cross-batch identities and removes ambiguous document edges", () => {
  const nodes = snapshot.nodes;
  const first = {id:'a',links:[{kind:'document',target:'doc'}]};
  expect(mergeGraph(nodes,[first]).edges).toEqual([]);
  expect(mergeGraph(nodes,[first,{id:'b',document_id:'doc'}]).edges).toEqual([{source:'a',target:'b'}]);
  const ambiguous = mergeGraph(nodes,[first,{id:'b',document_id:'doc'},{id:'c',document_id:'DOC'}]);
  expect(ambiguous.edges).toEqual([]);
  expect(ambiguous.failures).toHaveLength(2);
});

it("filters by notebook and follows two-step local links", async () => {
  render(<NoteGraph onOpenNote={() => {}} notebooks={[{id:'book1',name:'첫 메모장'}]} />);
  const graph = await screen.findByRole('group', {name:'노트 관계 그래프'});
  fireEvent.click(within(graph).getByRole('button',{name:'시작'}));
  fireEvent.click(screen.getByRole('button',{name:'연결만 보기'}));
  fireEvent.change(screen.getByRole('combobox',{name:'연결 깊이'}),{target:{value:'2'}});
  expect(within(graph).getByRole('button',{name:'두 단계'})).toBeTruthy();
  fireEvent.change(screen.getByRole('combobox',{name:'그래프 메모장 필터'}),{target:{value:'book1'}});
  expect(within(graph).queryByRole('button',{name:'이전 노트'})).toBeNull();
});


it("keeps compact inspector controls and navigation independent from the whole graph", async () => {
  render(<NoteGraph focusId="a" compact onOpenNote={() => {}} />);
  const graph = await screen.findByRole('group', {name:'노트 관계 그래프'});
  expect(screen.queryByRole('searchbox', {name:'그래프 노트 검색'})).toBeNull();
  expect(screen.queryByRole('combobox', {name:'그래프 메모장 필터'})).toBeNull();
  expect(screen.getByRole('combobox', {name:'연결 깊이'})).toBeTruthy();
  fireEvent.change(screen.getByRole('combobox', {name:'연결 깊이'}), {target:{value:'2'}});
  expect(within(graph).getByRole('button', {name:'두 단계'})).toBeTruthy();
});

const books = [{id:'book1',name:'첫 메모장'}, {id:'book2',name:'둘째 메모장'}];
function SharedGraph({onOpen = () => {}}: {onOpen?: (id:string) => void}) {
  return <GraphIndexProvider><GraphNavigationProvider>
    <GraphNavigationPanel notebooks={books} onOpenNote={onOpen} />
    <NoteGraph notebooks={books} onOpenNote={onOpen} />
    <NoteGraph focusId="c" compact onOpenNote={onOpen} />
  </GraphNavigationProvider></GraphIndexProvider>;
}

it('shares selection, search and filters with the middle panel without duplicate data requests', async () => {
  const open = vi.fn();
  render(<SharedGraph onOpen={open} />);
  const panel = screen.getByRole('navigation', {name:'그래프 탐색'});
  await within(panel).findByRole('heading', {name:'주요 노트'});
  const graphs = await screen.findAllByRole('group', {name:'노트 관계 그래프'});
  await waitFor(() => expect(within(graphs[0]).getAllByRole('button')).toHaveLength(4));
  const ranked = within(panel).getByRole('region', {name:'주요 노트'});
  expect(within(ranked).getAllByRole('button')[0].textContent).toContain('<script>');
  fireEvent.click(within(panel).getByRole('button', {name:'시작'}));
  expect(within(graphs[0]).getByRole('button', {name:'시작'}).getAttribute('aria-pressed')).toBe('true');
  expect(within(graphs[1]).getByRole('button', {name:'이전 노트'}).getAttribute('aria-pressed')).toBe('true');
  expect(within(panel).getByRole('region', {name:'나가는 링크'}).textContent).toContain('<script>');
  fireEvent.click(within(panel).getByRole('button', {name:'노트 열기'}));
  expect(open).toHaveBeenCalledWith('a');
  fireEvent.change(screen.getByRole('searchbox', {name:'그래프 노트 검색'}), {target:{value:'두 단계'}});
  fireEvent.click(within(panel).getByRole('button', {name:'두 단계'}));
  expect((screen.getByRole('searchbox') as HTMLInputElement).value).toBe('');
  fireEvent.click(graphs[0]);
  expect(within(panel).getByRole('heading', {name:'주요 노트'})).toBeTruthy();
  fireEvent.change(screen.getByRole('combobox', {name:'그래프 메모장 필터'}), {target:{value:'book2'}});
  expect(within(panel).getByText('노트 0개 · 연결 0개')).toBeTruthy();
  expect(within(graphs[1]).getByRole('button', {name:'이전 노트'})).toBeTruthy();
  expect(vi.mocked(fetch).mock.calls.filter(([url]) => String(url).startsWith('/api/graph'))).toHaveLength(1);
});

it('uses notebook colors, degree sizes, directed highlights and clears selection on blank space', async () => {
  render(<NoteGraph notebooks={books} onOpenNote={() => {}} />);
  const graph = await screen.findByRole('group', {name:'노트 관계 그래프'});
  const a = within(graph).getByRole('button', {name:'시작'});
  const c = within(graph).getByRole('button', {name:'이전 노트'});
  expect(Number(a.querySelectorAll('circle')[1].getAttribute('r'))).toBeGreaterThan(Number(c.querySelectorAll('circle')[1].getAttribute('r')));
  expect(a.querySelectorAll('circle')[1].getAttribute('fill')).not.toBe(c.querySelectorAll('circle')[1].getAttribute('fill'));
  fireEvent.click(a);
  expect(graph.querySelector('line[data-direction="outgoing"]')?.getAttribute('stroke')).toBe('var(--graph-outgoing)');
  expect(graph.querySelector('line[data-direction="incoming"]')?.getAttribute('stroke')).toBe('var(--graph-incoming)');
  fireEvent.click(graph);
  expect(a.getAttribute('aria-pressed')).toBe('false');
});

it('bounds ranked notes at 16 and search results at 100 while retaining keyboard access', async () => {
  const nodes = Array.from({length:120}, (_,i) => ({id:String(i), title:`문서 ${i}`, notebook_id:'book1'}));
  vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({nodes,edges:nodes.slice(1).map(n => ({source:'0',target:n.id})),failures:[]}))));
  render(<GraphIndexProvider><GraphNavigationProvider>
    <GraphNavigationPanel notebooks={books} onOpenNote={() => {}} />
    <NoteGraph onOpenNote={() => {}} />
  </GraphNavigationProvider></GraphIndexProvider>);
  const panel = screen.getByRole('navigation', {name:'그래프 탐색'});
  await within(panel).findByRole('button', {name:'문서 0'});
  expect(within(within(panel).getByRole('region', {name:'주요 노트'})).getAllByRole('button')).toHaveLength(16);
  fireEvent.change(screen.getByRole('searchbox'), {target:{value:'문서'}});
  expect(within(within(panel).getByRole('region', {name:'검색 결과'})).getAllByRole('button')).toHaveLength(100);
  expect(within(panel).getByText('처음 100개 표시')).toBeTruthy();
});


it('reconciles filtered local focus and counts isolates within the filtered graph', async () => {
  render(<NoteGraph focusId="a" notebooks={books} onOpenNote={() => {}} />);
  await screen.findByRole('group', {name:'노트 관계 그래프'});
  fireEvent.change(screen.getByRole('combobox', {name:'그래프 메모장 필터'}), {target:{value:'book2'}});
  await waitFor(() => expect(screen.queryByRole('combobox', {name:'연결 깊이'})).toBeNull());
  expect(screen.getByText('노트 0 · 연결 0')).toBeTruthy();
  expect(screen.getByText('(미연결 2개 숨김)')).toBeTruthy();
  fireEvent.click(screen.getByRole('checkbox', {name:'연결 없는 노트'}));
  const graph = screen.getByRole('group', {name:'노트 관계 그래프'});
  expect(within(graph).getAllByRole('button')).toHaveLength(2);
  for (const node of within(graph).getAllByRole('button')) expect(node.getAttribute('aria-pressed')).toBe('false');
});

it('selects connections in the panel and shares neighborhood depth with the canvas', async () => {
  const open = vi.fn();
  render(<SharedGraph onOpen={open} />);
  const panel = screen.getByRole('navigation', {name:'그래프 탐색'});
  await within(panel).findByRole('button', {name:'시작'});
  fireEvent.click(within(panel).getByRole('button', {name:'시작'}));
  fireEvent.click(within(panel).getByRole('button', {name:'주변만 보기'}));
  const [graph] = screen.getAllByRole('group', {name:'노트 관계 그래프'});
  expect(within(graph).getAllByRole('button')).toHaveLength(3);
  const connection = within(within(panel).getByRole('region', {name:'나가는 링크'})).getByRole('button', {name:'<script>alert(1)</script>'});
  fireEvent.click(connection);
  expect(within(graph).getByRole('button', {name:'<script>alert(1)</script>'}).getAttribute('aria-pressed')).toBe('true');
  // Selecting a connection explores it without unexpectedly opening the editor.
  expect(open).not.toHaveBeenCalled();
  fireEvent.keyDown(within(graph).getByRole('button', {name:'<script>alert(1)</script>'}), {key:'Escape'});
  expect(within(panel).getByRole('heading', {name:'주요 노트'})).toBeTruthy();
});
