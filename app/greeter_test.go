package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHelloServerGreetsByNameParameter(t *testing.T) {
	t.Setenv("HOSTNAME", "greeter-abc123")

	rec := httptest.NewRecorder()
	HelloServer(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/?name=Ada", nil))

	if got := rec.Code; got != http.StatusOK {
		t.Fatalf("status = %d, want %d", got, http.StatusOK)
	}
	if got, want := rec.Body.String(), "Hello, Ada! I'm greeter-abc123\n"; got != want {
		t.Errorf("body = %q, want %q", got, want)
	}
}

func TestHelloServerFallsBackToIPWhenNameAbsent(t *testing.T) {
	t.Setenv("HOSTNAME", "greeter-abc123")

	req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil)
	req.RemoteAddr = "203.0.113.7:54321"

	rec := httptest.NewRecorder()
	HelloServer(rec, req)

	if got, want := rec.Body.String(), "Hello, 203.0.113.7! I'm greeter-abc123\n"; got != want {
		t.Errorf("body = %q, want %q", got, want)
	}
}

func TestHelloServerIncludesHelloTag(t *testing.T) {
	t.Setenv("HOSTNAME", "greeter-abc123")
	t.Setenv("HELLO_TAG", "v1.2.3")

	rec := httptest.NewRecorder()
	HelloServer(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/?name=Ada", nil))

	if got, want := rec.Body.String(), "Hello, Ada! I'm greeter-abc123 (tag: v1.2.3)\n"; got != want {
		t.Errorf("body = %q, want %q", got, want)
	}
}

func TestHelloServerSetsNoSniffPlainTextHeaders(t *testing.T) {
	rec := httptest.NewRecorder()
	HelloServer(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/?name=Ada", nil))

	if got, want := rec.Header().Get("Content-Type"), "text/plain; charset=utf-8"; got != want {
		t.Errorf("Content-Type = %q, want %q", got, want)
	}
	if got, want := rec.Header().Get("X-Content-Type-Options"), "nosniff"; got != want {
		t.Errorf("X-Content-Type-Options = %q, want %q", got, want)
	}
}

func TestHelloServerReturns404ForUnknownPaths(t *testing.T) {
	rec := httptest.NewRecorder()
	HelloServer(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/nope", nil))

	if got := rec.Code; got != http.StatusNotFound {
		t.Errorf("status = %d, want %d", got, http.StatusNotFound)
	}
}

func TestHealthServerReportsOK(t *testing.T) {
	rec := httptest.NewRecorder()
	HealthServer(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/healthz", nil))

	if got := rec.Code; got != http.StatusOK {
		t.Errorf("status = %d, want %d", got, http.StatusOK)
	}
	if got, want := rec.Body.String(), "ok\n"; got != want {
		t.Errorf("body = %q, want %q", got, want)
	}
}

func TestSanitizeName(t *testing.T) {
	long := strings.Repeat("a", maxNameLength+10)

	tests := []struct {
		name      string
		in        string
		want      string
		wantNamed bool
	}{
		{"plain", "Ada", "Ada", true},
		{"trims surrounding space", "  Ada  ", "Ada", true},
		{"empty is unnamed", "", "", false},
		{"whitespace only is unnamed", "   ", "", false},
		{"strips CRLF log forging", "Ada\r\nInject", "AdaInject", true},
		{"strips control characters", "Ada\x00\x07", "Ada", true},
		{"control-only is unnamed", "\r\n\t", "", false},
		{"truncates to max length", long, strings.Repeat("a", maxNameLength), true},
		{"preserves multibyte", "Zoë", "Zoë", true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, named := sanitizeName(tc.in)
			if named != tc.wantNamed {
				t.Fatalf("named = %v, want %v", named, tc.wantNamed)
			}
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestSanitizeNameTruncatesByRuneNotByte(t *testing.T) {
	// A byte-wise truncation of multibyte input would split a rune and emit
	// replacement characters.
	in := strings.Repeat("é", maxNameLength+5)

	got, named := sanitizeName(in)
	if !named {
		t.Fatal("expected a name")
	}
	if got, want := len([]rune(got)), maxNameLength; got != want {
		t.Errorf("rune length = %d, want %d", got, want)
	}
	if strings.ContainsRune(got, '�') {
		t.Error("truncation split a multibyte rune")
	}
}

func TestGetIPFromRequest(t *testing.T) {
	tests := []struct {
		name       string
		remoteAddr string
		xff        string
		want       string
	}{
		{"remote addr strips port", "203.0.113.7:54321", "", "203.0.113.7"},
		{"single xff entry wins", "10.0.0.1:1234", "203.0.113.7", "203.0.113.7"},
		{"xff chain takes leftmost client", "10.0.0.1:1234", "203.0.113.7, 10.0.0.5, 10.0.0.9", "203.0.113.7"},
		{"xff chain tolerates tight spacing", "10.0.0.1:1234", "203.0.113.7,10.0.0.5", "203.0.113.7"},
		{"blank xff falls back to remote addr", "203.0.113.7:54321", "   ", "203.0.113.7"},
		{"ipv6 remote addr strips port", "[2001:db8::1]:443", "", "2001:db8::1"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil)
			req.RemoteAddr = tc.remoteAddr
			if tc.xff != "" {
				req.Header.Set("x-forwarded-for", tc.xff)
			}

			if got := GetIPFromRequest(req); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestPortPrefersEnvironment(t *testing.T) {
	t.Setenv("PORT", "9090")
	if got, want := port(), "9090"; got != want {
		t.Errorf("port() = %q, want %q", got, want)
	}
}

func TestPortFallsBackToDefault(t *testing.T) {
	t.Setenv("PORT", "")
	if got, want := port(), defaultPort; got != want {
		t.Errorf("port() = %q, want %q", got, want)
	}
}

// freePort reserves an ephemeral port and releases it, returning the address.
// There is an unavoidable window between release and rebind; the callers below
// tolerate it by polling.
func freePort(t *testing.T) string {
	t.Helper()

	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve port: %v", err)
	}
	addr := ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatalf("release port: %v", err)
	}
	return addr
}

func TestRunServesUntilContextCancelled(t *testing.T) {
	addr := freePort(t)

	srv := &http.Server{
		Addr:              addr,
		Handler:           http.HandlerFunc(HelloServer),
		ReadHeaderTimeout: readTimeout,
	}

	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	done := make(chan error, 1)
	go func() { done <- run(ctx, srv) }()

	// Poll until the listener is actually accepting.
	client := &http.Client{Timeout: time.Second}
	var served bool
	for range 50 {
		req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, "http://"+addr+"/?name=Ada", nil)
		if err != nil {
			t.Fatalf("build request: %v", err)
		}
		resp, err := client.Do(req)
		if err == nil {
			resp.Body.Close()
			served = resp.StatusCode == http.StatusOK
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !served {
		t.Fatal("server never became reachable")
	}

	// Cancellation must trigger a clean drain, not a hang or an error.
	cancel()

	select {
	case err := <-done:
		if err != nil {
			t.Errorf("run returned %v, want nil on graceful shutdown", err)
		}
	case <-time.After(shutdownTimeout + 5*time.Second):
		t.Fatal("run did not return after context cancellation")
	}
}

func TestRunReturnsListenError(t *testing.T) {
	// Hold the port so ListenAndServe cannot bind. run must surface that
	// rather than block forever.
	var lc net.ListenConfig
	ln, err := lc.Listen(t.Context(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	srv := &http.Server{
		Addr:              ln.Addr().String(),
		Handler:           http.HandlerFunc(HelloServer),
		ReadHeaderTimeout: readTimeout,
	}

	if err := run(t.Context(), srv); err == nil {
		t.Error("run returned nil, want a bind error")
	}
}
