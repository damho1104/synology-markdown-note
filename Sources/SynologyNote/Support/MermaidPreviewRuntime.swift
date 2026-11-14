import Foundation

enum MermaidPreviewRuntime {
    static func hasDiagram(in page: String) -> Bool {
        page.contains("language-mermaid")
    }

    static func libraryJavaScript() throws -> String {
        let packagedURL = Bundle.main.resourceURL?
            .appendingPathComponent("SynologyNote_SynologyNote.bundle", isDirectory: true)
            .appendingPathComponent("mermaid.min.js")
        let url: URL?
        if let packagedURL, FileManager.default.fileExists(atPath: packagedURL.path) {
            url = packagedURL
        } else {
            url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js")
        }
        guard let url else {
            throw CocoaError(.fileNoSuchFile)
        }
        // The library's final expression is an object that older WebKit cannot
        // bridge to Swift. Its side effects have completed; return a safe value
        // so the preview coordinator can continue with diagram rendering.
        return try String(contentsOf: url, encoding: .utf8) + "\n;null;"
    }

    static func bootstrapJavaScript(style: MermaidStyle = .sketch, theme: MermaidTheme = .automatic) -> String {
        let themeExpression = theme == .automatic
            ? "window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default'"
            : "'\(theme.rawValue)'"
        return #"""
    (() => {
      const blocks = Array.from(document.querySelectorAll('pre > code.language-mermaid'));
      if (blocks.length === 0 || typeof mermaid === 'undefined') return;

      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        htmlLabels: false,
        suppressErrorRendering: false,
        look: '\#(style.rawValue)',
        handDrawnSeed: 42,
        theme: \#(themeExpression)
      });

      for (const code of blocks) {
        const container = document.createElement('div');
        container.className = 'mermaid';
        container.textContent = code.textContent || '';
        code.parentElement.replaceWith(container);
      }

      mermaid.run({ querySelector: '.mermaid', suppressErrors: false }).catch((error) => {
        for (const element of document.querySelectorAll('.mermaid')) {
          if (!element.querySelector('svg')) {
            const fallback = document.createElement('pre');
            const code = document.createElement('code');
            code.className = 'language-mermaid';
            code.textContent = element.textContent || '';
            fallback.appendChild(code);
            element.replaceWith(fallback);
          }
        }
        console.error('Mermaid preview failed', error);
      });
    })();
    """#
    }
}
