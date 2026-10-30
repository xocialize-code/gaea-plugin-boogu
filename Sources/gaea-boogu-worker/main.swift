import BooguPlugin
import GaeaPluginKit

// The plugin's worker: BooguPlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(booguPlugin)
