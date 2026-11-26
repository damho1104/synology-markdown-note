// @vitest-environment jsdom
import { expect, it, vi } from "vitest";
import { screen } from "@testing-library/react";

it("waits for anonymous config and presents the first login screen in the fixed language", async () => {
  document.body.innerHTML = '<div id="root"></div>';
  vi.spyOn(navigator, "languages", "get").mockReturnValue(["ko-KR"]);
  let returnConfig!: (response: Response) => void;
  const config = new Promise<Response>(resolve => { returnConfig = resolve; });
  const fetchMock = vi.fn(async (path: string) => {
    if (path === "/api/public-config") return config;
    if (path === "/api/status") return Response.json({configured: true, nas_url: "https://nas.example", source: "database", read_only: false});
    return Response.json({detail: "LOGIN_REQUIRED"}, {status: 401});
  });
  vi.stubGlobal("fetch", fetchMock);
  try {
    await import("./main");
    expect(fetchMock.mock.calls.map(([path]) => path)).toEqual(["/api/public-config"]);
    expect(document.getElementById("root")?.textContent).toBe("");
    returnConfig(Response.json({default_language: "en"}));
    await screen.findByRole("heading", {name: "Sign in to NAS"});
    expect(document.documentElement.lang).toBe("en");
  } finally {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  }
});
