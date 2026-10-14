package syncer

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"

	"jira-ado/internal/ado"
	"jira-ado/internal/jira"
	"jira-ado/internal/syncjob"
)

var (
	priorities = map[string]string{"Highest": "1", "High": "2", "Medium": "3", "Low": "4", "Lowest": "4"}
	statesPBI  = map[string]string{"To Do": "New", "In Progress": "In Progress", "In Review": "Verify Test", "Done": "Done"}
	statesTask = map[string]string{"To Do": "To Do", "In Progress": "In Progress", "In Review": "Verify Test", "Done": "Done"}
	// ADO is the source of truth for these once filled: the sync keeps them and comments the difference.
	preserved = []string{syncjob.FieldOriginalEstimate, syncjob.FieldCompletedWork, "Microsoft.VSTS.Scheduling.DueDate", syncjob.FieldTargetDate}
)

// fields is one issue's values, already transformed for ADO.
type fields struct {
	wiType, title, description, start, target, priority, state, area, iteration, key, createdBy, assignedTo string
	originalEstimate, remaining, completed                                                                  float64 // hours, 0 = none
	parentID                                                                                                int
}

// process syncs one issue and reports what happened; it never returns an error, a failure is a Failed ticket.
func (r *run) process(ctx context.Context, is jira.Issue) (t syncjob.Ticket) {
	t = syncjob.Ticket{Key: is.Key}
	r.calls = &t.Calls
	defer func() { r.calls = nil }()
	fail := func(err error) syncjob.Ticket {
		t.Outcome, t.Error = syncjob.Failed, err.Error()
		return t
	}

	details, err := r.jira.Search(ctx, r.detailJQL(is.ID), jira.AllFields)
	if err != nil {
		return fail(err)
	}
	if len(details) == 0 {
		t.Outcome, t.Message = syncjob.Skipped, "No detail returned from Jira"
		return t
	}
	d := details[0]
	t.Key, t.Summary = d.Key, d.Fields.Summary
	f := r.fieldsOf(d)
	t.WorkItemType = f.wiType

	if fl := r.job.Filters; fl.UserFilter {
		pass := f.assignedTo != ""
		if names := fl.AssigneeList(); len(names) > 0 {
			pass = matchesAny(d.Fields.Assignee, names)
		}
		if !pass {
			t.Outcome, t.Message = syncjob.Skipped, "Skipped by user filter (assignee not in scope)"
			return t
		}
	}

	existing, err := r.ado.FindByField(ctx, r.conn.JiraKeyField, f.key)
	if err != nil {
		return fail(err)
	}
	if p := d.Fields.Parent; p != nil && p.Key != "" {
		if f.parentID, err = r.ado.FindByField(ctx, r.conn.JiraKeyField, p.Key+" - "+p.ID); err != nil {
			return fail(err)
		}
	}

	if existing != 0 {
		t.ADOID = existing
		skipped, err := r.update(ctx, existing, f, d)
		if err != nil {
			return fail(err)
		}
		if skipped {
			t.Outcome, t.Message = syncjob.Skipped, fmt.Sprintf("ADO #%d is Done - skipped update, commented instead", existing)
			return t
		}
		t.Outcome, t.Message = syncjob.Updated, fmt.Sprintf("Updated ADO %s #%d", f.wiType, existing)
	} else {
		id, err := r.create(ctx, f)
		if err != nil {
			return fail(err)
		}
		t.ADOID = id
		t.Outcome, t.Message = syncjob.Created, fmt.Sprintf("Created ADO %s #%d", f.wiType, id)
	}

	// Attachment and comment failures don't fail the ticket, as in the source; they show up as warnings.
	var warnings []string
	warnings = append(warnings, r.syncAttachments(ctx, t.ADOID, d.Fields.Attachment)...)
	if r.job.Filters.SyncComments {
		warnings = append(warnings, r.syncComments(ctx, d.Key, t.ADOID)...)
	}
	if len(warnings) > 0 {
		t.Message += " · " + strings.Join(warnings, "; ")
	}
	return t
}

