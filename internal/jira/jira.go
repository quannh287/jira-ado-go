// Package jira is the Jira Cloud REST v3 client the sync needs.
package jira

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"time"

	"jira-ado/internal/httpx"
)

type Client struct{ h *httpx.Client }

func New(baseURL, email, token string) *Client {
	auth := "Basic " + base64.StdEncoding.EncodeToString([]byte(email+":"+token))
	return &Client{h: httpx.New(baseURL+"/rest/api/3", auth)}
}

// NewWith wraps an existing httpx client, for tests.
func NewWith(h *httpx.Client) *Client { return &Client{h: h} }

type User struct {
	EmailAddress string `json:"emailAddress"`
	DisplayName  string `json:"displayName"`
}

type Ref struct {
	ID  string `json:"id"`
	Key string `json:"key"`
}

type Attachment struct {
	Filename string `json:"filename"`
	Content  string `json:"content"` // absolute download URL
	Size     int64  `json:"size"`
}

type Fields struct {
	Summary     string          `json:"summary"`
	Description json.RawMessage `json:"description"` // ADF
	Created     string          `json:"created"`
	Updated     string          `json:"updated"`
	DueDate     string          `json:"duedate"`
	Priority    *struct {
		Name string `json:"name"`
	} `json:"priority"`
	Status *struct {
		Name string `json:"name"`
	} `json:"status"`
	IssueType *struct {
		Name    string `json:"name"`
		Subtask bool   `json:"subtask"`
	} `json:"issuetype"`
	Parent                        *Ref         `json:"parent"`
	Assignee                      *User        `json:"assignee"`
	Reporter                      *User        `json:"reporter"`
	Subtasks                      []Ref        `json:"subtasks"`
	AggregateTimeEstimate         float64      `json:"aggregatetimeestimate"`
	AggregateTimeOriginalEstimate float64      `json:"aggregatetimeoriginalestimate"`
	AggregateTimeSpent            float64      `json:"aggregatetimespent"`
	Attachment                    []Attachment `json:"attachment"`
}

type Issue struct {
	ID     string `json:"id"`
	Key    string `json:"key"`
	Fields Fields `json:"fields"`
	// Raw keeps every field, for custom fields whose ID differs per site, such as Sprint.
	Raw map[string]json.RawMessage `json:"-"`
}

func (i *Issue) UnmarshalJSON(b []byte) error {
	var aux struct {
		ID     string          `json:"id"`
		Key    string          `json:"key"`
		Fields json.RawMessage `json:"fields"`
	}
	if err := json.Unmarshal(b, &aux); err != nil {
		return err
	}
	i.ID, i.Key = aux.ID, aux.Key
	if len(aux.Fields) == 0 || string(aux.Fields) == "null" {
		return nil
	}
	if err := json.Unmarshal(aux.Fields, &i.Fields); err != nil {
		return err
	}
	return json.Unmarshal(aux.Fields, &i.Raw)
}

// InActiveSprint reports whether the issue sits in a sprint that has started and not closed.
func (i Issue) InActiveSprint(sprintField string) bool {
	var sprints []struct {
		State string `json:"state"`
	}
	if json.Unmarshal(i.Raw[sprintField], &sprints) != nil {
		return false
	}
	for _, s := range sprints {
		if s.State == "active" {
			return true
		}
	}
	return false
}

// SprintField returns the ID of the Jira Software Sprint field (e.g. customfield_10020), or "" if the site has none.
func (c *Client) SprintField(ctx context.Context) (string, error) {
	var fields []struct {
		ID     string `json:"id"`
		Schema struct {
			Custom string `json:"custom"`
		} `json:"schema"`
	}
	if err := c.json(ctx, "GET", "/field", nil, &fields); err != nil {
		return "", fmt.Errorf("jira fields: %w", err)
	}
	for _, f := range fields {
		if f.Schema.Custom == "com.pyxis.greenhopper.jira:gh-sprint" {
			return f.ID, nil
		}
	}
	return "", nil
}

type Comment struct {
	ID      string          `json:"id"`
	Author  *User           `json:"author"`
	Body    json.RawMessage `json:"body"`
	Updated string          `json:"updated"`
}

