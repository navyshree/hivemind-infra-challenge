package main

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

func scrape(t *testing.T, m *metrics) string {
	t.Helper()

	rec := httptest.NewRecorder()
	m.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/metrics", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	return rec.Body.String()
}

func metricValue(t *testing.T, body, name string) float64 {
	t.Helper()

	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == name {
			v, err := strconv.ParseFloat(fields[1], 64)
			if err != nil {
				t.Fatalf("value of %s is not a number: %q", name, fields[1])
			}
			return v
		}
	}
	t.Fatalf("metric %q not found in:\n%s", name, body)
	return 0
}

func TestMetricsExposesPrometheusContentType(t *testing.T) {
	m := newMetrics(time.Now())

	rec := httptest.NewRecorder()
	m.ServeHTTP(rec, httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/metrics", nil))

	// Prometheus keys its parser off this; getting it wrong makes a scrape fail
	// in a way that looks like the endpoint is down.
	if got, want := rec.Header().Get("Content-Type"), "text/plain; version=0.0.4; charset=utf-8"; got != want {
		t.Errorf("Content-Type = %q, want %q", got, want)
	}
}

func TestMetricsCountsRequestsByStatus(t *testing.T) {
	m := newMetrics(time.Now())
	m.observe(200, time.Millisecond)
	m.observe(200, time.Millisecond)
	m.observe(404, time.Millisecond)

	body := scrape(t, m)

	if got := metricValue(t, body, `greeter_requests_total{status="200"}`); got != 2 {
		t.Errorf("200 count = %v, want 2", got)
	}
	if got := metricValue(t, body, `greeter_requests_total{status="404"}`); got != 1 {
		t.Errorf("404 count = %v, want 1", got)
	}
}

func TestHistogramInfBucketEqualsObservationCount(t *testing.T) {
	m := newMetrics(time.Now())
	// One observation deliberately beyond the widest bucket.
	for _, d := range []time.Duration{time.Microsecond, time.Millisecond, 5 * time.Second} {
		m.observe(200, d)
	}

	body := scrape(t, m)

	inf := metricValue(t, body, `greeter_request_duration_seconds_bucket{le="+Inf"}`)
	count := metricValue(t, body, "greeter_request_duration_seconds_count")

	// A histogram whose +Inf bucket disagrees with its count is invalid and
	// Prometheus will reject or mis-render it.
	if inf != count {
		t.Errorf("+Inf bucket = %v but count = %v; they must be equal", inf, count)
	}
	if count != 3 {
		t.Errorf("count = %v, want 3", count)
	}
}

func TestHistogramBucketsAreCumulative(t *testing.T) {
	m := newMetrics(time.Now())
	m.observe(200, 750*time.Microsecond) // falls in the 0.001 bucket and every wider one

	body := scrape(t, m)

	re := regexp.MustCompile(`greeter_request_duration_seconds_bucket\{le="([^"+]+)"\} (\d+)`)
	var prev int64 = -1
	for _, match := range re.FindAllStringSubmatch(body, -1) {
		v, err := strconv.ParseInt(match[2], 10, 64)
		if err != nil {
			t.Fatalf("bucket %s has non-integer value %q", match[1], match[2])
		}
		// Cumulative means each bucket is >= the one below it.
		if v < prev {
			t.Errorf("bucket le=%s has %d, less than the previous bucket's %d", match[1], v, prev)
		}
		prev = v
	}
	if prev < 1 {
		t.Error("no bucket captured the observation")
	}
}

func TestMetricsReportsBuildTagAndUptime(t *testing.T) {
	t.Setenv("HELLO_TAG", "sha-deadbeef")

	body := scrape(t, newMetrics(time.Now().Add(-90*time.Second)))

	if !strings.Contains(body, `greeter_build_info{tag="sha-deadbeef"} 1`) {
		t.Errorf("build_info missing or wrong tag:\n%s", body)
	}
	if got := metricValue(t, body, "greeter_uptime_seconds"); got < 89 || got > 120 {
		t.Errorf("uptime = %v, want roughly 90", got)
	}
}

func TestInstrumentRecordsTheHandlersStatus(t *testing.T) {
	m := newMetrics(time.Now())
	h := instrument(m, http.HandlerFunc(HelloServer))

	// "/" succeeds; an unknown path 404s. Both must be counted under their own
	// status, which means the wrapper has to see the code the handler wrote.
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/?name=Ada", nil))
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/nope", nil))

	body := scrape(t, m)

	if got := metricValue(t, body, `greeter_requests_total{status="200"}`); got != 1 {
		t.Errorf("200 count = %v, want 1", got)
	}
	if got := metricValue(t, body, `greeter_requests_total{status="404"}`); got != 1 {
		t.Errorf("404 count = %v, want 1", got)
	}
}

func TestInstrumentDefaultsToOKWhenHandlerNeverSetsAStatus(t *testing.T) {
	m := newMetrics(time.Now())
	// A handler that only writes has implicitly sent 200; recording it as 0
	// would produce a nonsense label.
	h := instrument(m, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("hi")) //nolint:errcheck // test handler
	}))

	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequestWithContext(t.Context(), http.MethodGet, "/", nil))

	if got := metricValue(t, scrape(t, m), `greeter_requests_total{status="200"}`); got != 1 {
		t.Errorf("200 count = %v, want 1", got)
	}
}

func TestMetricsPortDefaultsAndOverrides(t *testing.T) {
	t.Setenv("METRICS_PORT", "")
	if got, want := metricsPort(), defaultMetricsPort; got != want {
		t.Errorf("metricsPort() = %q, want %q", got, want)
	}

	t.Setenv("METRICS_PORT", "9999")
	if got, want := metricsPort(), "9999"; got != want {
		t.Errorf("metricsPort() = %q, want %q", got, want)
	}
}

func TestMetricsIsSafeUnderConcurrentObservation(t *testing.T) {
	m := newMetrics(time.Now())

	done := make(chan struct{})
	for range 8 {
		go func() {
			for range 100 {
				m.observe(200, time.Millisecond)
			}
			done <- struct{}{}
		}()
	}
	for range 8 {
		<-done
	}

	// Run with -race; this asserts nothing was lost to a data race.
	if got := metricValue(t, scrape(t, m), `greeter_requests_total{status="200"}`); got != 800 {
		t.Errorf("count = %v, want 800", got)
	}
}
