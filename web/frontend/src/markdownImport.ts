import { t, UiError } from "./i18n";
const MAX_MARKDOWN_LENGTH = 2_000_000;

export async function readMarkdownFile(file: File): Promise<{title: string; markdown: string}> {
  const name = /\.(?:md|markdown)$/i.exec(file.name);
  if (!name) throw new UiError("Markdown 파일(.md, .markdown)을 선택하세요.");
  if (file.size > MAX_MARKDOWN_LENGTH * 4) throw new UiError("Markdown 본문이 너무 깁니다.");

  const bytes = await new Promise<ArrayBuffer>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as ArrayBuffer);
    reader.onerror = reader.onabort = () => reject(new UiError("파일을 읽을 수 없습니다."));
    reader.readAsArrayBuffer(file);
  });
  let markdown: string;
  try {
    markdown = new TextDecoder("utf-8", {fatal:true}).decode(bytes);
  } catch {
    throw new UiError("UTF-8 Markdown 파일을 선택하세요.");
  }
  if (markdown.length > MAX_MARKDOWN_LENGTH) throw new UiError("Markdown 본문이 너무 깁니다.");
  const title = Array.from(file.name.slice(0, name.index).trim()).slice(0, 256).join("") || t("제목 없음");
  return {title, markdown};
}