var (
	MiniFields = []string{"id", "subtasks", "updated"}
	AllFields  = []string{"*all"}
)

// Search pages through POST /search/jql with nextPageToken.
func (c *Client) Search(ctx context.Context, jql string, fields []string) ([]Issue, error) {
	var all []Issue
	token := ""
	for {
		body := map[string]any{"jql": jql, "maxResults": 100, "fields": fields}
		if token != "" {
			body["nextPageToken"] = token
		}
		var page struct {
			Issues        []Issue `json:"issues"`
			IsLast        bool    `json:"isLast"`
			NextPageToken string  `json:"nextPageToken"`
		}
		if err := c.json(ctx, "POST", "/search/jql", body, &page); err != nil {
			return nil, fmt.Errorf("jira search %q: %w", jql, err)
		}
		all = append(all, page.Issues...)
		if page.IsLast || page.NextPageToken == "" {
			return all, nil
		}
		token = page.NextPageToken
	}
}

// Comments pages through /issue/{key}/comment; the comment field on search results is not complete.
func (c *Client) Comments(ctx context.Context, key string) ([]Comment, error) {
	var all []Comment
	for start := 0; ; {
		var page struct {
			Comments []Comment `json:"comments"`
			Total    int       `json:"total"`
		}
		path := fmt.Sprintf("/issue/%s/comment?startAt=%d&maxResults=100&orderBy=created", url.PathEscape(key), start)
		if err := c.json(ctx, "GET", path, nil, &page); err != nil {
			return nil, fmt.Errorf("jira comments %s: %w", key, err)
		}
		all = append(all, page.Comments...)
		start += len(page.Comments)
		if len(page.Comments) == 0 || start >= page.Total {
			return all, nil
		}
	}
}

func (c *Client) Download(ctx context.Context, contentURL string) ([]byte, error) {
	resp, err := c.h.Do(ctx, "GET", contentURL, "", nil)
	return resp.Body, err
}

// ProjectStatuses lists a project's issue types and the statuses their workflows use, in Jira's order.
func (c *Client) ProjectStatuses(ctx context.Context, project string) (types, statuses []string, err error) {
	var out []struct {
		Name     string `json:"name"`
		Statuses []struct {
			Name string `json:"name"`
		} `json:"statuses"`
	}
	if err := c.json(ctx, "GET", "/project/"+url.PathEscape(project)+"/statuses", nil, &out); err != nil {
		return nil, nil, fmt.Errorf("jira statuses of %s: %w", project, err)
	}
	for _, t := range out {
		types = append(types, t.Name)
		for _, s := range t.Statuses {
			statuses = append(statuses, s.Name)
		}
	}
	return types, statuses, nil
}

// Priorities lists the site's priority names, highest first.
func (c *Client) Priorities(ctx context.Context) ([]string, error) {
	var out []struct {
		Name string `json:"name"`
	}
	if err := c.json(ctx, "GET", "/priority", nil, &out); err != nil {
		return nil, fmt.Errorf("jira priorities: %w", err)
	}
	names := make([]string, len(out))
	for i, p := range out {
		names[i] = p.Name
	}
	return names, nil
}

// TimeZone is the account's time zone, the one Jira reads JQL dates in.
func (c *Client) TimeZone(ctx context.Context) (*time.Location, error) {
	var u struct {
		TimeZone string `json:"timeZone"`
	}
	if err := c.json(ctx, "GET", "/myself", nil, &u); err != nil {
		return nil, err
	}
	if u.TimeZone == "" {
		return time.UTC, nil
	}
	return time.LoadLocation(u.TimeZone)
}

// Myself checks the credentials and returns the account's display name.
func (c *Client) Myself(ctx context.Context) (string, error) {
	var u User
	err := c.json(ctx, "GET", "/myself", nil, &u)
	return u.DisplayName, err
}

func (c *Client) json(ctx context.Context, method, path string, in, out any) error {
	var body []byte
	if in != nil {
		var err error
		if body, err = json.Marshal(in); err != nil {
			return err
		}
	}
	resp, err := c.h.Do(ctx, method, path, "application/json", body)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(resp.Body, out); err != nil {
		return fmt.Errorf("decode %s %s: %w", method, path, err)
	}
	return nil
}
