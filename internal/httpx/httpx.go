// Package httpx is a small JSON-over-HTTP client with retries for transient failures.
package httpx

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

const maxBody = 32 << 20 // larger responses are refused rather than buffered

// Client sends requests relative to Base with a fixed Authorization header.
type Client struct {
	HTTP      *http.Client
	Base      string
	Auth      string
	Retries   int
	BaseDelay time.Duration
}

func New(base, auth string) *Client {
	return &Client{HTTP: &http.Client{Timeout: 30 * time.Second}, Base: strings.TrimRight(base, "/"), Auth: auth, Retries: 3, BaseDelay: 500 * time.Millisecond}
}

// StatusError is a non-2xx response; Body is kept for the report.
type StatusError struct {
	Method, URL string
	Status      int
	Body        []byte
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("%s %s: HTTP %d: %s", e.Method, e.URL, e.Status, truncate(e.Body, 300))
}

// Response is a completed exchange, also returned alongside errors so callers can log it.
type Response struct {
	Status   int
	Body     []byte
	Retries  int
	Duration time.Duration
}

// Do sends body (nil for none) and retries 429, 5xx and network errors with exponential backoff; other 4xx fail at once.
func (c *Client) Do(ctx context.Context, method, path, contentType string, body []byte) (Response, error) {
	url := path
	if !strings.HasPrefix(path, "http://") && !strings.HasPrefix(path, "https://") {
		url = c.Base + path
	}
	start := time.Now()
	var resp Response
	for attempt := 0; ; attempt++ {
		status, data, err := c.once(ctx, method, url, contentType, body)
		resp = Response{Status: status, Body: data, Retries: attempt, Duration: time.Since(start)}
		if err == nil && status < 300 {
			return resp, nil
		}
		if err == nil {
			err = &StatusError{Method: method, URL: url, Status: status, Body: data}
		}
		if attempt >= c.Retries || !transient(ctx, status, err) {
			// Only the URL and status: bodies and headers can hold work item data or credentials.
			slog.Warn("http request failed", "method", method, "url", url, "status", status, "retries", attempt,
				"elapsed", resp.Duration.Round(time.Millisecond), "err", truncate([]byte(err.Error()), 500))
			return resp, err
		}
		delay := c.BaseDelay << attempt
		slog.Info("http retry", "method", method, "url", url, "status", statusOr(status, err), "attempt", attempt+1, "delay", delay)
		select {
		case <-time.After(delay):
		case <-ctx.Done():
			return resp, ctx.Err()
		}
	}
}

func (c *Client) once(ctx context.Context, method, url, contentType string, body []byte) (int, []byte, error) {
	var r io.Reader
	if body != nil {
		r = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, r)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", c.Auth)
	req.Header.Set("Accept", "application/json")
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	res, err := c.HTTP.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, maxBody+1))
	if err != nil {
		return res.StatusCode, nil, err
	}
	if len(data) > maxBody {
		return res.StatusCode, nil, fmt.Errorf("%s %s: response larger than %d bytes", method, url, maxBody)
	}
	return res.StatusCode, data, nil
}

func transient(ctx context.Context, status int, err error) bool {
	if ctx.Err() != nil {
		return false
	}
	var se *StatusError
	if errors.As(err, &se) {
		return se.Status == http.StatusTooManyRequests || se.Status >= 500
	}
	return status == 0 // transport error: timeout, reset, DNS
}

func statusOr(status int, err error) any {
	if status != 0 {
		return status
	}
	return err
}

func truncate(b []byte, n int) string {
	if len(b) > n {
		return string(b[:n]) + "…"
	}
	return string(b)
}
