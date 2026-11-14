import Foundation

enum MathPreviewRuntime {
    static func hasMath(in page: String) -> Bool { page.contains("note-math-") }

    private static func resource(_ name: String, extension ext: String) throws -> String {
        let packaged = Bundle.main.resourceURL?
            .appendingPathComponent("SynologyNote_SynologyNote.bundle", isDirectory: true)
            .appendingPathComponent("\(name).\(ext)")
        let url = packaged.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: name, withExtension: ext)
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // Immutable app resources are cached; typing does not reread the library/fonts.
    private static let script: Result<String, Error> = Result {
        let library = try resource("katex.min", extension: "js")
        let css = try resource("katex-offline.min", extension: "css") + """
        .note-math-display{display:block;max-width:100%;overflow-x:auto;overflow-y:hidden;padding:4px 0}
        .note-math .katex{font-size:1.1em}
        .note-math-error{color:light-dark(#b42318,#ff9990);white-space:pre-wrap;font-family:ui-monospace,monospace}
        """
        let json = try JSONSerialization.data(withJSONObject: [css])
        let encodedCSS = String(decoding: json, as: UTF8.self)
        return library + "\n" + #"""
        (() => {
          if (!document.getElementById('note-katex-style')) {
            const style = document.createElement('style');
            style.id = 'note-katex-style';
            style.textContent = \#(encodedCSS)[0];
            document.head.appendChild(style);
          }
          for (const element of document.querySelectorAll('.note-math')) {
            if (element.querySelector('.katex') || element.classList.contains('note-math-error')) continue;
            const source = element.textContent;
            try {
              katex.render(source, element, {
                displayMode: element.classList.contains('note-math-display'),
                output: 'htmlAndMathml',
                throwOnError: true,
                trust: false,
                strict: 'ignore',
                maxExpand: 1000,
                maxSize: 20
              });
            } catch (error) {
              element.textContent = source;
              element.classList.add('note-math-error');
              element.title = '수식 오류: ' + String(error.message || error);
            }
          }
        })();
        """#
    }

    static func renderJavaScript() throws -> String { try script.get() }
}
