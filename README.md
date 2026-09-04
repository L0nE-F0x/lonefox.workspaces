# Workspace Hover Cards

Omarchy bar widget: workspace number indicators with a rich hover card that shows
exactly what is running on each workspace.

![Hover card showing Workspace 2 with one window: X — Home / X](preview.png)

## Features

- **Live hover card** — hovering a workspace chip shows its name, window count,
  and a per-window list of app icon + window title, instead of the plain
  "Workspace N" tooltip bubble.
- **Accurate app icons** — resolves icons through desktop entries, handling both
  Wayland `appId` and XWayland `class` (e.g. `Google-chrome` → Google Chrome →
  the right icon).
- **Webapp icons** — browser windows are matched by the site name carried in the
  window title (e.g. "Home / X" gets the X icon), so webapps don't all show a
  generic browser icon.
- **Steam games** — `steam_app_<id>` surfaces are resolved to the actual game
  name and icon via the window title.

## Install

Install from the Omarchy plugin marketplace, or manually:

```bash
omarchy plugin install lonefox.workspaces
```

Then add the widget to your bar (replace the built-in workspaces widget if you
use one):

```bash
omarchy bar move lonefox.workspaces --section left
```

## License

MIT — see [LICENSE](LICENSE).
