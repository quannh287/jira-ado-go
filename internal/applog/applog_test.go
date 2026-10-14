package applog

import (
	"log"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSetupWritesAndRotates(t *testing.T) {
	dir := t.TempDir()
	big := filepath.Join(dir, FileName)
	os.WriteFile(big, make([]byte, maxSize+1), 0o600)

	path, closer, err := Setup(dir)
	if err != nil {
		t.Fatal(err)
	}
	slog.Info("sync done", "job", 2, "created", 1)
	log.Printf("legacy line")
	err = func() (err error) {
		defer func() { err = Recovered("test", recover(), "job", 2) }()
		panic("boom")
	}()
	closer.Close()

	if _, err := os.Stat(big + ".1"); err != nil {
		t.Fatal("oversized log not rotated")
	}
	data, _ := os.ReadFile(path)
	for _, want := range []string{`msg="sync done" job=2 created=1`, "legacy line", `panic=boom`, "applog_test.go"} {
		if !strings.Contains(string(data), want) {
			t.Errorf("log lacks %q:\n%s", want, data)
		}
	}
	if err == nil || !strings.Contains(err.Error(), FileName) {
		t.Fatalf("Recovered error %v", err)
	}
}
