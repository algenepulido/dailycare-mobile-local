// Package httpapi is the surface. Everything it does that matters happens somewhere else:
// the database decides who may read a resident, internal/records records that they did,
// and internal/sessions decides whose uuid this request is carrying.
//
// What is here is the part that is easy to get wrong in an HTTP layer specifically -
// telling a caller more than they asked for. Errors are the usual route: a handler that
// returns the database's message tells an outsider which table exists and which constraint
// they tripped, and one that distinguishes "no such resident" from "not yours" answers a
// question nobody should be able to ask.
package httpapi

import (
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/dailycare-hq/dailycare-api/internal/db"
	"github.com/dailycare-hq/dailycare-api/internal/logging"
	"github.com/dailycare-hq/dailycare-api/internal/records"
	"github.com/dailycare-hq/dailycare-api/internal/sessions"
)

type API struct {
	sessions *sessions.Store
	records  *records.Store
	log      *logging.Logger
}

func New(s *sessions.Store, r *records.Store, l *logging.Logger) *API {
	return &API{sessions: s, records: r, log: l}
}

func (a *API) Routes() http.Handler {
	mux := http.NewServeMux()

	// Unauthenticated, and only these three. Everything else goes through identified.
	mux.HandleFunc("POST /v1/sessions", a.signIn)
	mux.HandleFunc("POST /v1/sessions/refresh", a.refresh)
	mux.HandleFunc("DELETE /v1/sessions", a.signOut)

	mux.Handle("DELETE /v1/sessions/all", a.identified(a.signOutEverywhere))
	mux.Handle("GET /v1/residents", a.identified(a.listResidents))
	mux.Handle("GET /v1/residents/{id}/days/{date}", a.identified(a.careDay))

	// POST rather than PUT, and the difference is the point. A second one is not a replay
	// that should be swallowed; it is a correction, and the database records it as a new
	// row pointing back at what it corrected.
	mux.Handle("POST /v1/residents/{id}/days/{date}", a.identified(a.fileDay))

	// No identity and nothing about the system: a health check that reported the database
	// version or the migration state would be a free map for anybody who found the port.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok\n"))
	})

	return a.withRequestID(mux)
}

type callerKey struct{}

// identified refuses anything without a verifiable access token, before the handler runs.
// A handler that has to remember to check is a handler that will one day not.
func (a *API) identified(h func(http.ResponseWriter, *http.Request, db.Caller)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearer(r)
		if !ok {
			a.fail(w, r, http.StatusUnauthorized, "not signed in", nil)
			return
		}
		caller, err := a.sessions.Identify(token, requestID(r))
		if err != nil {
			// Expired and forged are the same answer. The client's move is identical -
			// refresh, then sign in - and telling the difference to somebody holding a
			// forgery tells them the forgery was well-formed.
			a.fail(w, r, http.StatusUnauthorized, "not signed in", nil)
			return
		}
		h(w, r, caller)
	})
}

func (a *API) signIn(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Email    string `json:"email"`
		Password string `json:"password"`
		Device   string `json:"device"`
	}
	if !a.read(w, r, &body) {
		return
	}
	s, err := a.sessions.SignIn(r.Context(), body.Email, body.Password, body.Device)
	if err != nil {
		if errors.Is(err, sessions.ErrSignInFailed) {
			// The email is not logged. It identifies a person, never_log says so, and a
			// failed sign-in is exactly where a list of real addresses would accumulate.
			a.log.Info("sign-in refused", logging.F("request_id", requestID(r)))
			a.fail(w, r, http.StatusUnauthorized, "that email and password do not match an account", nil)
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not sign in", err)
		return
	}
	a.ok(w, r, http.StatusCreated, s)
}

