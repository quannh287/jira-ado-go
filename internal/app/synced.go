package app

import (
	"encoding/json"
	"fmt"
	"html"
	"regexp"
	"strings"

	"jira-ado/internal/syncjob"
)

// syncedField is one ADO field a ticket's run wrote, with its final value.
type syncedField struct{ name, value string }

// synced reads a ticket's ADO calls back into what changed: fields written (last write wins) and side effects.
func synced(calls []syncjob.APICall) (fields []syncedField, notes []string) {
	index := map[string]int{}
	var comments, edited, attached int
	parent := false
	for _, c := range calls {
		if c.Status >= 400 || c.Error != "" {
			continue // a failed write changed nothing
		}
		switch {
		case strings.Contains(c.URL, "/comments"):
			if c.Method == "POST" {
				comments++
			} else if c.Method == "PATCH" {
				edited++
			}
			continue
		case strings.Contains(c.URL, "/attachments"):
			continue // counted by the relation that links it
		case c.Method != "POST" && c.Method != "PATCH":
			continue
		}
		var ops []struct {
			Op    string `json:"op"`
			Path  string `json:"path"`
			Value any    `json:"value"`
		}
		if json.Unmarshal([]byte(c.Request), &ops) != nil {
			continue
		}
		for _, op := range ops {
			if field, ok := strings.CutPrefix(op.Path, "/fields/"); ok {
				v := oneLine(op.Value)
				if i, seen := index[field]; seen {
					fields[i].value = v
				} else {
					index[field] = len(fields)
					fields = append(fields, syncedField{field, v})
				}
				continue
			}
			if rel, ok := op.Value.(map[string]any); ok && op.Path == "/relations/-" {
				switch rel["rel"] {
				case "AttachedFile":
					attached++
				case "System.LinkTypes.Hierarchy-Reverse":
					parent = true
				}
			}
		}
	}
	for i := range fields {
		fields[i].name = fields[i].name[strings.LastIndex(fields[i].name, ".")+1:]
	}
	if parent {
		notes = append(notes, "Linked to parent")
	}
	if attached > 0 {
		notes = append(notes, plural(attached, "attachment")+" uploaded")
	}
	if comments > 0 {
		notes = append(notes, plural(comments, "comment")+" added")
	}
	if edited > 0 {
		notes = append(notes, plural(edited, "comment")+" updated")
	}
	return fields, notes
}

var tags = regexp.MustCompile(`<[^>]*>`)

// oneLine turns a field value (HTML descriptions included) into a short single line for the summary.
func oneLine(v any) string {
	s := strings.Join(strings.Fields(html.UnescapeString(tags.ReplaceAllString(fmt.Sprint(v), " "))), " ")
	if r := []rune(s); len(r) > 90 {
		return string(r[:90]) + "…"
	}
	return s
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return fmt.Sprintf("%d %ss", n, word)
}

// shortURL drops the host and api-version, leaving what was called.
func shortURL(u string) string {
	if i := strings.Index(u, "/_apis/"); i >= 0 {
		u = u[i+len("/_apis"):]
	}
	if i := strings.Index(u, "api-version="); i >= 0 {
		u = strings.TrimRight(u[:i], "?&")
	}
	return u
}
