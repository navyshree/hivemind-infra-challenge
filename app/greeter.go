// Command greeter is a small HTTP service that greets the caller.
//
// It greets by the "name" URL parameter when supplied, and falls back to the
// caller's IP address otherwise. The value of HELLO_TAG is reported both at
// startup and on every response so a running pod can be traced back to the
// image and release that produced it.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
	"unicode"
)

const (
	defaultPort = "8080"

	// Deliberately not 8080: the Ingress routes only to the application port,
	// so metrics are unreachable from the internet by construction.
	defaultMetricsPort = "9090"

	// maxNameLength bounds the greeting parameter so a caller cannot use it to
	// drive large allocations or flood the logs.
	maxNameLength = 64

	readTimeout     = 5 * time.Second
	writeTimeout    = 10 * time.Second
	idleTimeout     = 120 * time.Second
	shutdownTimeout = 15 * time.Second
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	// serve() rather than inlining here: os.Exit skips deferred functions, so
	// calling it inside the body that owns the metrics server's shutdown defer
	// would silently abandon that cleanup on the error path.
	if err := serve(); err != nil {
		slog.Error("server terminated unexpectedly", "error", err)
		os.Exit(1)
	}
	slog.Info("shutdown complete")
}

// serve wires up both listeners and blocks until the process is told to stop.
func serve() error {
	addr := net.JoinHostPort("", port())
	slog.Info("starting Hivemind Go Greeter",
		"hello_tag", helloTag(),
		"hostname", hostname(),
		"addr", addr,
	)

	mux := http.NewServeMux()
	mux.HandleFunc("/", HelloServer)
	mux.HandleFunc("/healthz", HealthServer)
	mux.HandleFunc("/readyz", HealthServer)

	// Metrics live on their own port and their own server. Keeping them off the
	// application port means the Ingress cannot expose them however the routing
	// is later changed — the ALB only ever knows about 8080.
	m := newMetrics(time.Now())
	metricsMux := http.NewServeMux()
	metricsMux.Handle("/metrics", m)

	metricsSrv := &http.Server{
		Addr:              net.JoinHostPort("", metricsPort()),
		Handler:           metricsMux,
		ReadHeaderTimeout: readTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
	}

	go func() {
		if err := metricsSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			// Losing metrics must not take the service down with it.
			slog.Error("metrics server stopped", "error", err)
		}
	}()
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		if err := metricsSrv.Shutdown(shutdownCtx); err != nil {
			slog.Warn("metrics server did not shut down cleanly", "error", err)
		}
	}()

	srv := &http.Server{
		Addr:    addr,
		Handler: instrument(m, mux),
		// Go's default server applies no timeouts at all, which leaves it open
		// to slow-client resource exhaustion. These are deliberately modest.
		ReadHeaderTimeout: readTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	return run(ctx, srv)
}

// run serves until ctx is cancelled, then drains in-flight requests.
//
// Kubernetes sends SIGTERM and waits terminationGracePeriodSeconds before
// SIGKILL. Draining rather than exiting immediately is what makes a rolling
// update invisible to callers.
//
// Cancellation arrives via ctx rather than being wired to signals internally,
// so the shutdown path is reachable from a test.
func run(ctx context.Context, srv *http.Server) error {
	errCh := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
			return
		}
		errCh <- nil
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		slog.Info("shutdown signal received, draining connections")
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}

// HelloServer greets the caller by the "name" parameter, or by source IP.
func HelloServer(w http.ResponseWriter, r *http.Request) {
	// ServeMux treats "/" as a catch-all prefix; keep 404s honest.
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}

	greetee, named := sanitizeName(r.URL.Query().Get("name"))
	if !named {
		greetee = GetIPFromRequest(r)
	}

	msg := fmt.Sprintf("Hello, %s! I'm %s", greetee, hostname())
	if tag := helloTag(); tag != "" {
		msg = fmt.Sprintf("%s (tag: %s)", msg, tag)
	}

	// Pin the content type and forbid sniffing: the response echoes caller
	// input, and without these a browser may interpret it as markup.
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")

	// #nosec G705 -- gosec taints msg because it derives from a query
	// parameter. Reflecting it is safe here and deliberately so: the response
	// is pinned to text/plain with nosniff, so no user agent will parse it as
	// markup; sanitizeName has already stripped control characters and capped
	// the length. Escaping for HTML would corrupt a plain-text payload rather
	// than protect it.
	if _, err := fmt.Fprintln(w, msg); err != nil {
		// The client hung up mid-write. There is no recovery and the status
		// line is already sent, but it should not pass silently.
		slog.Warn("failed to write greeting", "error", err)
		return
	}

	slog.Info("greeting served", "named", named, "path", r.URL.Path)
}

// HealthServer backs both the liveness and readiness probes.
//
// The service holds no downstream dependencies, so readiness and liveness are
// the same question. Splitting them would require a real dependency check.
func HealthServer(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)

	if _, err := fmt.Fprintln(w, "ok"); err != nil {
		slog.Warn("failed to write health response", "error", err)
	}
}

// sanitizeName bounds and cleans the caller-supplied greeting name. It reports
// whether a usable name survived.
func sanitizeName(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", false
	}

	// Strip control characters: they corrupt both the response and the
	// structured log line (CR/LF being the interesting ones for log forging).
	cleaned := strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, raw)

	cleaned = strings.TrimSpace(cleaned)
	if cleaned == "" {
		return "", false
	}

	if len([]rune(cleaned)) > maxNameLength {
		cleaned = string([]rune(cleaned)[:maxNameLength])
	}
	return cleaned, true
}

// GetIPFromRequest returns the caller's IP, preferring the X-Forwarded-For
// client entry when the service runs behind a load balancer.
func GetIPFromRequest(r *http.Request) string {
	// XFF is a comma-separated chain; the leftmost entry is the original
	// client. Downstream hops append, so the rightmost is the nearest proxy.
	if fwd := r.Header.Get("x-forwarded-for"); fwd != "" {
		if client, _, found := strings.Cut(fwd, ","); found {
			if client = strings.TrimSpace(client); client != "" {
				return client
			}
		} else if fwd = strings.TrimSpace(fwd); fwd != "" {
			return fwd
		}
	}

	// RemoteAddr carries a port; callers care about the host.
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

func port() string {
	if p := os.Getenv("PORT"); p != "" {
		return p
	}
	return defaultPort
}

func metricsPort() string {
	if p := os.Getenv("METRICS_PORT"); p != "" {
		return p
	}
	return defaultMetricsPort
}

// helloTag is the deployed release, reported in the greeting and as a
// build_info label so a scrape can be attributed to an exact image.
func helloTag() string {
	return os.Getenv("HELLO_TAG")
}

// hostname reports the pod name under Kubernetes, which is what makes the
// greeting useful for confirming traffic is spread across replicas.
func hostname() string {
	if h := os.Getenv("HOSTNAME"); h != "" {
		return h
	}
	if h, err := os.Hostname(); err == nil {
		return h
	}
	return "unknown"
}
