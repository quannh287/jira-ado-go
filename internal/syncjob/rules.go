package syncjob

import (
	"maps"
	"strings"
)

// Rules turn Jira values into ADO values. Keys match case-insensitively; the zero Rules means the defaults.
type Rules struct {
	Types       map[string]string // Jira issue type → ADO work item type
	SubtaskType string            // ADO type for Jira sub-tasks
	DefaultType string            // ADO type for any other issue type
	States      map[string]string // Jira status → ADO state, for backlog items (PBI, Bug…)
	TaskStates  map[string]string // Jira status → ADO state, for Tasks
	Priorities  map[string]string // Jira priority → ADO priority (1–4)
}

const (
	TypePBI  = "Product Backlog Item"
	TypeTask = "Task"
)

// DefaultRules are the source app's hardcoded mappings.
func DefaultRules() Rules {
	return Rules{
		Types:       map[string]string{},
		SubtaskType: TypeTask,
		DefaultType: TypePBI,
		States:      map[string]string{"To Do": "New", "In Progress": "In Progress", "In Review": "Verify Test", "Done": "Done"},
		TaskStates:  map[string]string{"To Do": "To Do", "In Progress": "In Progress", "In Review": "Verify Test", "Done": "Done"},
		Priorities:  map[string]string{"Highest": "1", "High": "2", "Medium": "3", "Low": "4", "Lowest": "4"},
	}
}

// OrDefault fills what r leaves empty with DefaultRules, so an old or partial config still syncs.
func (r Rules) OrDefault() Rules {
	d := DefaultRules()
	if r.Types != nil {
		d.Types = maps.Clone(r.Types)
	}
	if r.SubtaskType != "" {
		d.SubtaskType = r.SubtaskType
	}
	if r.DefaultType != "" {
		d.DefaultType = r.DefaultType
	}
	if len(r.States) > 0 {
		d.States = maps.Clone(r.States)
	}
	if len(r.TaskStates) > 0 {
		d.TaskStates = maps.Clone(r.TaskStates)
	}
	if len(r.Priorities) > 0 {
		d.Priorities = maps.Clone(r.Priorities)
	}
	return d
}

// Lookup finds key in m ignoring case and surrounding spaces.
func Lookup(m map[string]string, key string) (string, bool) {
	key = strings.TrimSpace(key)
	if v, ok := m[key]; ok {
		return v, true
	}
	for k, v := range m {
		if strings.EqualFold(strings.TrimSpace(k), key) {
			return v, true
		}
	}
	return "", false
}

// WorkItemType is the ADO type for a Jira issue type.
func (r Rules) WorkItemType(issueType string, subtask bool) string {
	if t, ok := Lookup(r.Types, issueType); ok && t != "" {
		return t
	}
	if subtask {
		return r.SubtaskType
	}
	return r.DefaultType
}

// IsTask reports whether an ADO type gets Task fields (estimates, no target date) and Task states.
func IsTask(adoType string) bool { return strings.EqualFold(adoType, TypeTask) }

// InitialState is the state ADO lets a work item be created in.
func InitialState(adoType string) string {
	if IsTask(adoType) {
		return "To Do"
	}
	return "New"
}

// State maps a Jira status for an ADO type, falling back to the type's initial state.
func (r Rules) State(adoType, jiraStatus string) string {
	m := r.States
	if IsTask(adoType) {
		m = r.TaskStates
	}
	if s, ok := Lookup(m, jiraStatus); ok && s != "" {
		return s
	}
	return InitialState(adoType)
}

// Priority maps a Jira priority, "4" when unknown, as the source did.
func (r Rules) Priority(jira string) string {
	if p, ok := Lookup(r.Priorities, jira); ok && p != "" {
		return p
	}
	return "4"
}
