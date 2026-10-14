# Design system: native SwiftUI

The app uses stock macOS SwiftUI components with no custom palette. Most of the look comes from the system. The few shared pieces live in `jira-ado-swift/Views/Widgets.swift`.

## Foundations

- **Colours:** only semantic colours: `.primary`, `.secondary`, `.separator`, `.background.secondary`, `.tint` and `Color.accentColor`. No hex values appear in the Swift code.
- **Accent:** `AccentColor.colorset` has no value set, so the accent follows the user's System Settings accent.
- **Theme:** the `theme` setting is `system`, `light` or `dark`. `JiraADOApp` applies it with `.preferredColorScheme` (`system` = `nil`). You can change it from the segmented picker in Settings → Appearance or the sun/moon toolbar button.
- **Type:** the system font and its text styles (`.caption`, `.callout`, `.title`). Monospaced is used for Jira keys, timestamps, URLs and HTTP bodies.
- **Materials:** the toast uses `.regularMaterial` with a small shadow. Nothing else sets a material.

## Status colours

| Value | Colour |
|---|---|
| Job ACTIVE / PAUSED | green / orange |
| Run success / partial / failed | green / orange / red |
| Ticket created / updated / skipped / failed | green / accent / secondary / red |

## Components

- **Pill:** caption2 bold text in the status colour, on a 15% tint of that colour inside a `Capsule`.
- **StatCard:** a label in caption/secondary and a value in `.title.bold()`. It sits on `.background.secondary` with radius 10 and a `.separator` hairline.
- **KV:** a `LabeledContent` row with selectable text, used inside `.formStyle(.grouped)` forms.
- **Mono:** selectable 11pt monospaced text that scrolls (max height 160) on `.background.secondary` with radius 6. It shows request and response bodies.
- **Report rows and banners:** rows have radius 8 with a `.separator` stroke. Banners use a 10% tint of their colour.
- **Empty states:** `ContentUnavailableView`.

## Layout

- **Shell:** `NavigationSplitView` with a standard `List` sidebar (one "Jira → ADO" section, the account in a bottom inset) and a `NavigationStack` for detail pages.
- **Toolbar:** a standard `.primaryAction` group with three buttons: theme toggle, New Sync Job (⌘N) and Search (⌘K palette sheet).
- **App icon:** there are three Dock icons (`icon-merge`, `icon-bridge`, `icon-lanes`), picked in Settings. Bridge is the packaged `AppIcon`. The SVG sources are in `design/logo/`.

## Dropped from the MyGo design

The user chose a native look, so these were not ported:

- **Always-dark floating sidebar:** it had custom sidebar text colours and traffic lights inside the panel.
- **Graphite greys and the Linear surface ladder:** dark mode now uses the system greys.
- **Fixed Linear accent `#5e6ad2`:** replaced by the system accent.
- **Capsule toolbar, search pill, topbar breadcrumbs and keycap empty hints:** replaced by the standard toolbar, navigation titles and `ContentUnavailableView`.

## Reference

- **Linear palette:** the earlier research ([getdesign.md](https://getdesign.md/linear.app/design-md)) can help if we want a brand accent later. Set it in `AccentColor.colorset`: primary `#5e6ad2`, hover `#828fff`, success `#27a644`. Linear only documents a dark theme.
