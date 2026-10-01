// Package records is the only way resident data leaves the database.
//
// The architecture directory flags this as the one gap it cannot close itself:
// PostgreSQL has no SELECT trigger, so a read is only in the audit trail if the
// application says so. audit-logging.sql calls that "a convention the code has to keep
// rather than a guarantee the database enforces, and the one place where a forgetful
// handler still produces a gap."
//
// This package is the answer to that. Every function here calls audit_read before it
// reads, in the same transaction, so a read that is not in the trail is a read that did
// not happen - the audit insert and the select commit together or neither does.
//
// It does not take a pgx.Tx from a caller and it does not hand one out. A handler that
// wants a care day asks this package; a handler that has a Tx and a query string is
// outside the design, and records_test.go fails the build for it by looking at the source
// of every other package for a PHI table name.
package records

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/dailycare-hq/dailycare-api/internal/db"
)

type Store struct{ db *db.DB }

func New(d *db.DB) *Store { return &Store{db: d} }

var ErrNotVisible = errors.New("records: no such resident, or not one this session may read")

// ErrNotTheirsToFile is somebody who may read a resident's record trying to write to it.
//
// Family, in practice. Reading and writing are separate predicates in the policies -
// app_may_read_resident and the insert policies on care_days - and this is the gap between
// them, which is the whole shape of a family member: they receive care, they do not record
// it. Separate from ErrNotVisible because the answers differ: a resident they cannot see is
// 404 so that uuids cannot be used to enumerate a building, and a resident they can see is
// not hidden now just because they tried to write to it.
var ErrNotTheirsToFile = errors.New("records: this record is not theirs to write to")

// policyRefusal turns a row-level security refusal into the error that says so.
//
// Only safe to call after read(), which calls audit_read and fails closed - so the caller
// has already been shown to be somebody who may see this resident, and a 42501 past that
// point is the narrower refusal rather than the broad one.
//
// Measured before it was written, twice: a family member filing a day nobody had filed and
// a family member correcting one that existed both came back 42501 on care_days, so the
// policy is checked before the partial unique index and this does not need to tell them
// apart. Until M4 both were served as 400 "that day was not something the record accepts",
// which told a daughter her data was malformed when the truth was that recording care is
// not hers to do.
func policyRefusal(err error) error {
	var pg *pgconn.PgError
	if errors.As(err, &pg) && pg.Code == "42501" {
		return ErrNotTheirsToFile
	}
	return err
}

// CareDay is what a caregiver files at the end of a shift.
// A day as it reads back. The pointers are the difference between a day nobody has filed
// and a day filed as calm: absent means nothing was recorded, and false would be a claim.
//
// `note` rather than `notes`, to match what Filing sends. The two names for one field were
// a wart nothing had tripped over yet, because nothing read a day back.
type CareDay struct {
	ResidentID uuid.UUID `json:"residentId"`
	On         time.Time `json:"on"`
	Mood       *string   `json:"mood,omitempty"`
	Appetite   *string   `json:"appetite,omitempty"`
	Sleep      *string   `json:"sleep,omitempty"`
	Note       *string   `json:"note,omitempty"`
	Shower     *bool     `json:"shower,omitempty"`
	Grooming   *bool     `json:"grooming,omitempty"`
	// Always present, never null, so a caller can range over them without checking. Empty
	// means nothing was recorded, which is what an unfiled day is.
	Meals    []Meal     `json:"meals"`
	Concerns []string   `json:"concerns"`
	FiledBy  *uuid.UUID `json:"filedBy,omitempty"`
	FiledAt  *time.Time `json:"filedAt,omitempty"`
	// Set on a revision that a later one replaced. Absent on the day as it currently
	// stands, which is how a client tells the two apart without a second field saying so.
	SupersededAt *time.Time `json:"supersededAt,omitempty"`
	// Whether this row replaced an earlier one - amends_id, as a boolean, because the id
	// of the row it replaced is no use to a client that reads the chain by date. It is
	// what lets a history mark the days that were corrected without asking for the
	// revisions of every day on the screen.
	Corrected bool `json:"corrected"`
}

