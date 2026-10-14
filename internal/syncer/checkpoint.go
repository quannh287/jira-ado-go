package syncer

import (
	"sort"
	"time"

	"jira-ado/internal/jira"
)

// checkpoint is a watermark: it passes time T only once every issue updated at or before T is done.
// Issues run parents-first, not updated-ascending, so the last finished issue's time could skip older sub-tasks.
type checkpoint struct {
	byUpdated []jira.Issue
	pending   map[string]bool
	mark      int
	last      string
}

func newCheckpoint(issues []jira.Issue) *checkpoint {
	c := &checkpoint{byUpdated: append([]jira.Issue(nil), issues...), pending: map[string]bool{}}
	sort.SliceStable(c.byUpdated, func(i, j int) bool {
		return parseJiraTime(c.byUpdated[i].Fields.Updated).Before(parseJiraTime(c.byUpdated[j].Fields.Updated))
	})
	for _, i := range issues {
		c.pending[i.ID] = true
	}
	return c
}

// advance marks id done and returns a cursor that is safe to save, or "" when the watermark didn't move.
func (c *checkpoint) advance(id string) string {
	delete(c.pending, id)
	for c.mark < len(c.byUpdated) && !c.pending[c.byUpdated[c.mark].ID] {
		c.mark++
	}
	if c.mark == 0 {
		return ""
	}
	iso := c.byUpdated[c.mark-1].Fields.Updated
	if iso == "" || iso == c.last {
		return ""
	}
	c.last = iso
	return iso
}

// parseJiraTime reads Jira's "2006-01-02T15:04:05.000-0700" and RFC 3339 cursors; zero on failure.
func parseJiraTime(s string) time.Time {
	for _, layout := range []string{"2006-01-02T15:04:05.000-0700", time.RFC3339Nano} {
		if t, err := time.Parse(layout, s); err == nil {
			return t
		}
	}
	return time.Time{}
}
