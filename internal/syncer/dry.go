package syncer

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"

	"jira-ado/internal/ado"
	"jira-ado/internal/syncjob"
)

// notSent is the response a dry run records for a write it held back.
const notSent = "dry run: not sent"

// dryADO lets reads through and records every write instead of sending it.
type dryADO struct {
	adoAPI
	log  func(ado.Call)
	next int // fake IDs for work items "created" by the dry run
}

func (d *dryADO) record(method, path string, body any) {
	b, _ := json.MarshalIndent(body, "", "  ")
	d.log(ado.Call{Method: method, URL: path, Request: string(b), Response: notSent})
}

func (d *dryADO) Create(_ context.Context, workItemType string, ops []ado.Op) (int, error) {
	d.record("POST", "/wit/workitems/$"+url.PathEscape(workItemType), ops)
	d.next--
	return d.next, nil
}

func (d *dryADO) Update(_ context.Context, id int, ops []ado.Op) error {
	d.record("PATCH", fmt.Sprintf("/wit/workitems/%d", id), ops)
	return nil
}

// RemoveAttachments must not reach the real client, whose implementation writes.
func (d *dryADO) RemoveAttachments(_ context.Context, id int) error {
	d.record("PATCH", fmt.Sprintf("/wit/workitems/%d (remove attachments)", id), nil)
	return nil
}

func (d *dryADO) Attach(_ context.Context, id int, name string, data []byte) error {
	d.record("POST", fmt.Sprintf("/wit/attachments?fileName=%s (link to #%d)", url.QueryEscape(name), id), map[string]int{"bytes": len(data)})
	return nil
}

func (d *dryADO) AddComment(_ context.Context, id int, html string) (int, error) {
	d.record("POST", fmt.Sprintf("/wit/workItems/%d/comments", id), map[string]string{"text": html})
	return 0, nil
}

func (d *dryADO) UpdateComment(_ context.Context, id, commentID int, html string) error {
	d.record("PATCH", fmt.Sprintf("/wit/workItems/%d/comments/%d", id, commentID), map[string]string{"text": html})
	return nil
}

// readOnlyState reads the real cursor and mappings but keeps the dry run from moving them.
type readOnlyState struct{ syncjob.State }

func (readOnlyState) SetCursor(context.Context, int, string) error                     { return nil }
func (readOnlyState) SaveCommentMapping(context.Context, syncjob.CommentMapping) error { return nil }
