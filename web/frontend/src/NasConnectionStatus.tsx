import { Server } from "lucide-react";
import { t } from "./i18n";

export function NasConnectionStatus({ connected }: { connected: boolean }) {
  const label = connected ? t("auth.connectedNas") : t("common.disconnectedNas");
  return (
    <span className="nas-connection-status" role="img" aria-label={label} title={label} data-connected={connected}>
      <Server size={15} aria-hidden="true" />
      <span className="nas-connection-dot" aria-hidden="true" />
    </span>
  );
}
