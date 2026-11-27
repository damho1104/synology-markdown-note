// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { act, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";

beforeEach(() => {
  vi.resetModules();
  document.documentElement.lang = "en";
  document.body.innerHTML = '<div id="root"></div>';
  vi.spyOn(navigator, "languages", "get").mockReturnValue(["ko-KR"]);
});

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

function mockStartup(requestConfig: (options: RequestInit) => Promise<Response>) {
  const fetchMock = vi.fn(async (path: string, options: RequestInit) => {
    if (path === "/api/public-config") return requestConfig(options);
    if (path === "/api/status") return Response.json({configured: true, nas_url: "https://nas.example", source: "database", read_only: false});
    return Response.json({detail: "LOGIN_REQUIRED"}, {status: 401});
  });
  vi.stubGlobal("fetch", fetchMock);
  return () => fetchMock.mock.calls.map(([path]) => path);
}

it("waits for anonymous config and presents the first login screen in the fixed language", async () => {
  let returnConfig!: (response: Response) => void;
  const config = new Promise<Response>(resolve => { returnConfig = resolve; });
  const requests = mockStartup(() => config);
  await import("./main");
  expect(requests()).toEqual(["/api/public-config"]);
  const status = await screen.findByRole("status");
  expect(status.textContent).toBe("웹 설정을 불러오는 중…");
  expect(status.closest("[lang]")?.getAttribute("lang")).toBe("ko");
  expect(document.documentElement.lang).toBe("en");
  returnConfig(Response.json({default_language: "en"}));
  await screen.findByRole("heading", {name: "Sign in to NAS"});
  expect(document.documentElement.lang).toBe("en");
});

it("aborts a timed-out request and uses the forced language from the next request", async () => {
  vi.useFakeTimers();
  let firstSignal!: AbortSignal;
  let returnConfig!: (response: Response) => void;
  const nextConfig = new Promise<Response>(resolve => { returnConfig = resolve; });
  const requestConfig = vi.fn<(options: RequestInit) => Promise<Response>>()
    .mockImplementationOnce(({signal}) => new Promise((_resolve, reject) => {
      firstSignal = signal!;
      firstSignal.addEventListener("abort", () => reject(firstSignal.reason), {once: true});
    }))
    .mockReturnValueOnce(nextConfig);
  const requests = mockStartup(requestConfig);

  await act(async () => { await import("./main"); });
  await act(async () => { await vi.advanceTimersByTimeAsync(3999); });
  expect(firstSignal.aborted).toBe(true);
  expect(requests()).toEqual(["/api/public-config"]);
  await act(async () => { await vi.advanceTimersByTimeAsync(1); });
  expect(requests()).toEqual(["/api/public-config", "/api/public-config"]);
  expect(requestConfig.mock.calls[1][0].signal?.aborted).toBe(false);
  await act(async () => { returnConfig(Response.json({default_language: "en"})); });
  vi.useRealTimers();

  await screen.findByRole("heading", {name: "Sign in to NAS"});
  expect(document.documentElement.lang).toBe("en");
});

it("offers a keyboard retry in the same document when early requests fail", async () => {
  vi.spyOn(navigator, "languages", "get").mockReturnValue(["en-US"]);
  vi.useFakeTimers();
  let returnConfig!: (response: Response) => void;
  const retryConfig = new Promise<Response>(resolve => { returnConfig = resolve; });
  const requestConfig = vi.fn<() => Promise<Response>>()
    .mockRejectedValueOnce(new TypeError("Network unavailable"))
    .mockResolvedValueOnce(Response.json({}))
    .mockReturnValueOnce(retryConfig);
  const requests = mockStartup(requestConfig);
  const root = document.getElementById("root");

  await act(async () => { await import("./main"); });
  await act(async () => { await vi.advanceTimersByTimeAsync(1000); });
  vi.useRealTimers();
  expect(requests()).toEqual(["/api/public-config", "/api/public-config"]);
  const status = screen.getByRole("status");
  expect(status.textContent).toBe("Could not load web settings.");
  expect(status.closest("[lang]")?.getAttribute("lang")).toBe("en");
  const retry = screen.getByRole("button", {name: "Retry"});
  const user = userEvent.setup();
  await user.tab();
  expect(document.activeElement).toBe(retry);
  await user.keyboard("{Enter}");
  expect(document.activeElement).toBe(retry);
  expect(retry.getAttribute("aria-disabled")).toBe("true");
  await user.keyboard("{Enter}");
  expect(requests()).toEqual([
    "/api/public-config", "/api/public-config", "/api/public-config",
  ]);

  returnConfig(Response.json({default_language: "ko"}));
  await screen.findByRole("heading", {name: "NAS 계정 로그인"});
  expect(document.getElementById("root")).toBe(root);
  expect(document.documentElement.lang).toBe("ko");
});
