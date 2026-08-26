import { useEffect, useState } from "react";
import Hud from "./hud/Hud";
import Dashboard from "./dashboard/Dashboard";
import EnginePicker from "./dashboard/EnginePicker";
import { onSettingsChanged, onboardingNeeded, settingsGet } from "./lib/ipc";
import { applyAppearance, readStoredAppearance } from "./lib/theme";

const isHud = new URLSearchParams(window.location.search).get("window") === "hud";
if (isHud) document.documentElement.classList.add("hud-window");

export default function App() {
  return (
    <>
      <ThemeSync />
      {isHud ? <Hud /> : <DashboardGate />}
    </>
  );
}

function ThemeSync() {
  useEffect(() => {
    applyAppearance(readStoredAppearance());
    settingsGet()
      .then((s) => applyAppearance(s.appearance ?? "dark"))
      .catch((reason) => {
        // Appearance is non-critical because the stored value is already
        // applied above, but keep a diagnostic instead of hiding an IPC error.
        console.warn("Eko Nami: falha ao carregar aparência", reason);
      });
    const unsub = onSettingsChanged((s) => applyAppearance(s.appearance ?? "dark"))
      .catch((reason) => {
        console.warn("Eko Nami: falha ao acompanhar aparência", reason);
        return () => {};
      });
    return () => {
      unsub.then((fn) => fn()).catch(() => {});
    };
  }, []);
  return null;
}

function DashboardGate() {
  const [needsOnboarding, setNeedsOnboarding] = useState<boolean | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [retryCount, setRetryCount] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setNeedsOnboarding(null);
    setLoadError(null);
    onboardingNeeded()
      .then((value) => {
        if (!cancelled) setNeedsOnboarding(value);
      })
      .catch((reason) => {
        if (!cancelled) setLoadError(describeIpcError(reason));
      });
    return () => {
      cancelled = true;
    };
  }, [retryCount]);

  if (loadError) {
    return (
      <IpcFailure
        title="NÃO FOI POSSÍVEL INICIAR"
        message={loadError}
        onRetry={() => setRetryCount((count) => count + 1)}
      />
    );
  }

  if (needsOnboarding === null) {
    return <div className="dash muted" role="status" aria-live="polite">CARREGANDO…</div>;
  }

  if (needsOnboarding) {
    return <EnginePicker onDone={() => setNeedsOnboarding(false)} />;
  }

  return <Dashboard />;
}

function describeIpcError(reason: unknown): string {
  if (reason instanceof Error && reason.message) return reason.message;
  if (typeof reason === "string" && reason.trim()) return reason;
  if (reason && typeof reason === "object") {
    try {
      const serialized = JSON.stringify(reason);
      if (serialized && serialized !== "{}") return serialized;
    } catch {
      // Fall through to the stable user-facing message below.
    }
  }
  return "Verifique se o app está aberto corretamente e tente novamente.";
}

function IpcFailure({
  title,
  message,
  onRetry,
}: {
  title: string;
  message: string;
  onRetry: () => void;
}) {
  return (
    <div
      className="dash"
      role="alert"
      style={{
        display: "flex",
        minHeight: "100%",
        alignItems: "center",
        justifyContent: "center",
      }}
    >
      <div className="card" style={{ width: "100%", maxWidth: 520, height: "auto" }}>
        <div className="card-header">
          <span className="card-num">!</span>
          <span className="card-title">{title}</span>
        </div>
        <div className="card-body">
          <p style={{ margin: 0, color: "var(--accent)", fontSize: 12, lineHeight: 1.5 }}>
            {message}
          </p>
          <button type="button" className="pill prominent" onClick={onRetry}>
            TENTAR DE NOVO
          </button>
        </div>
      </div>
    </div>
  );
}
