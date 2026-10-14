// Package applog writes the app's diagnostic log to a file, so a packaged app's errors can be traced afterwards.
package applog

import (
	"fmt"
	"io"
	"log"
	"log/slog"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"
)

const (
	FileName = "jira-ado.log"
	maxSize  = 10 << 20 // rotated to .1 at launch past this; one previous file is kept
)

// Setup sends slog and the standard log package to dir/jira-ado.log (and stderr, for `mygo dev`).
// The log never contains secrets: callers log URLs, IDs and statuses, not request bodies or headers.
func Setup(dir string) (path string, closer io.Closer, err error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", nil, err
	}
	path = filepath.Join(dir, FileName)
	if fi, err := os.Stat(path); err == nil && fi.Size() > maxSize {
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return "", nil, err
	}
	w := &lockedWriter{w: io.MultiWriter(f, os.Stderr)}
	slog.SetDefault(slog.New(slog.NewTextHandler(w, &slog.HandlerOptions{Level: slog.LevelInfo})))
	log.SetOutput(w)
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	return path, f, nil
}

type lockedWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}

// Recovered logs a recovered panic with its stack and returns it as an error for the UI.
func Recovered(where string, p any, attrs ...any) error {
	slog.Error("panic", append([]any{"where", where, "panic", fmt.Sprint(p), "stack", string(debug.Stack())}, attrs...)...)
	return fmt.Errorf("internal error in %s: %v (stack trace in %s)", where, p, FileName)
}
