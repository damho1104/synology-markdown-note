/** getRandomValues is available on HTTP LAN origins, unlike randomUUID/subtle. */
export function previewNonce(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join(
    "",
  );
}
/** Match InternalNoteLinks.swift / graph_api._identity's decoding order. */
export function canonicalNoteLink(destination: string): string | null {
  const document = "synology-note://note/",
    remote = "synology-note://remote/";
  let decoded = destination;
  try {
    decoded = decodeURIComponent(destination);
  } catch {
    /* use original for document check */
  }
  if (decoded.toLowerCase().startsWith(document)) {
    const id = decoded.slice(document.length);
    return /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id)
      ? document + id.toLowerCase()
      : null;
  }
  if (destination.toLowerCase().startsWith(remote)) {
    const suffix = destination.slice(remote.length);
    if (!suffix || /[/?#]/.test(suffix)) return null;
    try {
      const value = decodeURIComponent(suffix);
      return value ? remote + encodeURIComponent(value) : null;
    } catch {
      return null;
    }
  }
  if (decoded.toLowerCase().endsWith(".md") && decoded.length > 3 && !/[\/\\?#:\n]/.test(decoded))
    return encodeURIComponent(decoded);
  return null;
}
