import { t } from "./i18n";

export function NasConnectionStatus({ connected }: { connected: boolean }) {
  const label = connected ? t("NAS 연결됨") : t("NAS 연결 안 됨");
  return (
    <footer className="nas-connection-footer">
      <span role="img" aria-label={label} title={label} data-connected={connected}>
        NAS
      </span>
    </footer>
  );
}
