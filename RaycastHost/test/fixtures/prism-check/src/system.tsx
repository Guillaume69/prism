// Essai de BrowserExtension et WindowManagement dans Prism : n'affiche que des nombres, jamais de titres ni d'adresses.
import { Detail, BrowserExtension, WindowManagement } from "@raycast/api";
import { useEffect, useState } from "react";

const VERSION = "v4";

export default function Command() {
  const [lines, setLines] = useState<string[]>([]);
  useEffect(() => {
    (async () => {
      const result: string[] = [`Version : ${VERSION}`];
      try {
        const tabs = await BrowserExtension.getTabs();
        result.push(`Onglets : ${tabs.length} (actif : ${tabs.filter((tab) => tab.active).length})`);
      } catch (error) {
        result.push(`Onglets : erreur — ${(error as Error).message}`);
      }
      try {
        const windows = await WindowManagement.getWindowsOnActiveDesktop();
        result.push(`Fenêtres visibles : ${windows.length} (déplaçables : ${windows.filter((window) => window.positionable).length})`);
      } catch (error) {
        result.push(`Fenêtres visibles : erreur — ${(error as Error).message}`);
      }
      try {
        const active = await WindowManagement.getActiveWindow();
        const size = active.bounds === "fullscreen" ? "plein écran" : `${Math.round(active.bounds.size.width)}×${Math.round(active.bounds.size.height)}`;
        result.push(`Fenêtre active : ${size}, déplaçable : ${active.positionable}`);
        // setWindowBounds avec les dimensions actuelles : l'appel est réel, la fenêtre ne bouge pas.
        if (active.bounds !== "fullscreen" && active.positionable) {
          await WindowManagement.setWindowBounds({ id: active.id, bounds: active.bounds });
          const after = await WindowManagement.getActiveWindow();
          const same = after.bounds !== "fullscreen" && Math.abs(after.bounds.size.width - active.bounds.size.width) < 2;
          result.push(`setWindowBounds : ${same ? "appliqué, dimensions conservées" : "dimensions changées"}`);
        }
      } catch (error) {
        result.push(`Fenêtre active : erreur — ${(error as Error).message}`);
      }
      const desktops = await WindowManagement.getDesktops();
      result.push(`Écrans : ${desktops.length}`);
      setLines(result);
    })();
  }, []);
  return <Detail isLoading={lines.length === 0} markdown={lines.map((line) => `- ${line}`).join("\n")} />;
}
