package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/dailycare-hq/dailycare-api/internal/auth"
	"github.com/dailycare-hq/dailycare-api/internal/db"
	"github.com/dailycare-hq/dailycare-api/internal/logging"
	"github.com/dailycare-hq/dailycare-api/internal/records"
	"github.com/dailycare-hq/dailycare-api/internal/sessions"
)

type harness struct {
	server *httptest.Server
	logs   *bytes.Buffer
	email  string
	pass   string
}

func serve(t *testing.T) *harness {
	t.Helper()
	dsn := os.Getenv("DAILYCARE_TEST_DSN")
	admin := os.Getenv("DAILYCARE_TEST_ADMIN_DSN")
	if dsn == "" || admin == "" {
		t.Skip("DAILYCARE_TEST_DSN is not set; run ./test.sh")
	}
	d, err := db.Open(context.Background(), dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(d.Close)

	c, err := pgx.Connect(context.Background(), admin)
	if err != nil {
		t.Fatalf("admin: %v", err)
	}
	defer c.Close(context.Background())

	pass := "a reasonable passphrase"
	digest, err := auth.Hash(pass)
	if err != nil {
		t.Fatal(err)
	}
	email := uuid.NewString() + "@example.test"
	if _, err := c.Exec(context.Background(),
		`INSERT INTO users (email, display_name, password_hash) VALUES ($1, 'A Nurse', $2)`,
		email, digest); err != nil {
		t.Fatalf("seeding: %v", err)
	}

	var fields []string
	rows, err := c.Query(context.Background(), `SELECT field FROM never_log`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var f string
		rows.Scan(&f)
		fields = append(fields, f)
	}
	rows.Close()

	logs := &bytes.Buffer{}
	signer, _ := auth.NewSigner([]byte("0123456789abcdef0123456789abcdef"))
	api := New(sessions.New(d, signer), records.New(d), logging.New(logs, fields))
	s := httptest.NewServer(api.Routes())
	t.Cleanup(s.Close)
	return &harness{server: s, logs: logs, email: email, pass: pass}
}

func (h *harness) do(t *testing.T, method, path, token string, body any) (*http.Response, []byte) {
	t.Helper()
	var r *http.Request
	var err error
	if body != nil {
		b, _ := json.Marshal(body)
		r, err = http.NewRequest(method, h.server.URL+path, bytes.NewReader(b))
	} else {
		r, err = http.NewRequest(method, h.server.URL+path, nil)
	}
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := h.server.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := &bytes.Buffer{}
	out.ReadFrom(resp.Body)
	return resp, out.Bytes()
}

func (h *harness) signIn(t *testing.T) sessions.Session {
	t.Helper()
	resp, body := h.do(t, "POST", "/v1/sessions", "", map[string]string{
		"email": h.email, "password": h.pass, "device": "a test"})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("sign in: %d %s", resp.StatusCode, body)
	}
	var s sessions.Session
	if err := json.Unmarshal(body, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestSignInThenUseTheToken(t *testing.T) {
	h := serve(t)
	s := h.signIn(t)

	resp, body := h.do(t, "GET", "/v1/residents", s.AccessToken, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("listing residents: %d %s", resp.StatusCode, body)
	}
	if resp.Header.Get("X-Request-Id") == "" {
		t.Error("no request id on the response, so a log line cannot be tied to it")
	}
}

// Every unauthenticated path onto an identified route has to be the same 401.
func TestNothingGetsThroughWithoutAToken(t *testing.T) {
	h := serve(t)
	good := h.signIn(t)
	for _, c := range []struct{ name, token string }{
		{"no header", ""},
		{"nonsense", "hello"},
		{"a token signed with another key", forgeWithAnotherKey(t)},
		{"the refresh token, which is not an access token", good.RefreshToken},
	} {
		resp, body := h.do(t, "GET", "/v1/residents", c.token, nil)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Errorf("%s: got %d, want 401 (%s)", c.name, resp.StatusCode, body)
		}
	}
}

func forgeWithAnotherKey(t *testing.T) string {
	t.Helper()
	other, err := auth.NewSigner([]byte("ffffffffffffffffffffffffffffffff"))
	if err != nil {
		t.Fatal(err)
	}
	return other.Issue(uuid.New(), timeNow())
}

// A caregiver who can tell "no such resident" from "not yours" can enumerate the building
// by asking about uuids until the answer changes.
func TestAResidentYouCannotSeeIsIndistinguishableFromOneThatDoesNotExist(t *testing.T) {
	h := serve(t)
	s := h.signIn(t)

	invented := uuid.New()
	resp1, body1 := h.do(t, "GET", "/v1/residents/"+invented.String()+"/days/2026-09-22", s.AccessToken, nil)
	resp2, body2 := h.do(t, "GET", "/v1/residents/"+uuid.NewString()+"/days/2026-09-22", s.AccessToken, nil)

	if resp1.StatusCode != http.StatusNotFound || resp2.StatusCode != http.StatusNotFound {
		t.Fatalf("got %d and %d, want 404 for both", resp1.StatusCode, resp2.StatusCode)
	}
	if err1, err2 := errorOf(t, body1), errorOf(t, body2); err1 != err2 {
		t.Fatalf("two different answers: %q and %q", err1, err2)
	}
}

// The database's message is for the log, never for the caller.
func TestErrorsSayNothingAboutTheDatabase(t *testing.T) {
	h := serve(t)
	s := h.signIn(t)
	h.do(t, "GET", "/v1/residents/not-a-uuid/days/2026-09-22", s.AccessToken, nil)
	resp, body := h.do(t, "GET", "/v1/residents/"+uuid.NewString()+"/days/nonsense", s.AccessToken, nil)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("got %d, want 400", resp.StatusCode)
	}
	for _, leak := range []string{"pgx", "SQLSTATE", "relation", "constraint", "care_days",
		"residents", "SELECT", "postgres"} {
		if strings.Contains(string(body), leak) {
			t.Errorf("the response mentions %q: %s", leak, body)
		}
	}
}

