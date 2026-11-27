import { t, UiError } from "./i18n";
const MAX_MARKDOWN_LENGTH = 2_000_000;

export async function readMarkdownFile(file: File): Promise<{title: string; markdown: string}> {
  const name = /\.(?:md|markdown)$/i.exec(file.name);
  if (!name) throw new UiError("errors.selectMarkdownFileMdOrMarkdown");
  if (file.size > MAX_MARKDOWN_LENGTH * 4) throw new UiError("errors.markdownBodyTooLong");

  const bytes = await new Promise<ArrayBuffer>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as ArrayBuffer);
    reader.onerror = reader.onabort = () => reject(new UiError("errors.couldNotReadFile"));
    reader.readAsArrayBuffer(file);
  });
  let markdown: string;
  try {
    markdown = new TextDecoder("utf-8", {fatal:true}).decode(bytes);
  } catch {
    throw new UiError("errors.selectUtf8MarkdownFile");
  }
  if (markdown.length > MAX_MARKDOWN_LENGTH) throw new UiError("errors.markdownBodyTooLong");
  const title = Array.from(file.name.slice(0, name.index).trim()).slice(0, 256).join("") || t("common.untitled");
  return {title, markdown};
}
