import { t } from "./i18n";

export function NasConnectionStatus({ connected }: { connected: boolean }) {
  const label = connected ? t("auth.connectedNas") : t("common.disconnectedNas");
  return (
    <footer className="nas-connection-footer">
      <span role="img" aria-label={label} title={label} data-connected={connected}>
        NAS
      </span>
    </footer>
  );
}
