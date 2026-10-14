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