func (r *run) detailJQL(id string) string {
	parts := []string{"id = " + id, "project = " + jqlQuote(r.job.JiraKey)}
	if r.conn.JQLExtra != "" {
		parts = append(parts, "("+r.conn.JQLExtra+")")
	}
	return strings.Join(parts, " AND ")
}

func (r *run) fieldsOf(d jira.Issue) fields {
	jf := d.Fields
	f := fields{wiType: typePBI, title: jf.Summary, description: adfToHTML(jf.Description), start: jf.Created, target: jf.DueDate,
		priority: "4", key: d.Key + " - " + d.ID}
	if it := jf.IssueType; it != nil && (strings.EqualFold(it.Name, "subtask") || strings.EqualFold(it.Name, "sub-task")) {
		f.wiType = typeTask
	}
	if jf.Priority != nil {
		f.priority = cmpOr(priorities[jf.Priority.Name], "4")
	}
	status := ""
	if jf.Status != nil {
		status = jf.Status.Name
	}
	if f.wiType == typePBI {
		f.state = cmpOr(statesPBI[status], "New")
	} else {
		f.state = cmpOr(statesTask[status], "To Do")
		f.originalEstimate, f.remaining, f.completed = hours(jf.AggregateTimeOriginalEstimate), hours(jf.AggregateTimeEstimate), hours(jf.AggregateTimeSpent)
	}
	f.area, f.iteration = r.job.Paths(r.e.Now())
	f.assignedTo = resolveEmail(jf.Assignee, r.job.Filters.Users)
	f.createdBy = resolveEmail(jf.Reporter, r.job.Filters.Users)
	return f
}

// ops builds the JSON patch: empty values are dropped and only mapped fields are written.
func (r *run) ops(f fields) []ado.Op {
	type kv struct {
		field string
		value any
	}
	all := []kv{
		{syncjob.FieldTitle, f.key + " - " + f.title},
		{syncjob.FieldDescription, f.description},
		{syncjob.FieldStartDate, f.start},
		{syncjob.FieldPriority, f.priority},
		{syncjob.FieldState, f.state},
		{"System.AreaPath", f.area},
		{"System.IterationPath", f.iteration},
		{r.conn.JiraKeyField, f.key},
		{syncjob.FieldCreatedBy, f.createdBy},
		{syncjob.FieldAssignedTo, f.assignedTo},
	}
	if f.wiType == typePBI {
		all = append(all, kv{syncjob.FieldTargetDate, f.target})
	} else { // Tasks get no due date, as in the source
		all = append(all, kv{syncjob.FieldOriginalEstimate, f.originalEstimate}, kv{syncjob.FieldRemainingWork, f.remaining}, kv{syncjob.FieldCompletedWork, f.completed})
	}
	always := map[string]bool{"System.AreaPath": true, "System.IterationPath": true, r.conn.JiraKeyField: true}
	var ops []ado.Op
	for _, x := range all {
		if isEmpty(x.value) || (!always[x.field] && !r.job.Writes(x.field)) {
			continue
		}
		ops = append(ops, ado.Op{Op: "add", Path: "/fields/" + x.field, Value: x.value})
	}
	if f.parentID != 0 {
		ops = append(ops, r.ado.ParentRelation(f.parentID))
	}
	return ops
}

// create makes the work item in its first state, then moves it: ADO refuses to create one directly in a later state.
func (r *run) create(ctx context.Context, f fields) (int, error) {
	initial := f
	initial.state = initialState(f.wiType)
	id, err := r.ado.Create(ctx, f.wiType, r.ops(initial))
	if err != nil {
		return 0, err
	}
	if f.state != initial.state && r.job.Writes(syncjob.FieldState) {
		if err := r.ado.Update(ctx, id, r.ops(f)); err != nil {
			return id, err
		}
	}
	return id, nil
}

