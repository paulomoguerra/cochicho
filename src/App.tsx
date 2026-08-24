import { useEffect, useState } from "react";
import Hud from "./hud/Hud";
import Dashboard from "./dashboard/Dashboard";
import EnginePicker from "./dashboard/EnginePicker";
import { onboardingNeeded } from "./lib/ipc";

const isHud = new URLSearchParams(window.location.search).get("window") === "hud";

export default function App() {
  if (isHud) return <Hud />;
  return <DashboardGate />;
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
