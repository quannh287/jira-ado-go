# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Stack

Desktop app built with [MyGo](https://github.com/egoist/mygo) (`github.com/egoist/mygo` v0.4.8) using **native UI** (package `github.com/egoist/mygo/ui`): the interface is written in Go and drawn by MyGo on the GPU — no webview, HTML, JS, or frontend build. Pure Go module; no bun/npm. Currently a todo-list prototype; the Jira/ADO functionality is not written yet.

## Commands

- `go tool mygo dev` — run the app with reload (CLI is pinned as a Go tool in `go.mod`)
- `go tool mygo build` — package the app into `build/`
- `CGO_ENABLED=0 go test ./...` — tests; single test: `CGO_ENABLED=0 go test -run TestTodos ./internal/app`
- `go tool mygo vet ./internal/app` — MyGo-specific vet (stored build values, goroutine captures); takes a package dir, not `./...`

## Architecture

- **Layout**: `main.go` only opens the window (stays at root — `mygo dev/build` build the project dir). `internal/todo` is plain domain logic with no `ui` import, unit-tested directly. `internal/app` is the native UI (`App` state + `View`, split by area: `sidebar.go`, `todos.go`). Future Jira/ADO HTTP clients belong in their own `internal/<name>` package, injected into `App`, never called from views directly.
- **Immediate-mode views**: `App.View(c *ui.Context)` rebuilds the whole UI from `app` state on every frame (possibly several passes per frame). State lives only in the `app` struct; widgets bind to pointers into it (`ui.Checkbox(c, &a.todos[i].done, ...)`, `ui.TextInput(c, &a.draft)`).
- **macOS layout**: window uses `TitleBarHiddenInset` + `VibrancySidebar`; the sidebar reserves `titleBarHeight` for the traffic lights, draws no background when `c.Vibrancy()` is true, and title rows call `.DragWindow()`. Mirrors `examples/vibrancy` in the MyGo module.
- **Mutating collections**: use `.OnClick(fn)` (deferred, runs after construction) when removing items from a slice the current pass is iterating.
- **Lists**: `ui.List` with `ListState.Key` set to the item ID so row state follows items, not indices.
- **Tests**: `ui.NewTester(view, w, h)` drives the view without a window (`Type`, `Click(label)`, `HasText`); `Tester.Image()` renders a PNG for visually checking layout.
- Config is `mygo.json` (native projects have no `mygo.config.ts`).

## MyGo maintenance

`.agents/skills/mygo-maintenance/SKILL.md` has the MyGo-specific rules. Key points:

- Check APIs against the pinned source (`go list -m -f '{{.Dir}}' github.com/egoist/mygo`; `ui/doc.go`, `docs/ui/*.md`, `examples/`) or `go doc github.com/egoist/mygo/ui <Symbol>`, not memory — MyGo is `0.x` and changes between minors.
- Never store `ui.Element` or `*ui.Context` in app state or goroutines; use `ui.Handle` / `c.Key(...)` for persistent identity.
- Keep slow I/O (Jira/ADO HTTP calls) off the UI thread; publish results with `Window.Update`.
- For minor-version upgrades on `0.x`, read `docs/ui/migration.md` and use `go tool mygo migrate-ui .` (preview), then `-write`.
