package main

import (
	"bytes"
	"fmt"
	"log/slog"
	"net/http"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"time"
)

// Prometheus exposition, written against the standard library only.
//
// The obvious move is prometheus/client_golang, and it is the wrong one here.
// It pulls roughly eight transitive modules into a service that currently has
// zero, which costs the empty `go.mod`, the CVE surface of a dependency tree
// this binary does not otherwise carry, and some of the image size that makes
// FROM scratch worth doing. The text exposition format is a few lines of
// printing; the library earns its keep on richer instrumentation than a
// greeter needs.
//
// Served on a separate port so it is never reachable through the Ingress. The
// ALB routes only to the application port, and the NetworkPolicy admits the
// metrics port from inside the namespace alone.

// Buckets in seconds. Tightly packed at the bottom because the service does no
// I/O — a request that takes longer than a few milliseconds is already
// interesting, and one over a second is pathological.
var durationBuckets = []float64{0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.1, 0.5, 1}

type metrics struct {
	mu sync.Mutex

	// Requests by HTTP status code.
	requests map[int]uint64

	// Cumulative histogram state for request duration.
	bucketCounts []uint64
	durationSum  float64
	durationObs  uint64

	startedAt time.Time
}

func newMetrics(started time.Time) *metrics {
	return &metrics{
		requests:     make(map[int]uint64),
		bucketCounts: make([]uint64, len(durationBuckets)),
		startedAt:    started,
	}
}

// observe records one completed request.
func (m *metrics) observe(status int, d time.Duration) {
	secs := d.Seconds()

	m.mu.Lock()
	defer m.mu.Unlock()

	m.requests[status]++
	m.durationSum += secs
	m.durationObs++

	// Cumulative buckets: an observation counts in its own bucket and every
	// wider one, which is what Prometheus' le semantics require.
	for i, upper := range durationBuckets {
		if secs <= upper {
			m.bucketCounts[i]++
		}
	}
}

// ServeHTTP writes the Prometheus text exposition format.
func (m *metrics) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	m.mu.Lock()
	requests := make(map[int]uint64, len(m.requests))
	for k, v := range m.requests {
		requests[k] = v
	}
	buckets := append([]uint64(nil), m.bucketCounts...)
	sum, obs, started := m.durationSum, m.durationObs, m.startedAt
	m.mu.Unlock()

	// Rendered into a buffer and written once. A scrape that fails halfway
	// leaves Prometheus parsing a truncated exposition, which it reports as a
	// malformed metric rather than a failed scrape — a confusing way to lose
	// monitoring. One write also gives an accurate Content-Length.
	var b bytes.Buffer

	// Status codes are sorted so the output is byte-stable between scrapes;
	// unstable ordering makes diffing a scrape needlessly painful.
	codes := make([]int, 0, len(requests))
	for c := range requests {
		codes = append(codes, c)
	}
	sort.Ints(codes)

	fmt.Fprintln(&b, "# HELP greeter_requests_total Requests handled, by HTTP status code.")
	fmt.Fprintln(&b, "# TYPE greeter_requests_total counter")
	for _, c := range codes {
		fmt.Fprintf(&b, "greeter_requests_total{status=\"%d\"} %d\n", c, requests[c])
	}

	fmt.Fprintln(&b, "# HELP greeter_request_duration_seconds Request latency.")
	fmt.Fprintln(&b, "# TYPE greeter_request_duration_seconds histogram")
	var cumulative uint64
	for i, upper := range durationBuckets {
		cumulative = buckets[i]
		fmt.Fprintf(&b, "greeter_request_duration_seconds_bucket{le=\"%s\"} %d\n",
			strconv.FormatFloat(upper, 'g', -1, 64), cumulative)
	}
	// +Inf must equal the total observation count, or the histogram is invalid.
	fmt.Fprintf(&b, "greeter_request_duration_seconds_bucket{le=\"+Inf\"} %d\n", obs)
	fmt.Fprintf(&b, "greeter_request_duration_seconds_sum %s\n", strconv.FormatFloat(sum, 'g', -1, 64))
	fmt.Fprintf(&b, "greeter_request_duration_seconds_count %d\n", obs)

	fmt.Fprintln(&b, "# HELP greeter_build_info Deployed release, always 1.")
	fmt.Fprintln(&b, "# TYPE greeter_build_info gauge")
	fmt.Fprintf(&b, "greeter_build_info{tag=\"%s\"} 1\n", helloTag())

	fmt.Fprintln(&b, "# HELP greeter_uptime_seconds Seconds since process start.")
	fmt.Fprintln(&b, "# TYPE greeter_uptime_seconds gauge")
	fmt.Fprintf(&b, "greeter_uptime_seconds %s\n",
		strconv.FormatFloat(time.Since(started).Seconds(), 'f', 3, 64))

	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)

	fmt.Fprintln(&b, "# HELP go_goroutines Goroutines currently running.")
	fmt.Fprintln(&b, "# TYPE go_goroutines gauge")
	fmt.Fprintf(&b, "go_goroutines %d\n", runtime.NumGoroutine())

	fmt.Fprintln(&b, "# HELP go_memstats_alloc_bytes Heap bytes allocated and in use.")
	fmt.Fprintln(&b, "# TYPE go_memstats_alloc_bytes gauge")
	fmt.Fprintf(&b, "go_memstats_alloc_bytes %d\n", ms.Alloc)

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	if _, err := w.Write(b.Bytes()); err != nil {
		slog.Warn("failed to write metrics response", "error", err)
	}
}

// statusRecorder captures the status code, which http.ResponseWriter does not
// otherwise expose to middleware.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(p []byte) (int, error) {
	// A handler that writes without calling WriteHeader has implicitly sent 200.
	if r.status == 0 {
		r.status = http.StatusOK
	}
	return r.ResponseWriter.Write(p)
}

// instrument wraps a handler so every request is observed.
func instrument(m *metrics, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w}

		next.ServeHTTP(rec, r)

		if rec.status == 0 {
			rec.status = http.StatusOK
		}
		m.observe(rec.status, time.Since(start))
	})
}
