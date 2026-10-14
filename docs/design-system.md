# Design system: Linear tokens on MyGo

## Source

- **getdesign.md** is a catalog of DESIGN.md files (Google DESIGN.md spec) for well-known products, maintained by VoltAgent: https://getdesign.md/design-md
- **Chosen file:** https://getdesign.md/linear.app/design-md. The page renders it client-side, so the raw copy came from https://raw.githubusercontent.com/VoltAgent/awesome-design-md/main/design-md/linear.app/DESIGN.md (the same file is in npm `getdesign@0.6.26`, `templates/linear.app.md`).
- **Caveat:** each file describes the product's *marketing site*, not its app.

## Shortlist

| System | Why |
|---|---|
| **Linear** (picked) | Dense, technical tool, one accent, hierarchy from a surface ladder plus hairlines. Its font fallback is SF Pro, which is what macOS already uses. |
| Raycast | A macOS-native tool with full success/warning/danger colors and 15% soft tints (our pill already uses that formula). Its accent is white, and it is dark-only. |
| Vercel | Dense neutral greys, light only. It has error and warning colors but no success. |
| Apple | The macOS look, but tuned for a consumer product page. It has no semantic colors. |
| Sentry | A developer/admin tool, but its look is purple-heavy brand. |

## Linear tokens (quoted)

- **Colors (dark only):** canvas `#010102`; surface-1/2/3 `#0f1011` `#141516` `#18191a`; hairline `#23252a`; ink `#f7f8f8`; ink-subtle `#8a8f98`; primary `#5e6ad2`, hover `#828fff`, focus `#5e69d1`; on-primary `#ffffff`; semantic-success `#27a644`.
- **Missing:** a light theme ("Light mode is not documented"), warning, danger, tables, sidebar.
- **Type:** SF Pro fallback. Caption 12/400, body-sm 14/400, button 14/500, mono 13/400, subhead 20/400, card-title 22/500, headline 28/600. The doc says "Linear resists 700+".
- **Spacing:** 4px base: 4, 8, 12, 16, 24, 32, 48.
- **Radius:** xs 4 (badges), sm 6, md 8 (buttons, inputs), lg 12 (cards), pill 9999.
- **Elevation:** no drop shadows. Depth comes from the surface ladder plus a 1px hairline. The focus ring is a 2px primary-focus outline at 50% opacity.
- **Components:** status-badge is surface-2, ink-muted, caption, pill, padding 2px 8px. Buttons are padded 8px 14px. Cards are surface-1 with a hairline and 24px padding. Rows have a 1px hairline bottom rule.

## Theme mapping

```go
t := *c.Theme() // keeps system appearance, Danger/Warning defaults
t.Radius = 8 // rounded.md
t.Accent, t.AccentHover, t.AccentPressed, t.AccentText =
	ui.Hex("#5e6ad2"), ui.Hex("#828fff"), ui.Hex("#5e69d1"), ui.Hex("#ffffff")
t.Focus = ui.Hex("#5e69d1").Alpha(0.5)
if t.Dark {
	t.Background = ui.Hex("#010102")
	t.Surface, t.SurfaceHover, t.SurfacePressed =
		ui.Hex("#0f1011"), ui.Hex("#141516"), ui.Hex("#18191a")
	t.Border = ui.Hex("#23252a")
	t.Text, t.TextMuted = ui.Hex("#f7f8f8"), ui.Hex("#8a8f98")
	t.Success = ui.Hex("#27a644")
}
c.SetTheme(&t)
```

- **Unchanged:** `Spacing` stays 4 (it matches Linear's base), `FontSize` stays 13 (the macOS default), and `Font` stays `""` (the system font, which is Linear's fallback).
- **Light mode:** keeps `LightTheme()` colors and gets only the accent and radius.

## widgets.go changes

| Helper | Now | Change |
|---|---|---|
| `page` title | 20 `Bold()` | 20 `FontWeight(600)` |
| `card` | radius 10, padding 14/16 | `Radius(12)`, keep padding 16 for density (Linear uses 24) |
| `stat` value | 24 `Bold()` | 22 `FontWeight(500)` (card-title) |
| `pill` | 11 bold, radius 10 | `FontSize(12)`, no Bold, `Radius(999)`; keep the 0.15 status tint (Linear's badge is grey, which hides status) |
| `mono` | 11, radius 6 | `FontSize(13)` |

## macOS conflicts

- **Vibrancy sidebar:** keep it. Linear has no sidebar spec, and `app.go` already skips the background when vibrancy is on.
- **System font:** keep it. Linear's fallback is SF Pro anyway.
- **Canvas `#010102`:** much darker than native dark windows. Consider `#0f1011` as `Background` if it looks harsh next to the vibrancy sidebar.
- **Fixed accent:** this overrides the user's system accent (`c.Preferences().Accent`). It is a trade-off between brand and native feel.
