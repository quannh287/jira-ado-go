package jira

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"jira-ado/internal/httpx"
)

func TestSearchPaginates(t *testing.T) {
	var tokens []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		tok, _ := body["nextPageToken"].(string)
		tokens = append(tokens, tok)
		if tok == "" {
			io.WriteString(w, `{"issues":[{"id":"1","key":"SE-1"}],"nextPageToken":"p2"}`)
			return
		}
		io.WriteString(w, `{"issues":[{"id":"2","key":"SE-2","fields":{"updated":"2026-10-01T00:00:00.000+0000"}}],"isLast":true}`)
	}))
	defer srv.Close()
	got, err := NewWith(httpx.New(srv.URL, "x")).Search(context.Background(), "project = SE", MiniFields)
	if err != nil || len(got) != 2 || got[1].Fields.Updated == "" {
		t.Fatalf("got %+v err %v", got, err)
	}
	if len(tokens) != 2 || tokens[1] != "p2" {
		t.Fatalf("tokens %q", tokens)
	}
}

func TestCommentsPaginate(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("startAt") == "0" {
			io.WriteString(w, `{"comments":[{"id":"a"}],"total":2}`)
			return
		}
		io.WriteString(w, `{"comments":[{"id":"b"}],"total":2}`)
	}))
	defer srv.Close()
	got, err := NewWith(httpx.New(srv.URL, "x")).Comments(context.Background(), "SE-1")
	if err != nil || len(got) != 2 {
		t.Fatalf("got %+v err %v", got, err)
	}
}

func TestSprint(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/field":
			io.WriteString(w, `[{"id":"summary","schema":{}},{"id":"customfield_10020","schema":{"custom":"com.pyxis.greenhopper.jira:gh-sprint"}}]`)
		default:
			io.WriteString(w, `{"issues":[
				{"id":"1","key":"CAT-1","fields":{"summary":"a","customfield_10020":[{"id":5,"state":"closed"},{"id":6,"state":"active"}]}},
				{"id":"2","key":"CAT-2","fields":{"summary":"b","customfield_10020":[{"id":7,"state":"future"}]}},
				{"id":"3","key":"CAT-3","fields":{"summary":"c","customfield_10020":null}}],"isLast":true}`)
		}
	}))
	defer srv.Close()
	c := NewWith(httpx.New(srv.URL, "x"))
	field, err := c.SprintField(context.Background())
	if err != nil || field != "customfield_10020" {
		t.Fatalf("field %q err %v", field, err)
	}
	issues, err := c.Search(context.Background(), "x", AllFields)
	if err != nil || issues[0].Fields.Summary != "a" {
		t.Fatalf("issues %+v err %v", issues, err)
	}
	for i, want := range []bool{true, false, false} {
		if got := issues[i].InActiveSprint(field); got != want {
			t.Errorf("%s in active sprint = %v, want %v", issues[i].Key, got, want)
		}
	}
}

func TestProjectStatusesAndPriorities(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/project/CAT/statuses":
			io.WriteString(w, `[{"name":"Story","statuses":[{"name":"To Do"},{"name":"Done"}]},{"name":"Sub-task","statuses":[{"name":"To Do"},{"name":"QA"}]}]`)
		case "/priority":
			io.WriteString(w, `[{"name":"Highest"},{"name":"Low"}]`)
		default:
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	c := NewWith(httpx.New(srv.URL, "x"))
	types, statuses, err := c.ProjectStatuses(context.Background(), "CAT")
	if err != nil || len(types) != 2 || len(statuses) != 4 || types[1] != "Sub-task" {
		t.Fatalf("types %q statuses %q err %v", types, statuses, err)
	}
	p, err := c.Priorities(context.Background())
	if err != nil || len(p) != 2 || p[0] != "Highest" {
		t.Fatalf("priorities %q err %v", p, err)
	}
}
