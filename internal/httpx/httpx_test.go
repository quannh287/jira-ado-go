package httpx

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestRetry(t *testing.T) {
	cases := []struct {
		name     string
		statuses []int
		wantErr  bool
		wantHits int32
	}{
		{"5xx then ok", []int{503, 502, 200}, false, 3},
		{"429 retried", []int{429, 200}, false, 2},
		{"4xx not retried", []int{400, 200}, true, 1},
		{"gives up after retries", []int{500, 500, 500, 500, 200}, true, 4},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var hits atomic.Int32
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				n := hits.Add(1)
				if r.Header.Get("Authorization") != "Basic x" {
					t.Errorf("auth header = %q", r.Header.Get("Authorization"))
				}
				w.WriteHeader(tc.statuses[n-1])
			}))
			defer srv.Close()
			c := New(srv.URL, "Basic x")
			c.BaseDelay = 0
			resp, err := c.Do(context.Background(), "GET", "/x", "", nil)
			if (err != nil) != tc.wantErr || hits.Load() != tc.wantHits {
				t.Fatalf("err=%v hits=%d, want err=%v hits=%d", err, hits.Load(), tc.wantErr, tc.wantHits)
			}
			if resp.Retries != int(tc.wantHits)-1 {
				t.Fatalf("retries = %d", resp.Retries)
			}
			var se *StatusError
			if tc.wantErr && !errors.As(err, &se) {
				t.Fatalf("want StatusError, got %T", err)
			}
		})
	}
}

func TestNetworkErrorRetried(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	url := srv.URL
	srv.Close() // connection refused
	c := New(url, "")
	c.BaseDelay = 0
	resp, err := c.Do(context.Background(), "GET", "/x", "", nil)
	if err == nil || resp.Retries != 3 {
		t.Fatalf("err=%v retries=%d", err, resp.Retries)
	}
}
