import { useEffect, useState } from "react";
import Hud from "./hud/Hud";
import Dashboard from "./dashboard/Dashboard";
import EnginePicker from "./dashboard/EnginePicker";
import { onSettingsChanged, onboardingNeeded, settingsGet } from "./lib/ipc";
import { applyAppearance, readStoredAppearance } from "./lib/theme";

const isHud = new URLSearchParams(window.location.search).get("window") === "hud";

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
      .catch(() => {});
    const unsub = onSettingsChanged((s) => applyAppearance(s.appearance ?? "dark"));
    return () => {
      unsub.then((fn) => fn());
    };
  }, []);
  return null;
}

function DashboardGate() {
  const [needsOnboarding, setNeedsOnboarding] = useState<boolean | null>(null);

  useEffect(() => {
    onboardingNeeded()
      .then(setNeedsOnboarding)
      .catch(() => setNeedsOnboarding(false));
  }, []);

  if (needsOnboarding === null) {
    return <div className="dash muted">…</div>;
  }

  if (needsOnboarding) {
    return <EnginePicker onDone={() => setNeedsOnboarding(false)} />;
  }

  return <Dashboard />;
}
