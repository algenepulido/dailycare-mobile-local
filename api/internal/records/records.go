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

	"github.com/dailycare-hq/dailycare-api/internal/db"
)

type Store struct{ db *db.DB }

func New(d *db.DB) *Store { return &Store{db: d} }

var ErrNotVisible = errors.New("records: no such resident, or not one this session may read")

// CareDay is what a caregiver files at the end of a shift.
type CareDay struct {
	ResidentID uuid.UUID  `json:"residentId"`
	On         time.Time  `json:"on"`
	Mood       *string    `json:"mood,omitempty"`
	Notes      *string    `json:"notes,omitempty"`
	FiledBy    *uuid.UUID `json:"filedBy,omitempty"`
	FiledAt    *time.Time `json:"filedAt,omitempty"`
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
	var d CareDay
	err := s.read(ctx, c, resident, "care_days", func(tx pgx.Tx) error {
		row := tx.QueryRow(ctx, `
			SELECT resident_id, care_date, mood, note, filed_by, filed_at
			FROM care_days
			WHERE resident_id = $1 AND care_date = $2 AND superseded_at IS NULL`,
			resident, on)
		return row.Scan(&d.ResidentID, &d.On, &d.Mood, &d.Notes, &d.FiledBy, &d.FiledAt)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		// A day nobody has filed yet is an empty day, not a missing one. The read is still
		// in the trail: somebody asked about this resident.
		return &CareDay{ResidentID: resident, On: on}, nil
	}
	if err != nil {
		return nil, err
	}
	return &d, nil
}

// Residents is the list a caregiver sees. No audit_read: the list is who they are
// assigned to, which the policies already answer, and recording a row per resident on
// every app launch would fill the trail with the one event that carries no information.
func (s *Store) Residents(ctx context.Context, c db.Caller) ([]Resident, error) {
	var out []Resident
	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT id, display_name, facility_id FROM residents ORDER BY display_name`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var r Resident
			if err := rows.Scan(&r.ID, &r.DisplayName, &r.FacilityID); err != nil {
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
				return err
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
			return err
		}

		for _, m := range f.Meals {
			if _, err := tx.Exec(ctx,
				`INSERT INTO care_day_meals (care_day_id, slot, happened, amount)
				 VALUES ($1, $2, $3, $4)`, id, m.Slot, m.Happened, m.Amount); err != nil {
				return err
			}
		}
		for _, name := range f.Concerns {
			if _, err := tx.Exec(ctx,
				`INSERT INTO care_day_concerns (care_day_id, concern) VALUES ($1, $2)`,
				id, name); err != nil {
				return err
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
}