func (a *API) refresh(w http.ResponseWriter, r *http.Request) {
	var body struct {
		RefreshToken string `json:"refreshToken"`
	}
	if !a.read(w, r, &body) {
		return
	}
	s, err := a.sessions.Refresh(r.Context(), body.RefreshToken)
	if err != nil {
		if errors.Is(err, sessions.ErrSignInFailed) {
			a.fail(w, r, http.StatusUnauthorized, "sign in again", nil)
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not refresh", err)
		return
	}
	a.ok(w, r, http.StatusOK, s)
}

func (a *API) signOut(w http.ResponseWriter, r *http.Request) {
	var body struct {
		RefreshToken string `json:"refreshToken"`
	}
	if !a.read(w, r, &body) {
		return
	}
	// No access token needed and none asked for. A caregiver whose token expired while
	// the phone was in a pocket still gets to end the session, and the refresh token is
	// the authorisation - the database checks it.
	if err := a.sessions.SignOut(r.Context(), body.RefreshToken); err != nil {
		a.fail(w, r, http.StatusInternalServerError, "could not sign out", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) signOutEverywhere(w http.ResponseWriter, r *http.Request, c db.Caller) {
	n, err := a.sessions.SignOutEverywhere(r.Context(), c)
	if err != nil {
		a.fail(w, r, http.StatusInternalServerError, "could not sign out", err)
		return
	}
	a.ok(w, r, http.StatusOK, map[string]int{"sessionsEnded": n})
}

func (a *API) listResidents(w http.ResponseWriter, r *http.Request, c db.Caller) {
	list, err := a.records.Residents(r.Context(), c)
	if err != nil {
		a.fail(w, r, http.StatusInternalServerError, "could not list residents", err)
		return
	}
	if list == nil {
		list = []records.Resident{}
	}
	a.ok(w, r, http.StatusOK, list)
}

func (a *API) fileDay(w http.ResponseWriter, r *http.Request, c db.Caller) {
	id, on, ok := a.residentAndDate(w, r)
	if !ok {
		return
	}
	var filing records.Filing
	if !a.read(w, r, &filing) {
		return
	}
	filed, err := a.records.File(r.Context(), c, id, on, filing)
	if err != nil {
		if errors.Is(err, records.ErrNotVisible) {
			a.fail(w, r, http.StatusNotFound, "no such resident", nil)
			return
		}
		// A mood the enum does not have, a meal slot that is not a meal, an amount
		// without the meal. All of them are the caller sending something the model
		// refuses, and the model's message is not the caller's business.
		a.fail(w, r, http.StatusBadRequest, "that day was not something the record accepts", err)
		return
	}
	a.ok(w, r, http.StatusCreated, map[string]string{"careDayId": filed.String()})
}

func (a *API) careDay(w http.ResponseWriter, r *http.Request, c db.Caller) {
	id, on, ok := a.residentAndDate(w, r)
	if !ok {
		return
	}
	day, err := a.records.Day(r.Context(), c, id, on)
	if err != nil {
		if errors.Is(err, records.ErrNotVisible) {
			// Not "you may not see this resident". A caregiver who can tell the two apart
			// can enumerate the building by asking about uuids.
			a.fail(w, r, http.StatusNotFound, "no such resident", nil)
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not read the day", err)
		return
	}
	a.ok(w, r, http.StatusOK, day)
}

// Both day handlers take the same two path values, and a resident id that is not a uuid
// is answered the same way as one that is: a 404 saying no such resident. Telling a caller
// that their uuid was well-formed but unknown is half of an enumeration oracle.
func (a *API) residentAndDate(w http.ResponseWriter, r *http.Request) (uuid.UUID, time.Time, bool) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		a.fail(w, r, http.StatusNotFound, "no such resident", nil)
		return uuid.Nil, time.Time{}, false
	}
	on, err := time.Parse("2006-01-02", r.PathValue("date"))
	if err != nil {
		a.fail(w, r, http.StatusBadRequest, "the date should look like 2026-09-23", nil)
		return uuid.Nil, time.Time{}, false
	}
	return id, on, true
}
