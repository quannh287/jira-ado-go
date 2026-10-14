// Package todo holds the todo list's data and rules, independent of the UI.
package todo

import "strings"

type Filter string

const (
	All    Filter = "all"
	Active Filter = "active"
	Done   Filter = "done"
)

type Item struct {
	ID    int
	Title string
	Done  bool
}

func (f Filter) Matches(it Item) bool {
	switch f {
	case Active:
		return !it.Done
	case Done:
		return it.Done
	}
	return true
}

// ponytail: in-memory only, persist to a JSON file under the app data dir when needed
type List struct {
	Items  []Item
	nextID int
}

// Add appends a todo and reports whether title was non-blank.
func (l *List) Add(title string) bool {
	title = strings.TrimSpace(title)
	if title == "" {
		return false
	}
	l.nextID++
	l.Items = append(l.Items, Item{ID: l.nextID, Title: title})
	return true
}

func (l *List) Remove(id int) {
	for i, it := range l.Items {
		if it.ID == id {
			l.Items = append(l.Items[:i], l.Items[i+1:]...)
			return
		}
	}
}

func (l *List) ClearDone() {
	kept := l.Items[:0]
	for _, it := range l.Items {
		if !it.Done {
			kept = append(kept, it)
		}
	}
	l.Items = kept
}

func (l *List) Count(f Filter) int {
	n := 0
	for _, it := range l.Items {
		if f.Matches(it) {
			n++
		}
	}
	return n
}

// Indices returns positions in Items matching f, so callers can bind to the real items.
func (l *List) Indices(f Filter) []int {
	var idx []int
	for i, it := range l.Items {
		if f.Matches(it) {
			idx = append(idx, i)
		}
	}
	return idx
}
