package syncjob

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"math/rand/v2"
	"slices"
	"time"
)

var ErrInvalidPAT = errors.New("ADO rejected the personal access token")

// Fake simulates Jira→ADO calls with generated tickets.
// ponytail: demo engine for JIRA_ADO_DEMO and UI tests; internal/syncer is the real one
type Fake struct {
	Delay time.Duration
	Now   func() time.Time
	rnd   *rand.Rand
}

func NewFake(delay time.Duration, now func() time.Time) *Fake {
	return &Fake{Delay: delay, Now: now, rnd: rand.New(rand.NewPCG(1, 2))}
}

func (f *Fake) ValidatePAT(ctx context.Context, org, pat string) (string, error) {
	if err := f.wait(ctx); err != nil {
		return "", err
	}
	if len(pat) < 20 {
		return "", ErrInvalidPAT
	}
	return "Demo User", nil
}

func (f *Fake) CheckJira(ctx context.Context, conn Connection) (string, error) {
	if conn.JiraToken == "" {
		return "", errors.New("Jira API token is empty")
	}
	return "Demo Jira User", f.wait(ctx)
}

func (f *Fake) Check(context.Context, Connection, Job) ([]string, error) { return nil, nil }

func (f *Fake) Sync(ctx context.Context, _ Connection, j Job, opts RunOptions) Run {
	onProgress := opts.OnProgress
	start := f.Now()
	run := Run{JobID: j.ID, Started: start}
	switch {
	case opts.DryRun:
		run.Kind = KindDryRun
	case len(opts.Keys) > 0:
		run.Kind = KindRetry
	}
	area, iteration := j.Paths(start)
	n := 3 + f.rnd.IntN(6)
	if len(opts.Keys) > 0 {
		n = len(opts.Keys)
	}
	report := func() {
		if onProgress != nil {
			onProgress(Progress{Run: run.Snapshot(), Done: len(run.Tickets), Total: n})
		}
	}
	report()
	for i := range n {
		if err := f.waitFor(ctx, f.Delay/time.Duration(n)); err != nil {
			run.Error = err.Error()
			break
		}
		t := f.ticket(j, i+1, area, iteration)
		if len(opts.Keys) > 0 {
			t.Key = opts.Keys[i]
		}
		run.Tickets = append(run.Tickets, t)
		report()
	}
	run.Duration = f.Now().Sub(start)
	return run
}

var summaries = []string{
	"Login button unresponsive on Android", "Crash when opening notifications", "Update onboarding copy",
	"Sprint report export is empty", "Add dark mode to settings", "Timeout calling payments API",
	"Profile photo upload fails", "Improve search ranking",
}

func (f *Fake) ticket(j Job, n int, area, iteration string) Ticket {
	t := Ticket{Key: fmt.Sprintf("%s-%d", j.JiraKey, 100+f.rnd.IntN(900)), Summary: summaries[f.rnd.IntN(len(summaries))]}
	fields := map[string]string{"System.AreaPath": area, "System.IterationPath": iteration}
	for _, m := range j.Mappings {
		fields[m.ADO] = fmt.Sprintf("%s of %s", m.Jira, t.Key)
	}
	fields["System.Title"] = t.Summary
	body, _ := json.MarshalIndent(patchOps(fields), "", "  ")
	base := fmt.Sprintf("https://dev.azure.com/org/%s/_apis/wit/workitems", j.ADOProject)

	switch p := f.rnd.IntN(10); {
	case p < 4:
		t.Outcome = Created
		t.Calls = []APICall{{Method: "POST", URL: base + "/$Bug?api-version=7.1", Request: string(body), Status: 200,
			Response: fmt.Sprintf(`{"id": %d, "rev": 1}`, 4000+n)}}
	case p < 7:
		t.Outcome = Updated
		t.Calls = []APICall{{Method: "PATCH", URL: fmt.Sprintf("%s/%d?api-version=7.1", base, 3000+n), Request: string(body), Status: 200,
			Response: fmt.Sprintf(`{"id": %d, "rev": 7}`, 3000+n)}}
	case p < 9:
		t.Outcome = Skipped
		t.Message = "Skipped by user filter (assignee not in scope)"
	default:
		t.Outcome = Failed
		t.Error = "TF401320: Rule Error for field Assigned To. Error code: Required, HasValues, InvalidListValue."
		t.Calls = []APICall{{Method: "POST", URL: base + "/$Bug?api-version=7.1", Request: string(body), Status: 400,
			Response: `{"message": "TF401320: Rule Error for field Assigned To.", "typeKey": "RuleValidationException"}`}}
	}
	return t
}

func patchOps(fields map[string]string) []map[string]string {
	ops := make([]map[string]string, 0, len(fields))
	for _, k := range slices.Sorted(maps.Keys(fields)) {
		ops = append(ops, map[string]string{"op": "add", "path": "/fields/" + k, "value": fields[k]})
	}
	return ops
}

func (f *Fake) wait(ctx context.Context) error { return f.waitFor(ctx, f.Delay) }

func (f *Fake) waitFor(ctx context.Context, d time.Duration) error {
	if d == 0 {
		return nil
	}
	select {
	case <-time.After(d):
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
