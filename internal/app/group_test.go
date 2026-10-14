package app

import (
	"testing"

	"jira-ado/internal/syncjob"
)

func TestGroupTickets(t *testing.T) {
	tk := func(key, parent string) syncjob.Ticket { return syncjob.Ticket{Key: key, ParentKey: parent} }
	tickets := []syncjob.Ticket{
		tk("CAT-341", "CAT-284"), // sub-task listed before its parent
		tk("CAT-284", ""),
		tk("CAT-342", "CAT-284"),
		tk("CAT-400", ""),
		tk("CAT-501", "CAT-500"), // parent not in the run
		tk("CAT-502", "CAT-500"),
	}
	g := groupTickets(tickets)
	if len(g) != 3 {
		t.Fatalf("groups %+v", g)
	}
	if g[0].parent != 1 || len(g[0].children) != 2 || g[0].children[0] != 0 || g[0].children[1] != 2 {
		t.Errorf("CAT-284 group %+v", g[0])
	}
	if g[1].parent != 3 || len(g[1].children) != 0 {
		t.Errorf("CAT-400 group %+v", g[1])
	}
	if g[2].parent != -1 || g[2].parentKey != "CAT-500" || len(g[2].children) != 2 {
		t.Errorf("orphan group %+v", g[2])
	}
	// Every ticket shows exactly once.
	seen := map[int]bool{}
	for _, x := range g {
		if x.parent >= 0 {
			seen[x.parent] = true
		}
		for _, c := range x.children {
			seen[c] = true
		}
	}
	if len(seen) != len(tickets) {
		t.Fatalf("shown %d of %d tickets", len(seen), len(tickets))
	}
}
