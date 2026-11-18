# LaTeX Math Preview

**English** | [한국어](math-preview.ko.md)

The Markdown preview renders math with [KaTeX](https://katex.org/). KaTeX 0.19.0 and its fonts are bundled with the app, so no internet connection or additional configuration is required.

Write inline math using `$…$` or `\(…\)`.

```markdown
Mass and energy: $E=mc^2$
Fraction: \(\frac{a}{b}\)
```

Write block math using `$$…$$` or `\[…\]`; multiple lines are supported.

```latex
$$
\begin{aligned}
  x_i &= y_j + 1 \\
  a &= \frac{1}{2}
\end{aligned}
$$

\[\int_0^\infty e^{-x}\,dx = 1\]

$$\begin{pmatrix}a & b \\ c & d\end{pmatrix}$$
```

To display math examples literally, use code blocks or inline code as in the examples above. Inline math also works in headings, lists, table cells, and link text. Long block equations can be scrolled horizontally. Invalid math displays the source in a distinct color and shows the reason for the error on hover.

Escape `$` in ordinary monetary amounts as `\$`. Supported math commands follow the [official KaTeX support list](https://katex.org/docs/supported). Trusted commands that require loading external images or inserting HTML are not allowed.

Starting with 0.2.1 build 8, synchronization generates offline PNGs of equations so that they appear as ordinary image attachments in Note Station on the web. Exact TeX, delimiters, and line breaks are preserved in the Markdown source; the app verifies the fingerprint and image mappings in the v3 source attachment when reopening it for editing. Images for identical equations are reused, and unused generated images are cleaned up during synchronization. The default maximum image size is 2048×2048; very large equations are scaled down proportionally. Invalid math appears as an error image containing the source.

If web edits to the body cause the source attachment to no longer match, the note opens as a rich-text HTML document to preserve those edits. Content in original HTML documents and preservation blocks is not automatically reinterpreted as math. Validation on 2026-10-16 covered actual WebKit image generation and synthetic NAS round trips; it did not recheck display in a real NAS web interface.

To update bundled resources, extract the official npm distribution and run `python3 script/bundle_katex.py /path/to/package`. This script embeds WOFF2 fonts in the CSS; nothing is downloaded while building or running the app. The license is included in `Resources/KATEX-LICENSE.txt`.
