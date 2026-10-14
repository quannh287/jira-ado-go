package app

import (
	"testing"

	"jira-ado/internal/syncjob"
)

func TestSynced(t *testing.T) {
	calls := []syncjob.APICall{
		{Method: "POST", URL: "https://dev.azure.com/o/p/_apis/wit/wiql?api-version=7.1", Request: `{"query":"SELECT"}`, Status: 200},
		{Method: "POST", URL: "https://dev.azure.com/o/p/_apis/wit/workitems/$Task?api-version=7.1", Status: 200, Request: `[
			{"op":"add","path":"/fields/System.Title","value":"SE-1 - 10 - Fix login"},
			{"op":"add","path":"/fields/System.State","value":"To Do"},
			{"op":"add","path":"/fields/System.Description","value":"<p><strong>a &amp; b</strong></p>"},
			{"op":"add","path":"/relations/-","value":{"rel":"System.LinkTypes.Hierarchy-Reverse","url":"x"}}]`},
		{Method: "PATCH", URL: "https://dev.azure.com/o/p/_apis/wit/workitems/5?api-version=7.1", Status: 200,
			Request: `[{"op":"add","path":"/fields/System.State","value":"In Progress"},{"op":"add","path":"/relations/-","value":{"rel":"AttachedFile","url":"y"}}]`},
		{Method: "PATCH", URL: "https://dev.azure.com/o/p/_apis/wit/workitems/5?api-version=7.1", Status: 400,
			Request: `[{"op":"add","path":"/fields/System.State","value":"Done"}]`},
		{Method: "POST", URL: "https://dev.azure.com/o/p/_apis/wit/workItems/5/comments?api-version=7.1-preview.4", Status: 200, Request: `{"text":"hi"}`},
	}
	fields, notes := synced(calls)
	want := []syncedField{{"Title", "SE-1 - 10 - Fix login"}, {"State", "In Progress"}, {"Description", "a & b"}}
	if len(fields) != len(want) {
		t.Fatalf("fields %+v", fields)
	}
	for i := range want {
		if fields[i] != want[i] {
			t.Errorf("field %d = %+v, want %+v", i, fields[i], want[i])
		}
	}
	if got := len(notes); got != 3 { // parent, attachment, comment
		t.Fatalf("notes %q", notes)
	}
	if shortURL(calls[2].URL) != "/wit/workitems/5" {
		t.Fatalf("shortURL %q", shortURL(calls[2].URL))
	}
}

func TestReferenceLinks(t *testing.T) {
	if got := issueURL("https://keppel-ltd.atlassian.net/", "CAT-284"); got != "https://keppel-ltd.atlassian.net/browse/CAT-284" {
		t.Fatalf("jira %q", got)
	}
	if got := workItemURL("ats-technology", "My Project", 32143); got != "https://dev.azure.com/ats-technology/My%20Project/_workitems/edit/32143" {
		t.Fatalf("ado %q", got)
	}
	if issueURL("", "X-1") != "" || workItemURL("o", "p", 0) != "" {
		t.Fatal("links without a site or an id must be empty")
	}
}