// update reports skipped=true when ADO has the item Done: ADO wins, the change is only commented.
func (r *run) update(ctx context.Context, id int, f fields, d jira.Issue) (skipped bool, err error) {
	cur, err := r.ado.Fields(ctx, id, append([]string{syncjob.FieldTitle, syncjob.FieldState, "System.IterationPath"}, preserved...))
	if err != nil {
		return false, err
	}
	state, _ := cur[syncjob.FieldState].(string)
	if state == "Done" {
		_, err := r.ado.AddComment(ctx, id, fmt.Sprintf(
			"<p>Jira <b>%s</b> vừa được cập nhật nhưng work item này đang ở trạng thái <b>Done</b> nên sync đã bỏ qua, không ghi đè. Vui lòng kiểm tra và cập nhật thủ công nếu cần.</p>",
			escape(f.key)))
		return true, err
	}
	// Removed can only go back to the first state; jumping straight to a later one is a 400.
	if state == "Removed" && f.state != "Removed" {
		if err := r.ado.Update(ctx, id, []ado.Op{{Op: "add", Path: "/fields/" + syncjob.FieldState, Value: initialState(f.wiType)}}); err != nil {
			return false, err
		}
	}

	var conflicts []string
	keep := func(field string, jiraValue any) bool {
		adoValue, ok := cur[field]
		if !ok || isEmpty(adoValue) {
			return false
		}
		if !isEmpty(jiraValue) && !sameValue(adoValue, jiraValue) {
			conflicts = append(conflicts, fmt.Sprintf("%s: ADO <b>%s</b> — Jira <b>%s</b>",
				field[strings.LastIndex(field, ".")+1:], escape(fmt.Sprint(adoValue)), escape(fmt.Sprint(jiraValue))))
		}
		return true
	}
	if keep(syncjob.FieldTargetDate, f.target) {
		f.target = ""
	}
	jf := d.Fields
	if keep(syncjob.FieldOriginalEstimate, hours(jf.AggregateTimeOriginalEstimate)) {
		f.originalEstimate = 0
	}
	if keep(syncjob.FieldCompletedWork, hours(jf.AggregateTimeSpent)) {
		f.completed = 0
	}

	if err := r.ado.Update(ctx, id, r.ops(f)); err != nil {
		return false, err
	}
	if len(conflicts) > 0 {
		html := fmt.Sprintf("<p>Sync từ Jira <b>%s</b> không ghi đè các field đã có giá trị trên ADO:</p><ul><li>%s</li></ul>",
			escape(f.key), strings.Join(conflicts, "</li><li>"))
		if _, err := r.ado.AddComment(ctx, id, html); err != nil {
			return false, err
		}
	}
	return false, nil
}

// syncAttachments replaces every ADO attachment with Jira's.
// ponytail: re-uploads all files on every update like the source; diff by name+size if uploads get slow
func (r *run) syncAttachments(ctx context.Context, id int, atts []jira.Attachment) []string {
	var warnings []string
	if err := r.ado.RemoveAttachments(ctx, id); err != nil {
		warnings = append(warnings, "remove attachments: "+err.Error())
	}
	for _, a := range atts {
		data, err := r.jira.Download(ctx, a.Content)
		if err == nil {
			err = r.ado.Attach(ctx, id, a.Filename, data)
		}
		if err != nil {
			warnings = append(warnings, "attach "+a.Filename+": "+err.Error())
		}
	}
	return warnings
}

