package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/dailycare-hq/dailycare-api/internal/logging"
)

type requestIDKey struct{}

// Every request gets an id, it goes into app.request_id, and the audit rows the request
// writes carry it. A reviewer asking "what else did that request touch" gets an answer
// rather than a timestamp and a guess.
func (a *API) withRequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := uuid.NewString()
		w.Header().Set("X-Request-Id", id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id)))
	})
}

func requestID(r *http.Request) string {
	if v, ok := r.Context().Value(requestIDKey{}).(string); ok {
		return v
	}
	return ""
}

func bearer(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(h) <= len(prefix) || h[:len(prefix)] != prefix {
		return "", false
	}
	return h[len(prefix):], true
}

// read decodes a JSON body and refuses anything odd about it.
//
// The body is capped and unknown fields are refused. Both are about the same thing: a
// handler that accepts whatever arrives is a handler whose behaviour is decided by the
// caller, and a typo'd field name that is silently ignored is a bug that looks like a
// working request.
func (a *API) read(w http.ResponseWriter, r *http.Request, into any) bool {
	dec := json.NewDecoder(io.LimitReader(r.Body, 64*1024))
	dec.DisallowUnknownFields()
	if err := dec.Decode(into); err != nil {
		a.fail(w, r, http.StatusBadRequest, "that request body was not what this endpoint expects", nil)
		return false
	}
	return true
}

func (a *API) ok(w http.ResponseWriter, r *http.Request, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		a.log.Error("a response would not encode",
			logging.F("request_id", requestID(r)), logging.F("error", err.Error()))
	}
}

// fail is the only way this package answers with an error, and the split is the point.
//
// What the caller gets is a sentence written here. What goes in the log is the underlying
// error, once, with the request id - so the two can be put together by somebody with
// access to both and by nobody else. A handler that returns the database's message tells
// an outsider which table exists, which constraint they tripped, and often the value that
// tripped it.
func (a *API) fail(w http.ResponseWriter, r *http.Request, status int, message string, err error) {
	if err != nil {
		a.log.Error("request failed",
			logging.F("request_id", requestID(r)),
			logging.F("status", status),
			logging.F("path", r.URL.Path),
			logging.F("error", err.Error()))
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{
		"error":     message,
		"requestId": requestID(r),
	})
}

// timeNow is here so a test can forge a token without importing time into its own file
// for one call. Not a seam for faking the clock: there is nothing in this package that
// should be reading it.
func timeNow() time.Time { return time.Now() }