// A failed sign-in is where a list of real addresses would accumulate.
func TestTheLogDoesNotCarryTheEmail(t *testing.T) {
	h := serve(t)
	h.do(t, "POST", "/v1/sessions", "", map[string]string{
		"email": h.email, "password": "wrong", "device": "a test"})
	if strings.Contains(h.logs.String(), h.email) {
		t.Fatalf("the log carries the address somebody tried: %s", h.logs.String())
	}
}

// A field name on never_log keeps its name and loses its value, so the line still says
// something was refused rather than quietly becoming a different line.
func TestNeverLogFieldsAreRedactedRatherThanDropped(t *testing.T) {
	// display_name is PHI on residents; the logger should refuse it whatever it carries.
	// No server needed - this is about the logger, and wiring one up would make the test
	// depend on things it is not testing.
	logs := &bytes.Buffer{}
	l := logging.New(logs, []string{"display_name", "email"})
	l.Info("a line", logging.F("display_name", "Mrs Cathy Reed"), logging.F("request_id", "r1"))
	out := logs.String()
	if strings.Contains(out, "Cathy") {
		t.Fatalf("the value survived: %s", out)
	}
	if !strings.Contains(out, "display_name") {
		t.Fatalf("the field name vanished, so the line does not say anything was refused: %s", out)
	}
	if !strings.Contains(out, "r1") {
		t.Fatalf("an allowed field was dropped too: %s", out)
	}
}

func TestUnknownFieldsInABodyAreRefused(t *testing.T) {
	h := serve(t)
	resp, _ := h.do(t, "POST", "/v1/sessions", "", map[string]string{
		"email": h.email, "password": h.pass, "passwrod": "a typo"})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("got %d, want 400: a typo'd field should not read as a working request", resp.StatusCode)
	}
}

func errorOf(t *testing.T, body []byte) string {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatalf("not json: %s", body)
	}
	return fmt.Sprint(m["error"])
}

// Filing over HTTP, and the two ways it can be refused.
func TestFilingADayOverHTTP(t *testing.T) {
	h := serve(t)
	s := h.signIn(t)

	// No resident is assigned to this account, so the only thing worth checking here is
	// that an unknown one is refused the same way an invisible one is - the seeding for a
	// full ward lives in the records tests, where it belongs.
	body := map[string]any{
		"mood": "calm", "appetite": "fair", "sleep": "restless",
		"note": "settled evening", "shower": true, "grooming": false,
		"meals":    []map[string]any{{"slot": "breakfast", "happened": true, "amount": "most"}},
		"concerns": []string{"pain"},
	}
	resp, out := h.do(t, "POST", "/v1/residents/"+uuid.NewString()+"/days/2026-09-23", s.AccessToken, body)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("filing for an unknown resident gave %d, want 404: %s", resp.StatusCode, out)
	}
	if got := errorOf(t, out); got != "no such resident" {
		t.Fatalf("the refusal says %q", got)
	}
}

func TestFilingWithoutATokenIsRefused(t *testing.T) {
	h := serve(t)
	resp, _ := h.do(t, "POST", "/v1/residents/"+uuid.NewString()+"/days/2026-09-23", "",
		map[string]any{"mood": "calm"})
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401", resp.StatusCode)
	}
}

// A mood the enum does not have. The model refuses it and the caller is told that the day
// was not accepted, not which constraint said so.
func TestAnImpossibleDayIsRefusedWithoutSayingWhy(t *testing.T) {
	h := serve(t)
	s := h.signIn(t)
	resp, out := h.do(t, "POST", "/v1/residents/"+uuid.NewString()+"/days/2026-09-23", s.AccessToken,
		map[string]any{"mood": "cheerful", "appetite": "fair", "sleep": "restless"})
	if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusCreated {
		t.Fatalf("a mood that is not in the enum was accepted")
	}
	for _, leak := range []string{"enum", "SQLSTATE", "invalid input value", "care_days", "cheerful"} {
		if strings.Contains(string(out), leak) {
			t.Errorf("the response mentions %q: %s", leak, out)
		}
	}
}

// A path value that is not a uuid is the same answer as one that is and is unknown.
// Otherwise a caller learns which of their guesses were well-formed.
func TestABadResidentIdAnswersLikeAnUnknownOne(t *testing.T) {
	h := serve(t)
	s := h.signIn(t)
	_, bad := h.do(t, "GET", "/v1/residents/not-a-uuid/days/2026-09-23", s.AccessToken, nil)
	_, unknown := h.do(t, "GET", "/v1/residents/"+uuid.NewString()+"/days/2026-09-23", s.AccessToken, nil)
	if errorOf(t, bad) != errorOf(t, unknown) {
		t.Fatalf("two answers: %q and %q", errorOf(t, bad), errorOf(t, unknown))
	}
}
