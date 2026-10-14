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
