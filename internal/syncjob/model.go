// Package syncjob holds Jira→ADO sync jobs, their runs and the engine that executes them, independent of the UI.
package syncjob

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"strings"
	"time"
)

type Status string

const (
	Active Status = "ACTIVE"
	Paused Status = "PAUSED"
)

type SyncType string

const (
	Manual    SyncType = "Manual"
	Scheduler SyncType = "Scheduler"
	Webhook   SyncType = "Webhook"
)

var SyncTypes = []SyncType{Manual, Scheduler, Webhook}

type FieldPair struct{ Jira, ADO string }

type UserPair struct{ Jira, ADOEmail string }

// Filters mirrors the source app's syncComments, userFilter, userMappings and adoConfig.
type Filters struct {
	SyncComments bool
	// UserFilter on: Assignees non-empty → assignee must match one; empty → assignee must resolve through Users.
	UserFilter bool
	Assignees  string // comma-separated Jira users (email or display name)
	Users      []UserPair
	AreaPath   string
	// AutoPaths follows the Jira sprint: issues in an active Jira sprint go to the current ADO sprint
	// SprintRoot\Sprint N (N = AnchorSprint + full weeks since AnchorDate), all others to the backlog SprintRoot.
	// Off, every issue goes to the fixed Iteration.
	AutoPaths    bool
	Iteration    string
	SprintRoot   string
	AnchorSprint int
	AnchorDate   string // yyyy-mm-dd, UTC start of AnchorSprint
}

// Defaults of the source app (domain/entities/SyncJob.ts DEFAULT_ADO_CONFIG).
const (
	DefaultAreaPath     = `Tickets\KPL\KAI` // what the real jobs use; the source's default no longer exists in ADO
	DefaultSprintRoot   = `Tickets\Weekly Sprint`
	DefaultAnchorSprint = 63
	DefaultAnchorDate   = "2026-06-01"
)

func DefaultFilters() Filters {
	return Filters{SyncComments: true, UserFilter: true, AreaPath: DefaultAreaPath, AutoPaths: true,
		SprintRoot: DefaultSprintRoot, AnchorSprint: DefaultAnchorSprint, AnchorDate: DefaultAnchorDate}
}

