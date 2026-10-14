// Package ado is the Azure DevOps work-item REST client the sync needs. Every call is reported to OnCall for the run report.
package ado

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"jira-ado/internal/httpx"
)

const (
	apiVersion         = "7.1-preview"
	commentsAPIVersion = "7.1-preview.4" // comments are preview-only; lower to 7.1-preview.3 if the org rejects it
	maxLoggedBody      = 16 << 10
)

// Call is one logged request/response pair.
type Call struct {
	Method, URL string
	Request     string
	Status      int
	Response    string
	Retries     int
	Duration    time.Duration
	Error       string
}

type Client struct {
	org, project string
	h            *httpx.Client
	// OnCall receives every request made, success or not.
	OnCall func(Call)
}

func New(org, project, pat string) *Client {
	auth := PATAuth(pat)
	return NewWith(httpx.New(fmt.Sprintf("%s/%s/%s/_apis", Host, url.PathEscape(org), url.PathEscape(project)), auth), org, project)
}

// NewWith wraps an existing httpx client, for tests.
func NewWith(h *httpx.Client, org, project string) *Client {
	return &Client{org: org, project: project, h: h}
}

// Op is one JSON-patch operation.
type Op struct {
	Op    string `json:"op"`
	Path  string `json:"path"`
	Value any    `json:"value,omitempty"`
}

// Host is the ADO service root; tests point it at a local server.
var Host = "https://dev.azure.com"

// ConnectionData validates the PAT at the organization level and returns the user's display name.
func ConnectionData(ctx context.Context, h *httpx.Client, org string) (string, error) {
	resp, err := h.Do(ctx, "GET", fmt.Sprintf("%s/%s/_apis/connectionData", Host, url.PathEscape(org)), "", nil)
	if err != nil {
		return "", err
	}
	var cd struct {
		AuthenticatedUser *struct {
			ID                  string `json:"id"`
			ProviderDisplayName string `json:"providerDisplayName"`
		} `json:"authenticatedUser"`
	}
	// An invalid PAT can be redirected to an HTML sign-in page that still returns 2xx.
	if json.Unmarshal(resp.Body, &cd) != nil || cd.AuthenticatedUser == nil || cd.AuthenticatedUser.ID == "" ||
		cd.AuthenticatedUser.ID == "00000000-0000-0000-0000-000000000000" {
		return "", errors.New("ADO rejected the personal access token")
	}
	return cd.AuthenticatedUser.ProviderDisplayName, nil
}

// PATAuth is the Authorization header value for a PAT.
func PATAuth(pat string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(":"+pat))
}

// FindByField returns the work item whose field equals value, or 0.
func (c *Client) FindByField(ctx context.Context, field, value string) (int, error) {
	q := fmt.Sprintf("SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '%s' AND [%s] = '%s'",
		wiqlEscape(c.project), field, wiqlEscape(value))
	var out struct {
		WorkItems []struct {
			ID int `json:"id"`
		} `json:"workItems"`
	}
	if err := c.send(ctx, "POST", "/wit/wiql?api-version="+apiVersion, "application/json", map[string]string{"query": q}, &out); err != nil {
		return 0, err
	}
	if len(out.WorkItems) == 0 {
		return 0, nil
	}
	return out.WorkItems[0].ID, nil
}

// wiqlEscape doubles single quotes so a Jira key can't break out of the WIQL string.
func wiqlEscape(s string) string { return strings.ReplaceAll(s, "'", "''") }