// syncComments copies new Jira comments and patches edited ones in place; comments deleted in Jira are left alone.
func (r *run) syncComments(ctx context.Context, key string, id int) []string {
	comments, err := r.jira.Comments(ctx, key)
	if err != nil {
		return []string{"comments: " + err.Error()}
	}
	if len(comments) == 0 {
		return nil
	}
	state := r.e.State
	mapped, err := state.CommentMappings(ctx, id)
	if err != nil {
		return []string{"comment mappings: " + err.Error()}
	}
	var warnings []string
	for _, c := range comments {
		m, ok := mapped[c.ID]
		switch {
		case !ok:
			cid, err := r.ado.AddComment(ctx, id, renderComment(c, false))
			if err == nil {
				err = state.SaveCommentMapping(ctx, syncjob.CommentMapping{WorkItemID: id, JiraCommentID: c.ID, ADOCommentID: cid, JiraUpdated: c.Updated})
			}
			if err != nil {
				warnings = append(warnings, "comment "+c.ID+": "+err.Error())
			}
		case c.Updated != "" && c.Updated != m.JiraUpdated:
			err := r.ado.UpdateComment(ctx, id, m.ADOCommentID, renderComment(c, true))
			if err == nil {
				m.JiraUpdated = c.Updated
				err = state.SaveCommentMapping(ctx, m)
			}
			if err != nil {
				warnings = append(warnings, "comment "+c.ID+": "+err.Error())
			}
		}
	}
	return warnings
}

// renderComment prefixes the Jira author, since the ADO comment is posted as the PAT's user.
func renderComment(c jira.Comment, edited bool) string {
	author := "Unknown"
	if c.Author != nil && c.Author.DisplayName != "" {
		author = c.Author.DisplayName
	}
	marker := ""
	if edited {
		marker = " <em>(edited)</em>"
	}
	return fmt.Sprintf("<div><p><strong>[%s]:</strong>%s</p>%s</div>", escape(author), marker, adfToHTML(c.Body))
}

func initialState(wiType string) string {
	if wiType == typePBI {
		return "New"
	}
	return "To Do"
}

// resolveEmail maps a Jira user (email or display name, case-insensitive) to its ADO email, or "".
func resolveEmail(u *jira.User, users []syncjob.UserPair) string {
	for _, m := range users {
		if matches(u, m.Jira) {
			return m.ADOEmail
		}
	}
	return ""
}

func matches(u *jira.User, needle string) bool {
	n := strings.ToLower(strings.TrimSpace(needle))
	return u != nil && n != "" && (strings.ToLower(strings.TrimSpace(u.EmailAddress)) == n || strings.ToLower(strings.TrimSpace(u.DisplayName)) == n)
}

func matchesAny(u *jira.User, names []string) bool {
	for _, n := range names {
		if matches(u, n) {
			return true
		}
	}
	return false
}

// hours turns Jira seconds into ADO hours with 2 decimals; 0 for none.
func hours(seconds float64) float64 {
	if seconds <= 0 || math.IsNaN(seconds) || math.IsInf(seconds, 0) {
		return 0
	}
	return math.Round(seconds/3600*100) / 100
}

func isEmpty(v any) bool {
	switch x := v.(type) {
	case nil:
		return true
	case string:
		return x == ""
	case float64:
		return x == 0
	}
	return false
}

// sameValue compares numbers numerically and anything else by its date part, since ADO returns full ISO dates.
func sameValue(adoValue, jiraValue any) bool {
	an, aNum := adoValue.(float64)
	jn, jNum := jiraValue.(float64)
	if aNum || jNum {
		if !aNum {
			an, _ = toFloat(adoValue)
		}
		if !jNum {
			jn, _ = toFloat(jiraValue)
		}
		return an == jn
	}
	a, j := fmt.Sprint(adoValue), fmt.Sprint(jiraValue)
	return a[:min(10, len(a))] == j[:min(10, len(j))]
}

// toFloat is the source's Number(x) for the side that isn't already a number; NaN never equals anything.
func toFloat(v any) (float64, bool) {
	if s, ok := v.(string); ok {
		if f, err := strconv.ParseFloat(strings.TrimSpace(s), 64); err == nil {
			return f, true
		}
	}
	return math.NaN(), false
}
