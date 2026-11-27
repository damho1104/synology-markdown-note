import { setDefaultLanguage, setLanguage } from "./i18n";

// Existing UI assertions use the Korean catalog. Startup tests exercise production selection.
if (typeof document !== "undefined") {
  setDefaultLanguage("ko");
  setLanguage("ko");
}
