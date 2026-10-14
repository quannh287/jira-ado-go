package syncer

import (
	"context"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"

	"jira-ado/internal/ado"
	"jira-ado/internal/jira"
	"jira-ado/internal/syncjob"
)

// ADO is the source of truth for these once filled: the sync keeps them and comments the difference.
var preserved = []string{syncjob.FieldOriginalEstimate, syncjob.FieldCompletedWork, "Microsoft.VSTS.Scheduling.DueDate", syncjob.FieldTargetDate}

// fields is one issue's values, already transformed for ADO.
type fields struct {
	wiType, title, description, start, target, priority, state, area, iteration, key, createdBy, assignedTo string
	originalEstimate, remaining, completed                                                                  float64 // hours, 0 = none
	parentID                                                                                                int
}

// process syncs one issue and reports what happened; it never returns an error, a failure is a Failed ticket.
// details holds the batch-fetched issue; fetched says the batch answered, so a missing issue was filtered out by Jira.
func (r *run) process(ctx context.Context, is jira.Issue, details map[string]jira.Issue, fetched bool) (t syncjob.Ticket) {
	t = syncjob.Ticket{Key: is.Key}
	r.calls = &t.Calls
	defer func() { r.calls = nil }()
	fail := func(err error) syncjob.Ticket {
		t.Outcome, t.Error = syncjob.Failed, err.Error()
		return t
	}

	d, ok := details[is.ID]
	if !ok && !fetched { // the batch failed: one search for this issue alone
		got, err := r.jira.Search(ctx, r.scopedJQL("id = "+is.ID), jira.AllFields)
		if err != nil {
			return fail(err)
		}
		if ok = len(got) > 0; ok {
			d = got[0]
		}
	}
	if !ok {
		t.Outcome, t.Message = syncjob.Skipped, "No detail returned from Jira"
		return t
	}
	t.Key, t.Summary = d.Key, d.Fields.Summary
	if p := d.Fields.Parent; p != nil {
		t.ParentKey = p.Key
	}
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

	existing, err := r.findID(ctx, f.key)
	if err != nil {
		return fail(err)
	}
	if p := d.Fields.Parent; p != nil && p.Key != "" {
		if f.parentID, err = r.findID(ctx, p.Key+" - "+p.ID); err != nil {
			return fail(err)
		}
	}

	var rels []ado.Relation // the item's current links, read once by update; none for a new item
	wrote := true
	if existing != 0 {
		t.ADOID = existing
		res, err := r.update(ctx, existing, f, d)
		if err != nil {
			return fail(err)
		}
		rels = res.rels
		if res.done {
			t.Outcome, t.Message = syncjob.Skipped, fmt.Sprintf("ADO #%d is Done - skipped update, commented instead", existing)
			if r.firstRun {
				t.Message = fmt.Sprintf("ADO #%d is Done - skipped (first run imports the backlog, so no comment)", existing)
			}
			return t
		}
		wrote = res.wrote
		t.Outcome, t.Message = syncjob.Updated, fmt.Sprintf("Updated ADO %s #%d", f.wiType, existing)
		if r.dry {
			t.Message = fmt.Sprintf("Would update ADO %s #%d", f.wiType, existing)
		}
	} else {
		id, err := r.create(ctx, f)
		if err != nil {
			return fail(err)
		}
		r.ids[f.key] = id
		t.ADOID = id
		t.Outcome, t.Message = syncjob.Created, fmt.Sprintf("Created ADO %s #%d", f.wiType, id)
		if r.dry {
			t.ADOID, t.Message = 0, "Would create a new ADO "+f.wiType
		}
	}

	// Attachment and comment failures don't fail the ticket, as in the source; they show up as warnings.
	written, warnings := r.syncAttachments(ctx, t.ADOID, d.Fields.Attachment, rels, existing == 0)
	if r.job.Filters.SyncComments {
		n, w := r.syncComments(ctx, d.Key, t.ADOID)
		written, warnings = written+n, append(warnings, w...)
	}
	if !wrote && written == 0 {
		t.Outcome, t.Message = syncjob.Skipped, fmt.Sprintf("ADO #%d already up to date", existing)
	} else if !wrote {
		t.Message = fmt.Sprintf("ADO #%d fields already up to date; synced comments/attachments", existing)
	}
	if len(warnings) > 0 {
		t.Message += " · " + strings.Join(warnings, "; ")
	}
	return t
}

// findID resolves "KEY - id" to an ADO work item once per run; 0 when there is none yet.
func (r *run) findID(ctx context.Context, link string) (int, error) {
	if id, ok := r.ids[link]; ok {
		return id, nil
	}
	id, err := r.ado.FindByField(ctx, r.conn.JiraKeyField, link)
	if err == nil && id != 0 {
		r.ids[link] = id // not-found isn't cached: this run may create it
	}
	return id, err
}

