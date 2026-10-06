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

	"github.com/dailycare-hq/dailycare-api/internal/auth"
	"github.com/dailycare-hq/dailycare-api/internal/db"
	"github.com/dailycare-hq/dailycare-api/internal/facility"
	"github.com/dailycare-hq/dailycare-api/internal/logging"
	"github.com/dailycare-hq/dailycare-api/internal/media"
	"github.com/dailycare-hq/dailycare-api/internal/records"
	"github.com/dailycare-hq/dailycare-api/internal/sessions"
)

type API struct {
	sessions *sessions.Store
	records  *records.Store
	facility *facility.Store
	// Nil when the process has no Cloud Storage to sign against, which is how it runs on
	// a laptop. The route still exists and says so rather than disappearing, because an
	// endpoint that is absent in one environment and present in another is a difference
	// nobody notices until a client is written against the wrong one.
	media *media.Store
	log   *logging.Logger
}

func New(s *sessions.Store, r *records.Store, f *facility.Store, m *media.Store, l *logging.Logger) *API {
	return &API{sessions: s, records: r, facility: f, media: m, log: l}
}

func (a *API) Routes() http.Handler {
	mux := http.NewServeMux()

	// Unauthenticated, and only these three. Everything else goes through identified.
	mux.HandleFunc("POST /v1/sessions", a.signIn)
	mux.HandleFunc("POST /v1/sessions/refresh", a.refresh)

	// Unauthenticated on purpose: this is how somebody who has never signed in gets a
	// password, and how somebody who has lost theirs gets another. The link is the
	// credential, it is single-use, and it is checked in one statement in the database.
	mux.HandleFunc("POST /v1/credentials", a.redeem)
	mux.HandleFunc("DELETE /v1/sessions", a.signOut)

	mux.Handle("DELETE /v1/sessions/all", a.identified(a.signOutEverywhere))

	// Which face of the app belongs to the person holding this session. Asked on launch,
	// because the alternative is the app deciding for itself and a family member seeing a
	// filing form for the moment before it corrects itself.
	mux.Handle("GET /v1/me", a.identified(a.me))

	mux.Handle("GET /v1/residents", a.identified(a.listResidents))
	mux.Handle("GET /v1/residents/{id}/trail", a.identified(a.trail))
	mux.Handle("GET /v1/residents/{id}/days", a.identified(a.history))
	mux.Handle("GET /v1/residents/{id}/days/{date}/history", a.identified(a.dayHistory))
	mux.Handle("GET /v1/residents/{id}/days/{date}", a.identified(a.careDay))

	// POST rather than PUT, and the difference is the point. A second one is not a replay
	// that should be swallowed; it is a correction, and the database records it as a new
	// row pointing back at what it corrected.
	mux.Handle("POST /v1/residents/{id}/days/{date}", a.identified(a.fileDay))

	// Somewhere to put a photograph. The photograph itself never comes through here - the
	// app uploads to Cloud Storage with the URL this returns, so a care photo is not in
	// this process's memory, its logs, or anything's buffers on the way past.
	mux.Handle("POST /v1/residents/{id}/photos", a.identified(a.offerPhoto))

	// The upload happened. Until this arrives the row is a place that was offered, not a
	// photograph - media_never_arrived is the list of ones that never came.
	mux.Handle("POST /v1/photos/{objectId}/arrived", a.identified(a.photoArrived))

	// Separate from the day itself, and called only when somebody is about to look. Every
	// link here costs a signing call and cannot be withdrawn once minted, so a day read
	// that produced them whether or not anybody opened a photograph would be handing out
	// links nobody asked for.
	mux.Handle("GET /v1/residents/{id}/days/{date}/photos", a.identified(a.dayPhotos))

	// Administering a building. Every one of these is refused by the database for a
	// facility the caller does not manage, so what is here is the translation and not the
	// decision - which is the whole of what milestone five moves out of the terminal.
	mux.Handle("GET /v1/facilities/{id}/members", a.identified(a.listMembers))
	mux.Handle("POST /v1/facilities/{id}/members", a.identified(a.inviteMember))
	mux.Handle("DELETE /v1/members/{id}", a.identified(a.endMembership))

	// /healthz is not ours to use. Cloud Run's frontend answers it before a request
	// reaches the container, with an HTML 404 - so a probe against a deployed service
	// tests Google's load balancer and reports the service as broken. Found by deploying
	// and curling it.
	//
	// No identity and nothing about the system: a health check that reported the database
	// version or the migration state would be a free map for anybody who found the port.
	mux.HandleFunc("GET /v1/health", func(w http.ResponseWriter, r *http.Request) {
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

// Accepting an invitation or a reset link.
func (a *API) redeem(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Link     string `json:"link"`
		Password string `json:"password"`
		Device   string `json:"device"`
	}
	if !a.read(w, r, &body) {
		return
	}
	session, err := a.sessions.Redeem(r.Context(), body.Link, body.Password, body.Device)
	switch {
	case errors.Is(err, auth.ErrPasswordTooShort):
		// The one refusal here that is worth spelling out. Everything else about a link
		// is deliberately one answer.
		a.fail(w, r, http.StatusBadRequest, err.Error(), nil)
		return
	case errors.Is(err, sessions.ErrAccountNotActive):
		a.fail(w, r, http.StatusForbidden,
			"that account is not active. The link has not been used", nil)
		return
	case errors.Is(err, sessions.ErrLinkNotUsable):
		// Never used, already used, expired, or invented: one answer, because a caller
		// who can tell them apart can test links.
		a.fail(w, r, http.StatusUnauthorized, "that link cannot be used", nil)
		return
	case err != nil:
		a.fail(w, r, http.StatusInternalServerError, "could not set that password", err)
		return
	}
	a.ok(w, r, http.StatusCreated, session)
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

func (a *API) me(w http.ResponseWriter, r *http.Request, c db.Caller) {
	account, err := a.sessions.Account(r.Context(), c)
	if err != nil {
		if errors.Is(err, sessions.ErrSignInFailed) {
			// A valid token for an account this database does not have. 401 rather than
			// 500: the client's move is to sign in again, and nothing here is broken.
			a.fail(w, r, http.StatusUnauthorized, "not signed in", nil)
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not read this account", err)
		return
	}
	a.ok(w, r, http.StatusOK, account)
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

func (a *API) offerPhoto(w http.ResponseWriter, r *http.Request, c db.Caller) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		a.fail(w, r, http.StatusNotFound, "no such resident", nil)
		return
	}
	var body struct {
		ContentType string     `json:"contentType"`
		ByteSize    int64      `json:"byteSize"`
		CareDayID   *uuid.UUID `json:"careDayId,omitempty"`
	}
	if !a.read(w, r, &body) {
		return
	}
	if a.media == nil {
		// Running without Cloud Storage configured, which is how the API runs locally.
		// Said plainly rather than as a 500, because a caregiver seeing this is looking at
		// a deployment that is not finished rather than at something broken.
		a.fail(w, r, http.StatusServiceUnavailable, "photographs are not set up on this server", nil)
		return
	}
	up, err := a.media.Offer(r.Context(), c, id, body.CareDayID, body.ContentType, body.ByteSize)
	if err != nil {
		if errors.Is(err, media.ErrNotVisible) {
			a.fail(w, r, http.StatusNotFound, "no such resident", nil)
			return
		}
		a.fail(w, r, http.StatusBadRequest, "that is not a photograph this takes", err)
		return
	}
	a.ok(w, r, http.StatusCreated, up)
}

func (a *API) dayPhotos(w http.ResponseWriter, r *http.Request, c db.Caller) {
	if a.media == nil {
		a.fail(w, r, http.StatusServiceUnavailable, "photographs are not set up on this server", nil)
		return
	}
	id, on, ok := a.residentAndDate(w, r)
	if !ok {
		return
	}
	photos, err := a.media.ForDay(r.Context(), c, id, on)
	if err != nil {
		// The same answer the day itself gives, because it is the same refusal. This
		// returned 500 for a resident the session may not read, which is wrong twice:
		// a refusal is not a failure, and answering 404 for the day and 500 for its
		// photographs tells a caller the resident is there. Found by reading a day as a
		// family member and then asking for the photographs of one they hold no grant for.
		if errors.Is(err, media.ErrNotVisible) {
			a.fail(w, r, http.StatusNotFound, "no such resident", nil)
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not read the photographs", err)
		return
	}
	a.ok(w, r, http.StatusOK, photos)
}

func (a *API) photoArrived(w http.ResponseWriter, r *http.Request, c db.Caller) {
	if a.media == nil {
		a.fail(w, r, http.StatusServiceUnavailable, "photographs are not set up on this server", nil)
		return
	}
	id, err := uuid.Parse(r.PathValue("objectId"))
	if err != nil {
		a.fail(w, r, http.StatusNotFound, "no such photograph", nil)
		return
	}
	if err := a.media.Arrived(r.Context(), c, id); err != nil {
		a.fail(w, r, http.StatusNotFound, "no such photograph", nil)
		return
	}
	w.WriteHeader(http.StatusNoContent)
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
		// Somebody who may read this record and not write to it, which is what a family
		// member is. 403 and not 404: they have just been served this resident's days, so
		// hiding the resident at this point would contradict the answer before it. And not
		// 400, which is what this was until M4 - a family member filing a day was told
		// their data was malformed, when the database had refused them by policy and said
		// so plainly in the log.
		if errors.Is(err, records.ErrNotTheirsToFile) {
			a.fail(w, r, http.StatusForbidden, "only the care team can record a day", nil)
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

// trail is who opened this resident's record: GET .../trail?from=&to=
//
// A caregiver gets 403 rather than an empty list. The list would be empty - the policy on
// the table sees to that - but empty reads as "nobody has opened it", and that is a
// different statement from "this is not yours to ask". 404 is wrong here too: they can see
// the resident, so pretending otherwise would be a lie in the other direction.
func (a *API) trail(w http.ResponseWriter, r *http.Request, c db.Caller) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		a.fail(w, r, http.StatusNotFound, "no such resident", nil)
		return
	}
	to := time.Now().UTC().Add(24 * time.Hour)
	from := to.AddDate(0, 0, -91)
	if v := r.URL.Query().Get("from"); v != "" {
		if from, err = time.Parse("2006-01-02", v); err != nil {
			a.fail(w, r, http.StatusBadRequest, "from is a date, as 2006-01-02", nil)
			return
		}
	}

	entries, err := a.records.Trail(r.Context(), c, id, from, to)
	switch {
	case errors.Is(err, records.ErrNotTheirTrail):
		a.fail(w, r, http.StatusForbidden,
			"who has opened a record is a care manager's question", nil)
		return
	case errors.Is(err, records.ErrNotVisible):
		a.fail(w, r, http.StatusNotFound, "no such resident", nil)
		return
	case err != nil:
		a.fail(w, r, http.StatusInternalServerError, "could not read the trail", err)
		return
	}
	a.ok(w, r, http.StatusOK, map[string]any{"entries": entries})
}

// history is a resident's days over a range: GET .../days?from=&to=
//
// Both bounds are optional. to defaults to today and from to three weeks before it, which
// is the span the product shows and the span a caregiver backdates within. A range is
// capped rather than refused when it is too wide - a client asking for a year gets the
// most recent ninety days rather than an error, because the honest failure here is a slow
// query, not a malformed request.
func (a *API) history(w http.ResponseWriter, r *http.Request, c db.Caller) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		a.fail(w, r, http.StatusNotFound, "no such resident", nil)
		return
	}
	to := time.Now().UTC().Truncate(24 * time.Hour)
	if v := r.URL.Query().Get("to"); v != "" {
		if to, err = time.Parse("2006-01-02", v); err != nil {
			a.fail(w, r, http.StatusBadRequest, "to is a date, as 2006-01-02", nil)
			return
		}
	}
	from := to.AddDate(0, 0, -20) // twenty-one days inclusive
	if v := r.URL.Query().Get("from"); v != "" {
		if from, err = time.Parse("2006-01-02", v); err != nil {
			a.fail(w, r, http.StatusBadRequest, "from is a date, as 2006-01-02", nil)
			return
		}
	}
	if from.After(to) {
		a.fail(w, r, http.StatusBadRequest, "from is after to", nil)
		return
	}
	if earliest := to.AddDate(0, 0, -89); from.Before(earliest) {
		from = earliest
	}

	days, err := a.records.History(r.Context(), c, id, from, to)
	if err != nil {
		if errors.Is(err, records.ErrNotVisible) {
			a.fail(w, r, http.StatusNotFound, "no such resident", nil)
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not read the history", err)
		return
	}
	a.ok(w, r, http.StatusOK, map[string]any{
		"from": from.Format("2006-01-02"),
		"to":   to.Format("2006-01-02"),
		"days": days,
	})
}

// dayHistory is every revision of one day, oldest first: GET .../days/{date}/history
//
// A day filed once is a list of one. The client does not have to special-case a day with
// no corrections, and "has this been corrected" is answered by the length rather than by a
// flag somebody has to remember to set.
func (a *API) dayHistory(w http.ResponseWriter, r *http.Request, c db.Caller) {
	id, on, ok := a.residentAndDate(w, r)
	if !ok {
		return
	}
	revisions, err := a.records.Chain(r.Context(), c, id, on)
	if err != nil {
		if errors.Is(err, records.ErrNotVisible) {
			a.fail(w, r, http.StatusNotFound, "no such resident", nil)
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not read the day", err)
		return
	}
	a.ok(w, r, http.StatusOK, map[string]any{"revisions": revisions})
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

// The three administrative handlers.
//
// They share one shape and it is deliberate: a domain error becomes a status and a sentence
// a care manager can act on, and nothing from the database reaches the response. The errors
// they map were chosen in internal/facility for exactly this, because the alternative - a
// handler reading row counts and guessing - is the thing that put "that day was not
// something the record accepts" in front of a daughter in M3.
func (a *API) facilityFailure(w http.ResponseWriter, r *http.Request, err error) bool {
	switch {
	case errors.Is(err, facility.ErrNotVisible):
		a.fail(w, r, http.StatusNotFound, "no such membership", nil)
	case errors.Is(err, facility.ErrLastManager):
		a.fail(w, r, http.StatusConflict,
			"this is the last care manager at the building, so there would be nobody left to run it", nil)
	case errors.Is(err, facility.ErrNotTheirs):
		a.fail(w, r, http.StatusForbidden, "only a care manager can do this", nil)
	case errors.Is(err, facility.ErrAccountExists):
		a.fail(w, r, http.StatusConflict, "that email address already has an account", nil)
	default:
		return false
	}
	return true
}

func (a *API) listMembers(w http.ResponseWriter, r *http.Request, c db.Caller) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		a.fail(w, r, http.StatusNotFound, "no such facility", nil)
		return
	}
	members, err := a.facility.Members(r.Context(), c, id)
	if err != nil {
		if a.facilityFailure(w, r, err) {
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not read the building", err)
		return
	}
	a.ok(w, r, http.StatusOK, members)
}

func (a *API) inviteMember(w http.ResponseWriter, r *http.Request, c db.Caller) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		a.fail(w, r, http.StatusNotFound, "no such facility", nil)
		return
	}
	var body struct {
		Email       string `json:"email"`
		DisplayName string `json:"displayName"`
		Role        string `json:"role"`
	}
	if !a.read(w, r, &body) {
		return
	}
	// Checked here because these are the shape of the request rather than a decision about
	// who may do what. Everything that is a decision is below, in the database.
	if body.Email == "" || body.DisplayName == "" {
		a.fail(w, r, http.StatusBadRequest, "an email address and a name are both needed", nil)
		return
	}
	if body.Role != "caregiver" && body.Role != "care_manager" {
		a.fail(w, r, http.StatusBadRequest, "a role is either caregiver or care_manager", nil)
		return
	}

	token, digest, err := auth.NewToken()
	if err != nil {
		a.fail(w, r, http.StatusInternalServerError, "could not make an invitation", err)
		return
	}
	invited, err := a.facility.Invite(r.Context(), c, id,
		body.Email, body.DisplayName, body.Role, digest, token)
	if err != nil {
		if a.facilityFailure(w, r, err) {
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not add them to the building", err)
		return
	}
	// The one time the link exists anywhere outside the recipient's hands. Only its digest
	// was stored, so there is no asking for it again.
	a.ok(w, r, http.StatusCreated, invited)
}

func (a *API) endMembership(w http.ResponseWriter, r *http.Request, c db.Caller) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		a.fail(w, r, http.StatusNotFound, "no such membership", nil)
		return
	}
	if err := a.facility.End(r.Context(), c, id); err != nil {
		if a.facilityFailure(w, r, err) {
			return
		}
		a.fail(w, r, http.StatusInternalServerError, "could not end the membership", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