// AssigneeList splits Assignees into trimmed, non-empty names.
func (f Filters) AssigneeList() []string {
	var out []string
	for _, s := range strings.Split(f.Assignees, ",") {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}

type Activity struct {
	At   time.Time
	Text string
}

type Job struct {
	ID         int
	Name       string
	JiraKey    string
	ADOProject string
	Type       SyncType
	Status     Status
	Mappings   []FieldPair
	Filters    Filters
	Created    time.Time
	Activity   []Activity
}

// BacklogPath is where issues outside an active Jira sprint go when AutoPaths is on.
func (j Job) BacklogPath() string { return cmp.Or(j.Filters.SprintRoot, DefaultSprintRoot) }

// Paths returns the area path and the iteration of an issue in an active Jira sprint, for a run at t.
func (j Job) Paths(t time.Time) (area, iteration string) {
	f := j.Filters
	if !f.AutoPaths {
		return f.AreaPath, f.Iteration
	}
	root, anchor, date := cmp.Or(f.SprintRoot, DefaultSprintRoot), cmp.Or(f.AnchorSprint, DefaultAnchorSprint), cmp.Or(f.AnchorDate, DefaultAnchorDate)
	return f.AreaPath, fmt.Sprintf(`%s\Sprint %d`, root, SprintNumber(anchor, date, t))
}

// SprintNumber is anchor + whole weeks from anchorDate to t's UTC day; an unparsable date counts as no weeks.
func SprintNumber(anchor int, anchorDate string, t time.Time) int {
	start, err := time.Parse("2006-01-02", anchorDate)
	if err != nil {
		return anchor
	}
	day := time.Date(t.UTC().Year(), t.UTC().Month(), t.UTC().Day(), 0, 0, 0, 0, time.UTC)
	days := int(day.Sub(start).Hours() / 24)
	weeks := days / 7
	if days < 0 && days%7 != 0 {
		weeks-- // floor, as Math.floor does for dates before the anchor
	}
	return anchor + weeks
}

type Outcome string

const (
	Created Outcome = "created"
	Updated Outcome = "updated"
	Skipped Outcome = "skipped"
	Failed  Outcome = "failed"
)

var Outcomes = []Outcome{Created, Updated, Skipped, Failed}

type APICall struct {
	Method   string
	URL      string
	Request  string // JSON body sent to ADO
	Status   int
	Response string
	Retries  int
	Duration time.Duration
	Error    string
}

type Ticket struct {
	Key          string
	Summary      string
	ParentKey    string // the Jira parent of a sub-task, for grouping the report; "" for top-level issues
	Outcome      Outcome
	WorkItemType string
	ADOID        int
	Message      string // what happened, e.g. why it was skipped
	Error        string // set only when Outcome is Failed
	Calls        []APICall
}

type RunStatus string

const (
	Success RunStatus = "success"
	Partial RunStatus = "partial"
	Error   RunStatus = "failed"
)

var RunStatuses = []RunStatus{Success, Partial, Error}

// Run kinds besides a normal sync.
const (
	KindDryRun = "dry-run" // read everything, write nothing to ADO
	KindRetry  = "retry"   // only the given Jira keys, cursor untouched
)

type Run struct {
	ID       int
	JobID    int
	Started  time.Time
	Duration time.Duration
	Since    string // cursor the run started from; "" = full backlog
	Error    string // the run itself failed (auth, Jira search…)
	Kind     string // "", KindDryRun or KindRetry
	Tickets  []Ticket
}

// FailedKeys are the Jira keys of the run's failed tickets, for Retry failed.
func (r Run) FailedKeys() []string {
	var keys []string
	for _, t := range r.Tickets {
		if t.Outcome == Failed && t.Key != "" {
			keys = append(keys, t.Key)
		}
	}
	return keys
}

func (r Run) Count(o Outcome) int {
	n := 0
	for _, t := range r.Tickets {
		if t.Outcome == o {
			n++
		}
	}
	return n
}

// Status follows the source app: the run itself failing is failed, any failed ticket is partial.
func (r Run) Status() RunStatus {
	switch {
	case r.Error != "":
		return Error
	case r.Count(Failed) > 0:
		return Partial
	}
	return Success
}

// Connection is everything a sync needs to reach Jira and ADO; read from Settings and the keychain.
type Connection struct {
	ADOOrg, PAT                   string
	JiraURL, JiraEmail, JiraToken string
	JQLExtra                      string // ANDed into every search
	JiraKeyField                  string // ADO field holding "KEY - id", the link between both sides
	Rules                         Rules  // value mappings from the Mappings page
}

const DefaultJiraKeyField = "Custom.JiraID"

// Missing names the first setting a sync can't run without, or "".
func (c Connection) Missing() string {
	switch {
	case c.ADOOrg == "":
		return "ADO organization"
	case c.PAT == "":
		return "ADO PAT"
	case c.JiraURL == "":
		return "Jira URL"
	case c.JiraEmail == "":
		return "Jira email"
	case c.JiraToken == "":
		return "Jira API token"
	}
	return ""
}

// Engine is the boundary to Jira and ADO; the UI only talks to it.
type Engine interface {
	// ValidatePAT checks the PAT against the ADO organization and returns the user's display name.
	ValidatePAT(ctx context.Context, org, pat string) (string, error)
	// CheckJira checks the Jira credentials and returns the account's display name.
	CheckJira(ctx context.Context, conn Connection) (string, error)
	// Check lists what would make a sync of j fail before it writes anything (missing ADO paths, no Sprint field).
	Check(ctx context.Context, conn Connection, j Job) (problems []string, err error)
	Sync(ctx context.Context, conn Connection, j Job, opts RunOptions) Run
	// Catalog lists the values the Mappings page offers, for the given Jira and ADO projects.
	Catalog(ctx context.Context, conn Connection, jiraProjects, adoProjects []string) (Catalog, error)
}

// Catalog is what Jira and ADO accept as mapping values; empty lists mean "type it yourself".
type Catalog struct {
	JiraTypes, JiraStatuses, JiraPriorities []string
	ADOTypes                                []string
	ADOStates                               map[string][]string // per ADO work item type
}

// StatesFor merges the states of the given ADO types, in first-seen order.
func (c Catalog) StatesFor(types ...string) []string {
	var lists [][]string
	for _, t := range types {
		lists = append(lists, c.ADOStates[t])
	}
	return Union(lists...)
}

// Union merges lists without duplicates (case-insensitive), keeping first-seen order.
func Union(lists ...[]string) []string {
	seen := map[string]bool{}
	var out []string
	for _, l := range lists {
		for _, s := range l {
			if k := strings.ToLower(strings.TrimSpace(s)); k != "" && !seen[k] {
				seen[k] = true
				out = append(out, s)
			}
		}
	}
	return out
}

// RunOptions shape one Sync.
type RunOptions struct {
	// OnProgress gets a snapshot after detection and after every issue, on the worker goroutine.
	OnProgress func(Progress)
	DryRun     bool
	// Keys limits the run to these Jira issues (Retry failed); the cursor is neither read nor moved.
	Keys []string
}

// Progress is a snapshot of a run in flight.
type Progress struct {
	Run   Run // Tickets so far; ID is 0 until the run is saved
	Done  int
	Total int // issues detected; 0 while still searching Jira
}

// Snapshot copies r so a progress callback can hand it to another goroutine.
func (r Run) Snapshot() Run {
	r.Tickets = slices.Clone(r.Tickets)
	return r
}

// State is what a sync persists while it runs; implementations must be safe off the UI thread.
type State interface {
	Cursor(ctx context.Context, jobID int) (string, error) // "" = never synced
	SetCursor(ctx context.Context, jobID int, iso string) error
	CommentMappings(ctx context.Context, workItemID int) (map[string]CommentMapping, error)
	SaveCommentMapping(ctx context.Context, m CommentMapping) error
}

// CommentMapping links a Jira comment to the ADO comment it was copied to.
type CommentMapping struct {
	WorkItemID    int
	JiraCommentID string
	ADOCommentID  int
	JiraUpdated   string
}
