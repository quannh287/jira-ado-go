package ado

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"jira-ado/internal/httpx"
)

func TestFindByFieldEscapesWIQL(t *testing.T) {
	var query string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Query string }
		json.NewDecoder(r.Body).Decode(&body)
		query = body.Query
		io.WriteString(w, `{"workItems":[{"id":42}]}`)
	}))
	defer srv.Close()
	c := NewWith(httpx.New(srv.URL, "x"), "org", "kai")
	var calls []Call
	c.OnCall = func(call Call) { calls = append(calls, call) }
	id, err := c.FindByField(context.Background(), "Custom.JiraID", "SE-1' OR '1'='1")
	if err != nil || id != 42 {
		t.Fatalf("id=%d err=%v", id, err)
	}
	if !strings.Contains(query, `[Custom.JiraID] = 'SE-1'' OR ''1''=''1'`) {
		t.Fatalf("value not escaped: %s", query)
	}
	if len(calls) != 1 || calls[0].Status != 200 || !strings.Contains(calls[0].Request, "SELECT") {
		t.Fatalf("call not logged: %+v", calls)
	}
}

func TestErrorCallIsLogged(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(400)
		io.WriteString(w, `{"message":"TF401320: Rule Error"}`)
	}))
	defer srv.Close()
	c := NewWith(httpx.New(srv.URL, "x"), "org", "kai")
	var got Call
	c.OnCall = func(call Call) { got = call }
	if err := c.Update(context.Background(), 1, []Op{{Op: "add", Path: "/fields/System.State", Value: "Done"}}); err == nil {
		t.Fatal("400 not returned as an error")
	}
	if got.Status != 400 || !strings.Contains(got.Response, "TF401320") || got.Error == "" || got.Retries != 0 {
		t.Fatalf("logged %+v", got)
	}
}

func TestConnectionData(t *testing.T) {
	for _, tc := range []struct {
		body string
		ok   bool
	}{
		{`{"authenticatedUser":{"id":"u1","providerDisplayName":"Quan"}}`, true},
		{`{"authenticatedUser":{"id":"00000000-0000-0000-0000-000000000000"}}`, false},
		{`<html>sign in</html>`, false},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/org/_apis/connectionData" {
				t.Errorf("path %s", r.URL.Path)
			}
			io.WriteString(w, tc.body)
		}))
		Host = srv.URL
		name, err := ConnectionData(context.Background(), httpx.New("", "x"), "org")
		srv.Close()
		if (err == nil) != tc.ok || (tc.ok && name != "Quan") {
			t.Errorf("%s: name=%q err=%v", tc.body, name, err)
		}
	}
	Host = "https://dev.azure.com"
}

func TestNodeExists(t *testing.T) {
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.EscapedPath())
		if strings.Contains(r.URL.Path, "Missing") {
			w.WriteHeader(404)
			return
		}
		io.WriteString(w, `{"id":1}`)
	}))
	defer srv.Close()
	c := NewWith(httpx.New(srv.URL, "x"), "org", "Tickets")
	for _, tc := range []struct {
		kind, path string
		want       bool
	}{
		{"areas", `Tickets\KPL\KAI`, true},
		{"iterations", `Tickets\Weekly Sprint\Sprint 82`, true},
		{"iterations", `Tickets`, true},
		{"areas", `Tickets\Missing`, false},
		{"areas", `Other\KAI`, false}, // another project: no request at all
	} {
		got, err := c.NodeExists(context.Background(), tc.kind, tc.path)
		if err != nil || got != tc.want {
			t.Errorf("%s %s = %v, %v; want %v", tc.kind, tc.path, got, err, tc.want)
		}
	}
	if len(paths) != 4 || paths[1] != "/wit/classificationnodes/iterations/Weekly%20Sprint/Sprint%2082" {
		t.Fatalf("requests %q", paths)
	}
}

func TestHasParent(t *testing.T) {
	rels := []Relation{
		{Rel: "AttachedFile", URL: "https://x/att/1"},
		{Rel: "System.LinkTypes.Hierarchy-Reverse", URL: "https://dev.azure.com/o/p/_apis/wit/workItems/32143"},
	}
	if !HasParent(rels, 32143) || HasParent(rels, 3214) || HasParent(rels, 1) {
		t.Fatal("HasParent matched the wrong parent")
	}
}

func TestWorkItemTypesAndStates(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/wit/workitemtypes"):
			io.WriteString(w, `{"value":[{"name":"Bug"},{"name":"Old Type","isDisabled":true},{"name":"Task"}]}`)
		case strings.HasSuffix(r.URL.EscapedPath(), "/wit/workitemtypes/Product%20Backlog%20Item/states"):
			io.WriteString(w, `{"value":[{"name":"New"},{"name":"Done"}]}`)
		default:
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	c := NewWith(httpx.New(srv.URL, "x"), "org", "Tickets")
	types, err := c.WorkItemTypes(context.Background())
	if err != nil || len(types) != 2 || types[1] != "Task" {
		t.Fatalf("types %q err %v", types, err)
	}
	states, err := c.States(context.Background(), "Product Backlog Item")
	if err != nil || len(states) != 2 || states[0] != "New" {
		t.Fatalf("states %q err %v", states, err)
	}
}
