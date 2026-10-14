package app

import (
	"testing"

	"github.com/egoist/mygo/ui"
)

func TestTodos(t *testing.T) {
	a := New()
	tt := ui.NewTester(a.View, 880, 600)

	tt.Type("Ship native UI") // the input has AutoFocus
	if err := tt.Click("Add"); err != nil {
		t.Fatal(err)
	}
	if len(a.todos.Items) != 4 || !tt.HasText("Ship native UI") || a.draft != "" {
		t.Fatalf("items %v, draft %q, texts %q", a.todos.Items, a.draft, tt.Texts())
	}

	if err := tt.Click("Ship native UI"); err != nil {
		t.Fatal(err)
	}
	if !a.todos.Items[3].Done || !tt.HasText("3 left") {
		t.Fatalf("toggle failed: %v, texts %q", a.todos.Items[3], tt.Texts())
	}

	if err := tt.Click("Completed"); err != nil {
		t.Fatal(err)
	}
	if tt.HasText("Review SE-485 bugs") || !tt.HasText("Ship native UI") {
		t.Fatalf("filter failed, texts %q", tt.Texts())
	}

	if err := tt.Click("Clear Completed"); err != nil {
		t.Fatal(err)
	}
	if len(a.todos.Items) != 3 || !tt.HasText("Nothing here") {
		t.Fatalf("clear failed: %v", a.todos.Items)
	}
}
