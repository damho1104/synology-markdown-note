import Foundation

enum MermaidPreviewRuntime {
    static func hasDiagram(in page: String) -> Bool {
        page.contains("language-mermaid")
    }

    static func libraryJavaScript() throws -> String {
        guard let url = AppLocalization.resources.url(forResource: "mermaid.min", withExtension: "js") else {
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
        let message = (try? JSONEncoder().encode([appText("Could not render the Mermaid diagram.")]))
            .map { String(decoding: $0, as: UTF8.self) } ?? #"["Could not render the Mermaid diagram."]"#
        return #"""
    (() => {
      const blocks = Array.from(document.querySelectorAll('pre > code.language-mermaid'));
      if (blocks.length === 0 || typeof mermaid === 'undefined') return;

      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        htmlLabels: false,
        suppressErrorRendering: true,
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
        const [message] = \#(message);
        for (const element of document.querySelectorAll('.mermaid')) {
          if (!element.querySelector('svg')) {
            const fallback = document.createElement('div');
            const status = document.createElement('p');
            status.setAttribute('role', 'status');
            status.textContent = message;
            const source = document.createElement('pre');
            const code = document.createElement('code');
            code.className = 'language-mermaid';
            code.textContent = element.textContent || '';
            source.appendChild(code);
            fallback.append(status, source);
            element.replaceWith(fallback);
          }
        }
        console.error('Mermaid preview failed', error);
      });
    })();
    """#
    }
}