// NodeExists reports whether an area or iteration path exists. kind is "areas" or "iterations";
// path starts with the project name, as in System.AreaPath ("Tickets\\KPL\\KAI").
func (c *Client) NodeExists(ctx context.Context, kind, path string) (bool, error) {
	parts := strings.Split(strings.Trim(path, `\`), `\`)
	if len(parts) == 0 || !strings.EqualFold(parts[0], c.project) {
		return false, nil // a path outside the project can't be used for its work items
	}
	rest := make([]string, 0, len(parts)-1)
	for _, p := range parts[1:] {
		rest = append(rest, url.PathEscape(p))
	}
	u := fmt.Sprintf("/wit/classificationnodes/%s/%s?$depth=0&api-version=%s", kind, strings.Join(rest, "/"), apiVersion)
	_, err := c.h.Do(ctx, "GET", u, "", nil)
	var se *httpx.StatusError
	if errors.As(err, &se) && se.Status == 404 {
		return false, nil
	}
	return err == nil, err
}

// Relation is one link of a work item: a parent, a child, an attached file…
type Relation struct {
	Rel string `json:"rel"`
	URL string `json:"url"`
}

// WorkItem is a work item's current fields and relations.
type WorkItem struct {
	Fields    map[string]any `json:"fields"`
	Relations []Relation     `json:"relations"`
}

// Get reads every field and relation in one call ($expand can't be combined with a field list).
func (c *Client) Get(ctx context.Context, id int) (WorkItem, error) {
	var w WorkItem
	err := c.send(ctx, "GET", fmt.Sprintf("/wit/workitems/%d?$expand=relations&api-version=%s", id, apiVersion), "", nil, &w)
	return w, err
}

// HasParent reports whether the relations already link the item under parentID.
func HasParent(rels []Relation, parentID int) bool {
	suffix := fmt.Sprintf("/workItems/%d", parentID)
	for _, r := range rels {
		if r.Rel == "System.LinkTypes.Hierarchy-Reverse" && strings.HasSuffix(strings.ToLower(r.URL), strings.ToLower(suffix)) {
			return true
		}
	}
	return false
}

func (c *Client) Create(ctx context.Context, workItemType string, ops []Op) (int, error) {
	var out struct {
		ID int `json:"id"`
	}
	path := fmt.Sprintf("/wit/workitems/$%s?api-version=%s", url.PathEscape(workItemType), apiVersion)
	err := c.send(ctx, "POST", path, "application/json-patch+json", ops, &out)
	return out.ID, err
}

func (c *Client) Update(ctx context.Context, id int, ops []Op) error {
	return c.send(ctx, "PATCH", fmt.Sprintf("/wit/workitems/%d?api-version=%s", id, apiVersion), "application/json-patch+json", ops, nil)
}

// ParentRelation links a work item under parentID.
func (c *Client) ParentRelation(parentID int) Op {
	return Op{Op: "add", Path: "/relations/-", Value: map[string]string{
		"rel": "System.LinkTypes.Hierarchy-Reverse",
		"url": fmt.Sprintf("%s/%s/%s/_apis/wit/workItems/%d", Host, url.PathEscape(c.org), url.PathEscape(c.project), parentID),
	}}
}

// RemoveAttachments drops every AttachedFile relation, given the item's relations as read by Get.
// Links added since then went to the end, so these indexes still hold.
func (c *Client) RemoveAttachments(ctx context.Context, id int, rels []Relation) error {
	var ops []Op
	for i := len(rels) - 1; i >= 0; i-- { // from the end so earlier indexes stay valid
		if rels[i].Rel == "AttachedFile" {
			ops = append(ops, Op{Op: "remove", Path: fmt.Sprintf("/relations/%d", i)})
		}
	}
	if len(ops) == 0 {
		return nil
	}
	return c.Update(ctx, id, ops)
}

// Attach uploads data and links it to the work item.
func (c *Client) Attach(ctx context.Context, id int, name string, data []byte) error {
	path := fmt.Sprintf("/wit/attachments?fileName=%s&api-version=%s", url.QueryEscape(name), apiVersion)
	resp, err := c.h.Do(ctx, "POST", path, "application/octet-stream", data)
	c.log("POST", path, fmt.Sprintf("<%d bytes>", len(data)), resp, err)
	if err != nil {
		return err
	}
	var att struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(resp.Body, &att); err != nil {
		return fmt.Errorf("decode attachment upload: %w", err)
	}
	return c.Update(ctx, id, []Op{{Op: "add", Path: "/relations/-", Value: map[string]any{
		"rel": "AttachedFile", "url": att.URL, "attributes": map[string]string{"name": name},
	}}})
}

func (c *Client) AddComment(ctx context.Context, id int, html string) (int, error) {
	var out struct {
		ID int `json:"id"`
	}
	path := fmt.Sprintf("/wit/workItems/%d/comments?api-version=%s", id, commentsAPIVersion)
	err := c.send(ctx, "POST", path, "application/json", map[string]string{"text": html}, &out)
	return out.ID, err
}

func (c *Client) UpdateComment(ctx context.Context, id, commentID int, html string) error {
	path := fmt.Sprintf("/wit/workItems/%d/comments/%d?api-version=%s", id, commentID, commentsAPIVersion)
	return c.send(ctx, "PATCH", path, "application/json", map[string]string{"text": html}, nil)
}

func (c *Client) send(ctx context.Context, method, path, contentType string, in, out any) error {
	var body []byte
	if in != nil {
		var err error
		if body, err = json.MarshalIndent(in, "", "  "); err != nil {
			return err
		}
	}
	resp, err := c.h.Do(ctx, method, path, contentType, body)
	c.log(method, path, string(body), resp, err)
	if err != nil {
		return err
	}
	if out != nil {
		if err := json.Unmarshal(resp.Body, out); err != nil {
			return fmt.Errorf("decode %s %s: %w", method, path, err)
		}
	}
	return nil
}

func (c *Client) log(method, path, req string, resp httpx.Response, err error) {
	if c.OnCall == nil {
		return
	}
	call := Call{Method: method, URL: c.h.Base + path, Request: req, Status: resp.Status, Response: clip(resp.Body),
		Retries: resp.Retries, Duration: resp.Duration}
	if err != nil {
		call.Error = err.Error()
		var se *httpx.StatusError
		if errors.As(err, &se) {
			call.Response = clip(se.Body)
		}
	}
	c.OnCall(call)
}

func clip(b []byte) string {
	if len(b) > maxLoggedBody {
		return string(b[:maxLoggedBody]) + "\n…(truncated)"
	}
	return string(b)
}