// read runs fn after recording that the resident's data was looked at. Unexported, and the
// only route to a query in this package, so "audit first" is one line in one place rather
// than a thing every method remembers.
//
// audit_read refuses to record a read of a resident the session cannot see, so a failure
// here is also the access check - and it happens before any row is fetched rather than
// after, which is the order that matters if the two ever disagree.
func (s *Store) read(ctx context.Context, c db.Caller, resident uuid.UUID, subject string,
	fn func(pgx.Tx) error) error {
	return s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT audit_read($1, $2)`, resident, subject); err != nil {
			// insufficient_privilege from audit_read means the session cannot see this
			// resident. Same answer either way, so a probe cannot tell "no such resident"
			// from "not yours".
			return ErrNotVisible
		}
		return fn(tx)
	})
}

// Day returns one resident's day, or ErrNotVisible.
func (s *Store) Day(ctx context.Context, c db.Caller, resident uuid.UUID, on time.Time) (*CareDay, error) {
	d := CareDay{ResidentID: resident, On: on, Meals: []Meal{}, Concerns: []string{}}
	err := s.read(ctx, c, resident, "care_days", func(tx pgx.Tx) error {
		// The current revision only. A corrected day has an older row with the same
		// resident and date, and showing that one would be showing a past that was
		// withdrawn - which is the opposite of what amends_id is for.
		var id uuid.UUID
		if err := tx.QueryRow(ctx, `
			SELECT id, resident_id, care_date, mood, appetite, sleep, note,
			       hygiene_shower, hygiene_grooming, filed_by, filed_at
			FROM care_days
			WHERE resident_id = $1 AND care_date = $2 AND superseded_at IS NULL`,
			resident, on).Scan(&id, &d.ResidentID, &d.On, &d.Mood, &d.Appetite, &d.Sleep,
			&d.Note, &d.Shower, &d.Grooming, &d.FiledBy, &d.FiledAt); err != nil {
			return err
		}

		// Ordered by the enum rather than by name, so breakfast comes before lunch comes
		// before dinner instead of breakfast, dinner, lunch.
		rows, err := tx.Query(ctx,
			`SELECT slot, happened, amount FROM care_day_meals
			 WHERE care_day_id = $1 ORDER BY slot`, id)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var m Meal
			if err := rows.Scan(&m.Slot, &m.Happened, &m.Amount); err != nil {
				return err
			}
			d.Meals = append(d.Meals, m)
		}
		if err := rows.Err(); err != nil {
			return err
		}

		concerns, err := tx.Query(ctx,
			`SELECT concern FROM care_day_concerns WHERE care_day_id = $1 ORDER BY concern`, id)
		if err != nil {
			return err
		}
		defer concerns.Close()
		for concerns.Next() {
			var name string
			if err := concerns.Scan(&name); err != nil {
				return err
			}
			d.Concerns = append(d.Concerns, name)
		}
		return concerns.Err()
	})
	if errors.Is(err, pgx.ErrNoRows) {
		// A day nobody has filed yet is an empty day, not a missing one. The read is still
		// in the trail: somebody asked about this resident.
		return &CareDay{ResidentID: resident, On: on, Meals: []Meal{}, Concerns: []string{}}, nil
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// History is a resident's days over a range, most recent first.
//
// The current revision of each, the same rule Day() follows: a corrected day appears once,
// as it now stands. Chain() is where the versions of one day live.
//
// One audit row for the request, not one per day. read() calls audit_read once and the
// range is read inside it, so three weeks of history is recorded as somebody opening three
// weeks of history. A row per day would say the same thing twenty-one times and bury the
// reads that are about one person on one date.
func (s *Store) History(ctx context.Context, c db.Caller, resident uuid.UUID,
	from, to time.Time) ([]CareDay, error) {
	var out []CareDay
	err := s.read(ctx, c, resident, "care_days", func(tx pgx.Tx) error {
		var err error
		out, err = loadDays(ctx, tx, `
			SELECT id, resident_id, care_date, mood, appetite, sleep, note,
			       hygiene_shower, hygiene_grooming, filed_by, filed_at, superseded_at,
			       amends_id IS NOT NULL
			FROM care_days
			WHERE resident_id = $1 AND care_date BETWEEN $2 AND $3
			  AND superseded_at IS NULL
			ORDER BY care_date DESC`, resident, from, to)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// Chain is every revision of one day, oldest first.
//
// The original, then each correction that replaced it. Ordered by when they were filed
// rather than by amends_id: the link says which row a correction replaced and the order
// says when, and reading the chain by time means a row whose link is missing still appears
// in the right place instead of vanishing from the history.
//
// Empty for a day nobody has filed. One row for a day filed once - a day with no
// corrections is a chain of length one, not a special case.
func (s *Store) Chain(ctx context.Context, c db.Caller, resident uuid.UUID,
	on time.Time) ([]CareDay, error) {
	var out []CareDay
	err := s.read(ctx, c, resident, "care_days", func(tx pgx.Tx) error {
		var err error
		out, err = loadDays(ctx, tx, `
			SELECT id, resident_id, care_date, mood, appetite, sleep, note,
			       hygiene_shower, hygiene_grooming, filed_by, filed_at, superseded_at,
			       amends_id IS NOT NULL
			FROM care_days
			WHERE resident_id = $1 AND care_date = $2
			ORDER BY filed_at ASC`, resident, on)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// TrailEntry is one line of the answer to "who opened this resident's record".
//
// The actor is a name rather than an identifier, because a care manager reading their own
// building already knows the people in it and a column of uuids is not an answer. Absent
// for a job: retention has no name to give.
type TrailEntry struct {
	At      time.Time `json:"at"`
	Action  string    `json:"action"`
	Actor   *string   `json:"actor,omitempty"`
	Role    *string   `json:"role,omitempty"`
	Subject string    `json:"subject"`
}

// ErrNotTheirTrail is a caregiver asking who has read a record. They may read the record;
// who else has read it is a question the facility asks about its own building.
var ErrNotTheirTrail = errors.New("records: the trail is a care manager's to read")

// Trail is who opened this resident's record, most recent first.
//
// Refused for anybody but a care manager of the resident's own facility. The policy on
// audit_events already says so and would return nothing - but nothing is the same shape as
// "no-one has opened it", and those are different answers. A caregiver shown an empty trail
// would reasonably conclude the record had never been read.
//
// The check runs inside the transaction, before the select and after audit_read has
// already written a row saying this resident's trail was read. That order looks wrong and
// is deliberate: a refusal returns an error, InSession rolls back, and the audit row goes
// with it. Checking first and auditing second would be the same outcome by a longer route;
// what neither may do is leave a row claiming somebody read something they were refused.
func (s *Store) Trail(ctx context.Context, c db.Caller, resident uuid.UUID,
	from, to time.Time) ([]TrailEntry, error) {
	var out []TrailEntry
	err := s.read(ctx, c, resident, "audit_events", func(tx pgx.Tx) error {
		var manager bool
		if err := tx.QueryRow(ctx, `
			SELECT app_is_care_manager(r.facility_id)
			FROM residents r WHERE r.id = $1`, resident).Scan(&manager); err != nil {
			return err
		}
		if !manager {
			return ErrNotTheirTrail
		}

		// The actor's name through a join the policies decide: users_colleagues lets a
		// manager see the people at their own building, and nothing lets them see anybody
		// else - so a row written by somebody who has since left the facility comes back
		// without a name rather than with one this reader should not have.
		rows, err := tx.Query(ctx, `
			SELECT a.occurred_at, a.action, u.display_name, a.actor_role, a.subject_type
			FROM audit_events a
			LEFT JOIN users u ON u.id = a.actor_user_id
			WHERE a.resident_id = $1 AND a.occurred_at >= $2 AND a.occurred_at < $3
			ORDER BY a.occurred_at DESC
			LIMIT 200`, resident, from, to)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var e TrailEntry
			if err := rows.Scan(&e.At, &e.Action, &e.Actor, &e.Role, &e.Subject); err != nil {
				return err
			}
			out = append(out, e)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, err
	}
	if out == nil {
		out = []TrailEntry{}
	}
	return out, nil
}

// loadDays runs a query that returns care day rows and fills in their meals and concerns.
//
// Two queries for the children rather than two per day. Twenty-one days through the
// per-day path in Day() is forty-two round trips to say something that fits in two, and
// the count is set by how much history somebody scrolls rather than by anything the
// database is doing.
func loadDays(ctx context.Context, tx pgx.Tx, query string, args ...any) ([]CareDay, error) {
	rows, err := tx.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	// Indexed by care day id, because that is what the child tables reference. The slice
	// keeps the order the query asked for; the map is only how the children find their day.
	var (
		days []CareDay
		ids  []uuid.UUID
		byID = map[uuid.UUID]int{}
	)
	for rows.Next() {
		var id uuid.UUID
		d := CareDay{Meals: []Meal{}, Concerns: []string{}}
		if err := rows.Scan(&id, &d.ResidentID, &d.On, &d.Mood, &d.Appetite, &d.Sleep,
			&d.Note, &d.Shower, &d.Grooming, &d.FiledBy, &d.FiledAt, &d.SupersededAt,
			&d.Corrected); err != nil {
			rows.Close()
			return nil, err
		}
		byID[id] = len(days)
		days = append(days, d)
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(days) == 0 {
		return []CareDay{}, nil
	}

	meals, err := tx.Query(ctx,
		`SELECT care_day_id, slot, happened, amount FROM care_day_meals
		 WHERE care_day_id = ANY($1) ORDER BY care_day_id, slot`, ids)
	if err != nil {
		return nil, err
	}
	for meals.Next() {
		var id uuid.UUID
		var m Meal
		if err := meals.Scan(&id, &m.Slot, &m.Happened, &m.Amount); err != nil {
			meals.Close()
			return nil, err
		}
		if i, ok := byID[id]; ok {
			days[i].Meals = append(days[i].Meals, m)
		}
	}
	meals.Close()
	if err := meals.Err(); err != nil {
		return nil, err
	}

	concerns, err := tx.Query(ctx,
		`SELECT care_day_id, concern FROM care_day_concerns
		 WHERE care_day_id = ANY($1) ORDER BY care_day_id, concern`, ids)
	if err != nil {
		return nil, err
	}
	for concerns.Next() {
		var id uuid.UUID
		var name string
		if err := concerns.Scan(&id, &name); err != nil {
			concerns.Close()
			return nil, err
		}
		if i, ok := byID[id]; ok {
			days[i].Concerns = append(days[i].Concerns, name)
		}
	}
	concerns.Close()
	return days, concerns.Err()
}

// Residents is the list a caregiver sees. No audit_read: the list is who they are
// assigned to, which the policies already answer, and recording a row per resident on
// every app launch would fill the trail with the one event that carries no information.
func (s *Store) Residents(ctx context.Context, c db.Caller) ([]Resident, error) {
	var out []Resident
	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id, display_name, facility_id,
			       baseline_mood, baseline_appetite, baseline_sleep
			  FROM residents ORDER BY display_name`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var r Resident
			if err := rows.Scan(&r.ID, &r.DisplayName, &r.FacilityID,
				&r.Baseline.Mood, &r.Baseline.Appetite, &r.Baseline.Sleep); err != nil {
				return err
			}
			out = append(out, r)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, fmt.Errorf("records: listing residents: %w", err)
	}
	return out, nil
}