// scopedJQL limits clause to the job's project and the extra JQL.
func (r *run) scopedJQL(clause string) string {
	parts := []string{clause, "project = " + jqlQuote(r.job.JiraKey)}
	if r.conn.JQLExtra != "" {
		parts = append(parts, "("+r.conn.JQLExtra+")")
	}
	return strings.Join(parts, " AND ")
}

func (r *run) fieldsOf(d jira.Issue) fields {
	jf := d.Fields
	f := fields{title: jf.Summary, description: adfToHTML(jf.Description), start: jf.Created, target: jf.DueDate, key: d.Key + " - " + d.ID}
	typeName, subtask := "", false
	if it := jf.IssueType; it != nil {
		// Only the name counts as a sub-task here, as in the source; the subtask flag also covers Jira's other child types.
		typeName, subtask = it.Name, strings.EqualFold(it.Name, "subtask") || strings.EqualFold(it.Name, "sub-task")
	}
	f.wiType = r.rules.WorkItemType(typeName, subtask)
	priority, status := "", ""
	if jf.Priority != nil {
		priority = jf.Priority.Name
	}
	if jf.Status != nil {
		status = jf.Status.Name
	}
	f.priority = r.rules.Priority(priority)
	f.state = r.rules.State(f.wiType, status)
	if syncjob.IsTask(f.wiType) {
		f.originalEstimate, f.remaining, f.completed = hours(jf.AggregateTimeOriginalEstimate), hours(jf.AggregateTimeEstimate), hours(jf.AggregateTimeSpent)
	}
	f.area, f.iteration = r.job.Paths(r.e.Now())
	if r.job.Filters.AutoPaths && !d.InActiveSprint(r.sprintField) {
		f.iteration = r.job.BacklogPath() // out of sprint, or taken out of one: back to the backlog
	}
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
	if !syncjob.IsTask(f.wiType) {
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
	return ops
}

// create makes the work item in its first state, then moves it: ADO refuses to create one directly in a later state.
func (r *run) create(ctx context.Context, f fields) (int, error) {
	initial := f
	initial.state = syncjob.InitialState(f.wiType)
	ops := r.ops(initial)
	if f.parentID != 0 {
		ops = append(ops, r.ado.ParentRelation(f.parentID))
	}
	id, err := r.ado.Create(ctx, f.wiType, ops)
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

type updateResult struct {
	done  bool           // ADO has it Done: left alone (commented)
	wrote bool           // something was sent: fields, the Removed reset or a conflict comment
	rels  []ado.Relation // the item's links before this update
}

// update reads the item once, then writes only fields whose value differs; ADO's Done wins and is only commented.
func (r *run) update(ctx context.Context, id int, f fields, d jira.Issue) (updateResult, error) {
	w, err := r.ado.Get(ctx, id)
	if err != nil {
		return updateResult{}, err
	}
	cur, res := w.Fields, updateResult{rels: w.Relations}
	state, _ := cur[syncjob.FieldState].(string)
	if state == "Done" {
		res.done = true
		if r.firstRun {
			return res, nil // a backlog import would leave one comment on every old Done item
		}
		_, err := r.ado.AddComment(ctx, id, fmt.Sprintf(
			"<p>Jira <b>%s</b> vừa được cập nhật nhưng work item này đang ở trạng thái <b>Done</b> nên sync đã bỏ qua, không ghi đè. Vui lòng kiểm tra và cập nhật thủ công nếu cần.</p>",
			escape(f.key)))
		return res, err
	}
	// Removed can only go back to the first state; jumping straight to a later one is a 400.
	if state == "Removed" && f.state != "Removed" {
		if err := r.ado.Update(ctx, id, []ado.Op{{Op: "add", Path: "/fields/" + syncjob.FieldState, Value: syncjob.InitialState(f.wiType)}}); err != nil {
			return res, err
		}
		cur[syncjob.FieldState], res.wrote = syncjob.InitialState(f.wiType), true
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

	ops := changedOps(r.ops(f), cur)
	if f.parentID != 0 && !ado.HasParent(w.Relations, f.parentID) {
		ops = append(ops, r.ado.ParentRelation(f.parentID))
	}
	if len(ops) > 0 {
		if err := r.ado.Update(ctx, id, ops); err != nil {
			return res, err
		}
		res.wrote = true
	}
	if len(conflicts) > 0 {
		html := fmt.Sprintf("<p>Sync từ Jira <b>%s</b> không ghi đè các field đã có giá trị trên ADO:</p><ul><li>%s</li></ul>",
			escape(f.key), strings.Join(conflicts, "</li><li>"))
		if _, err := r.ado.AddComment(ctx, id, html); err != nil {
			return res, err
		}
		res.wrote = true
	}
	return res, nil
}

// changedOps drops the field ops whose value ADO already has, so an unchanged item gets no PATCH, revision or notification.
func changedOps(ops []ado.Op, cur map[string]any) []ado.Op {
	var out []ado.Op
	for _, op := range ops {
		field, ok := strings.CutPrefix(op.Path, "/fields/")
		if ok && sameADOValue(field, cur[field], op.Value) {
			continue
		}
		out = append(out, op)
	}
	return out
}

// sameADOValue compares what ADO returns for a field with what the sync would write.
// When unsure it answers false: an extra write is harmless, a skipped one loses a change.
func sameADOValue(field string, have, want any) bool {
	if have == nil {
		return isEmpty(want)
	}
	switch field {
	case syncjob.FieldAssignedTo, syncjob.FieldCreatedBy: // ADO returns an identity object
		if m, ok := have.(map[string]any); ok {
			u, _ := m["uniqueName"].(string)
			w, _ := want.(string)
			return u != "" && strings.EqualFold(u, w)
		}
	case syncjob.FieldStartDate: // same instant, written with a different offset
		h, _ := have.(string)
		w, _ := want.(string)
		ht, wt := parseJiraTime(h), parseJiraTime(w)
		return !ht.IsZero() && ht.Equal(wt)
	case syncjob.FieldTargetDate:
		return sameValue(have, want)
	case syncjob.FieldDescription:
		h, _ := have.(string)
		w, _ := want.(string)
		return normalizeHTML(h) == normalizeHTML(w)
	case "System.AreaPath", "System.IterationPath":
		h, _ := have.(string)
		w, _ := want.(string)
		return strings.EqualFold(h, w)
	}
	if _, ok := have.(float64); ok {
		return sameValue(have, want)
	}
	return fmt.Sprint(have) == fmt.Sprint(want)
}

// normalizeHTML evens out what ADO rewrites in stored HTML (void tags, whitespace) before comparing.
func normalizeHTML(s string) string {
	s = strings.NewReplacer("<br/>", "<br>", "<br />", "<br>", "<hr/>", "<hr>", "<hr />", "<hr>").Replace(s)
	return strings.Join(strings.Fields(s), " ")
}

// syncAttachments replaces the item's ADO attachments with Jira's; with none in Jira it does nothing,
// so files people attached in ADO stay. It returns how many files it wrote.
// ponytail: re-uploads all files when Jira has any, like the source; diff by name+size if uploads get slow
func (r *run) syncAttachments(ctx context.Context, id int, atts []jira.Attachment, rels []ado.Relation, created bool) (int, []string) {
	if len(atts) == 0 {
		return 0, nil
	}
	var warnings []string
	if !created && slices.ContainsFunc(rels, func(rl ado.Relation) bool { return rl.Rel == "AttachedFile" }) {
		if err := r.ado.RemoveAttachments(ctx, id, rels); err != nil {
			warnings = append(warnings, "remove attachments: "+err.Error())
		}
	}
	written := 0
	for _, a := range atts {
		if r.dry { // no download either: the dry run only needs the names
			_ = r.ado.Attach(ctx, id, a.Filename, nil)
			written++
			continue
		}
		data, err := r.jira.Download(ctx, a.Content)
		if err == nil {
			err = r.ado.Attach(ctx, id, a.Filename, data)
		}
		if err != nil {
			warnings = append(warnings, "attach "+a.Filename+": "+err.Error())
			continue
		}
		written++
	}
	return written, warnings
}

// syncComments copies new Jira comments and patches edited ones in place; comments deleted in Jira are left alone.
// It returns how many comments it wrote.
func (r *run) syncComments(ctx context.Context, key string, id int) (int, []string) {
	comments, err := r.jira.Comments(ctx, key)
	if err != nil {
		return 0, []string{"comments: " + err.Error()}
	}
	if len(comments) == 0 {
		return 0, nil
	}
	state := r.state
	mapped, err := state.CommentMappings(ctx, id)
	if err != nil {
		return 0, []string{"comment mappings: " + err.Error()}
	}
	written := 0
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
			} else {
				written++
			}
		case c.Updated != "" && c.Updated != m.JiraUpdated:
			err := r.ado.UpdateComment(ctx, id, m.ADOCommentID, renderComment(c, true))
			if err == nil {
				m.JiraUpdated = c.Updated
				err = state.SaveCommentMapping(ctx, m)
			}
			if err != nil {
				warnings = append(warnings, "comment "+c.ID+": "+err.Error())
			} else {
				written++
			}
		}
	}
	return written, warnings
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
