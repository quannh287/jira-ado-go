package todo

import "testing"

func TestList(t *testing.T) {
	var l List
	if l.Add("   ") {
		t.Fatal("blank title was added")
	}
	l.Add("a")
	l.Add(" b ")
	l.Add("c")
	if l.Items[1].Title != "b" {
		t.Fatalf("title not trimmed: %q", l.Items[1].Title)
	}

	l.Items[0].Done = true
	if got := l.Count(Active); got != 2 {
		t.Fatalf("active = %d, want 2", got)
	}
	if got := l.Indices(Done); len(got) != 1 || got[0] != 0 {
		t.Fatalf("done indices = %v", got)
	}

	l.Remove(l.Items[1].ID)
	l.ClearDone()
	if len(l.Items) != 1 || l.Items[0].Title != "c" {
		t.Fatalf("items = %v", l.Items)
	}

	// IDs stay unique after removals.
	l.Add("d")
	if l.Items[0].ID == l.Items[1].ID {
		t.Fatalf("duplicate id %d", l.Items[0].ID)
	}
}