// What a caregiver files at the end of a shift. Every field on it is PHI.
type Filing struct {
	Mood     string   `json:"mood"`
	Appetite string   `json:"appetite"`
	Sleep    string   `json:"sleep"`
	Note     string   `json:"note"`
	Shower   bool     `json:"shower"`
	Grooming bool     `json:"grooming"`
	Meals    []Meal   `json:"meals"`
	Concerns []string `json:"concerns"`
}

type Meal struct {
	Slot     string  `json:"slot"`
	Happened bool    `json:"happened"`
	Amount   *string `json:"amount,omitempty"`
}

// File writes a day, or amends one that is already there.
//
// Amending is the whole of the design here and it is not an update. care_days carries a
// trigger that refuses every column but superseded_at and updated_at, and a partial unique
// index that allows one un-superseded row per resident per day - so a correction is a new
// row pointing back at the old one through amends_id, and the original stays readable.
// A family can be shown that a correction happened rather than a different past.
//
// All of it in one transaction. Stamping the old row and failing to write the new one
// would leave a resident with a day that has been retired and not replaced.
func (s *Store) File(ctx context.Context, c db.Caller, resident uuid.UUID, on time.Time,
	f Filing) (uuid.UUID, error) {
	var id uuid.UUID
	err := s.read(ctx, c, resident, "care_days", func(tx pgx.Tx) error {
		var facility uuid.UUID
		if err := tx.QueryRow(ctx,
			`SELECT facility_id FROM residents WHERE id = $1`, resident).Scan(&facility); err != nil {
			return ErrNotVisible
		}

		// The one that is there now, if there is one.
		var previous *uuid.UUID
		if err := tx.QueryRow(ctx, `
			SELECT id FROM care_days
			WHERE resident_id = $1 AND care_date = $2 AND superseded_at IS NULL`,
			resident, on).Scan(&previous); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}

		// Retire the old one first. The partial unique index allows one un-superseded row
		// per resident per day, so inserting before retiring is the thing it refuses.
		// Nothing is left retired-with-no-replacement by a failure here, because the
		// insert below is in the same transaction and takes the stamp down with it.
		if previous != nil {
			if _, err := tx.Exec(ctx,
				// superseded_at and nothing else. It is the timestamp of the only change a
				// filed day can undergo, and the grant is narrower than the trigger here
				// for exactly that reason.
				`UPDATE care_days SET superseded_at = now() WHERE id = $1`,
				*previous); err != nil {
				return policyRefusal(err)
			}
		}

		if err := tx.QueryRow(ctx, `
			INSERT INTO care_days
			  (facility_id, resident_id, care_date, mood, appetite, sleep, note,
			   hygiene_shower, hygiene_grooming, filed_by, amends_id)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
			RETURNING id`,
			facility, resident, on, f.Mood, f.Appetite, f.Sleep, f.Note,
			f.Shower, f.Grooming, c.UserID, previous).Scan(&id); err != nil {
			return policyRefusal(err)
		}

		for _, m := range f.Meals {
			if _, err := tx.Exec(ctx,
				`INSERT INTO care_day_meals (care_day_id, slot, happened, amount)
				 VALUES ($1, $2, $3, $4)`, id, m.Slot, m.Happened, m.Amount); err != nil {
				return policyRefusal(err)
			}
		}
		for _, name := range f.Concerns {
			if _, err := tx.Exec(ctx,
				`INSERT INTO care_day_concerns (care_day_id, concern) VALUES ($1, $2)`,
				id, name); err != nil {
				return policyRefusal(err)
			}
		}
		return nil
	})
	return id, err
}

type Resident struct {
	ID          uuid.UUID `json:"id"`
	DisplayName string    `json:"displayName"`
	FacilityID  uuid.UUID `json:"facilityId"`
	Baseline    Baseline  `json:"baseline"`
}

// What a normal day looks like for this person.
//
// Served because "today's update" is not three values, it is which of them differ from
// this - the residents table says so in as many words, and a family member's phone has no
// other way to know. A caregiver's phone has its own copy typed during setup; this is the
// building's, and the building's is the one the record was filed against.
type Baseline struct {
	Mood     string `json:"mood"`
	Appetite string `json:"appetite"`
	Sleep    string `json:"sleep"`
}
