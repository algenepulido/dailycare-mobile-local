// Package facility is how a building is administered: who works in it, and on what terms.
//
// Every refusal here comes from the database. Nothing in this package decides who may do
// what - it asks, and translates the answer. That is the property milestone five exists
// for: an administrative surface that decides for itself is one more place for the policies
// and the application to drift apart, and the policies are the ones that run in production.
//
// Residents and the family grants on them are not here. They are PHI, reads of them belong
// to the records package by the rule that package is built around, and a second place that
// selected from them would be a disclosure route nobody is auditing. People and membership
// are not PHI, so they live here.
//
// The shape of every change is read, then write, in one transaction. Not for safety - the
// policies are that - but because an UPDATE a policy filters out changes no rows and raises
// nothing, so "nothing happened" has two meanings and a caller is owed different answers
// for them. The read says whether the row can be seen at all; the write says whether it was
// theirs to change. Without the read every refusal is a 404 and a manager at the right
// building is told their colleague does not exist.
package facility

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/dailycare-hq/dailycare-api/internal/db"
)

type Store struct{ db *db.DB }

func New(d *db.DB) *Store { return &Store{db: d} }

// ErrNotVisible is a building or a membership this caller has nothing to do with.
//
// 404, so that a uuid cannot be used to find out who works where.
var ErrNotVisible = errors.New("facility: no such membership, or not one this session may see")

// ErrNotTheirs is somebody who can see a membership and may not change it.
//
// A caregiver, in practice. members_own_facilities shows them the building they work in;
// nothing admits them to writing it. Separate from ErrNotVisible because the answers differ,
// the same way records tells a family member apart from a stranger.
var ErrNotTheirs = errors.New("facility: visible, and not this session's to change")

// ErrLastManager is the one refusal with a reason worth repeating back.
//
// The ending policy refuses two different things and both arrive as no rows changed: a
// building that is not yours, and the last person who can run one. The first is answered by
// the read above. This is the second, asked for by name afterwards, because "you cannot do
// that" is a worse answer than the true one when the true one is actionable.
var ErrLastManager = errors.New("facility: the last care manager at this building")

// ErrAccountExists is an email that already belongs to somebody.
//
// Deferred rather than solved, and the reason is worth keeping: a care manager cannot read
// an account they have not been introduced to - users opens to yourself, a colleague at your
// building, and a family member you granted access to - so the application cannot learn the
// id of an account it has just been told exists. Resolving it needs a function that answers
// "is there an account for this address", which is an oracle for whether any given email is
// in the system, offered to every care manager. That is a decision to make deliberately with
// a product reason, not one to make at the bottom of an invite handler.
var ErrAccountExists = errors.New("facility: that address already has an account")

// Member is one person's place in one building.
type Member struct {
	ID          uuid.UUID  `json:"id"`
	UserID      uuid.UUID  `json:"userId"`
	DisplayName string     `json:"displayName"`
	Email       string     `json:"email"`
	Role        string     `json:"role"`
	State       string     `json:"state"`
	StartedAt   time.Time  `json:"startedAt"`
	EndedAt     *time.Time `json:"endedAt,omitempty"`
}

// Invited is what a manager is handed once, at the moment they invite somebody.
//
// Link is empty when the person already had a way in. That is not a failure: redeem_token
// activates every invitation an account holds, so somebody who already has a password
// accepts this membership by signing in, and minting a second bearer credential because a
// building added them to something would be the wrong answer.
type Invited struct {
	Member Member `json:"member"`
	Link   string `json:"link,omitempty"`
}

func refusal(err error) error {
	var pg *pgconn.PgError
	if errors.As(err, &pg) {
		switch pg.Code {
		case "42501":
			return ErrNotTheirs
		case "23505":
			return ErrAccountExists
		}
	}
	return err
}

// Members is everybody at one building, including the ones who have left.
//
// Ended memberships are in the list because the screen is a record of the building rather
// than a roster: "without losing what they filed" is one of the milestone's own sentences,
// and a person who is gone from the list is a person whose name on a filed day has nothing
// behind it. The caller decides how to show them.
//
// No facility argument is checked here. members_own_facilities is what answers, and a
// building the caller has nothing to do with comes back empty rather than refused - which
// is the same answer it would give for a building that does not exist, deliberately.
func (s *Store) Members(ctx context.Context, c db.Caller, facility uuid.UUID) ([]Member, error) {
	out := []Member{}
	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT fm.id, fm.user_id, u.display_name, u.email::text,
			       fm.role::text, fm.state::text, fm.started_at, fm.ended_at
			  FROM facility_members fm
			  JOIN users u ON u.id = fm.user_id
			 WHERE fm.facility_id = $1
			 ORDER BY fm.ended_at NULLS FIRST, u.display_name`, facility)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var m Member
			if err := rows.Scan(&m.ID, &m.UserID, &m.DisplayName, &m.Email,
				&m.Role, &m.State, &m.StartedAt, &m.EndedAt); err != nil {
				return err
			}
			out = append(out, m)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// Invite puts somebody in a building and hands back the one link that lets them arrive.
//
// Three writes and one function call, in one transaction, and the order matters. The account
// is named by the application rather than asked for back: a manager who has just created one
// cannot read it, because an account with no membership yet is not themselves, not a
// colleague, and not a family member they granted access to. member-invitation.sql has the
// measurement that led to the id being in the insert grant.
//
// The link is empty when issue_invitation says the person already had a way in.
func (s *Store) Invite(ctx context.Context, c db.Caller, facility uuid.UUID,
	email, displayName, role, digest, token string) (Invited, error) {

	var inv Invited
	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		userID := uuid.New()
		if _, err := tx.Exec(ctx,
			`INSERT INTO users (id, email, display_name) VALUES ($1, $2, $3)`,
			userID, email, displayName); err != nil {
			return refusal(err)
		}

		// state is not named and cannot be: the column is outside the insert grant, so
		// 'invited' arrives as the default. invited_by is pinned by the policy to the person
		// making the request, so passing it is saying what is already true rather than
		// choosing it.
		var memberID uuid.UUID
		if err := tx.QueryRow(ctx, `
			INSERT INTO facility_members (facility_id, user_id, role, invited_by)
			VALUES ($1, $2, $3, app_user_id())
			RETURNING id`, facility, userID, role).Scan(&memberID); err != nil {
			return refusal(err)
		}

		var issued bool
		if err := tx.QueryRow(ctx,
			`SELECT issue_invitation($1, $2)`, userID, digest).Scan(&issued); err != nil {
			return refusal(err)
		}
		if issued {
			inv.Link = token
		}

		return tx.QueryRow(ctx, `
			SELECT fm.id, fm.user_id, u.display_name, u.email::text,
			       fm.role::text, fm.state::text, fm.started_at, fm.ended_at
			  FROM facility_members fm
			  JOIN users u ON u.id = fm.user_id
			 WHERE fm.id = $1`, memberID).Scan(
			&inv.Member.ID, &inv.Member.UserID, &inv.Member.DisplayName, &inv.Member.Email,
			&inv.Member.Role, &inv.Member.State, &inv.Member.StartedAt, &inv.Member.EndedAt)
	})
	if err != nil {
		return Invited{}, err
	}
	return inv, nil
}

// End closes a membership on a date. Nothing is deleted and nothing they filed moves.
//
// The three answers this has to tell apart, in the order they are asked: a membership this
// caller cannot see at all, which is 404; the last care manager at a building, which the
// policy refuses and which is worth saying out loud; and anything else the policy refused,
// which is a caregiver trying to administer their own building.
func (s *Store) End(ctx context.Context, c db.Caller, member uuid.UUID) error {
	return s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		var at uuid.UUID
		if err := tx.QueryRow(ctx,
			`SELECT facility_id FROM facility_members WHERE id = $1`, member).Scan(&at); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotVisible
			}
			return err
		}

		// One statement, matching the one transition members_manager_ends admits. A row
		// count of zero here is the policy filtering it out, which raises nothing - the
		// whole reason this function reads before it writes.
		tag, err := tx.Exec(ctx, `
			UPDATE facility_members
			   SET state = 'revoked', ended_at = now(), updated_at = now()
			 WHERE id = $1 AND ended_at IS NULL`, member)
		if err != nil {
			return refusal(err)
		}
		if tag.RowsAffected() == 1 {
			return nil
		}

		// The order of these two questions is the answer to a test that caught it the
		// other way round. Asked last-manager first, a caregiver who tried to end their
		// own manager's membership was told "that is the last care manager at this
		// building" - which is not why they were refused, and is a fact about how the
		// building is staffed handed to somebody who only asked to do something they may
		// not do. Whether this was theirs comes first; the reason it would be refused
		// anyway is only worth saying to somebody it could have worked for.
		var mine bool
		if err := tx.QueryRow(ctx,
			`SELECT app_is_care_manager($1)`, at).Scan(&mine); err != nil {
			return err
		}
		if !mine {
			return ErrNotTheirs
		}

		var last bool
		if err := tx.QueryRow(ctx,
			`SELECT app_is_last_care_manager($1)`, member).Scan(&last); err != nil {
			return err
		}
		if last {
			return ErrLastManager
		}
		return ErrNotTheirs
	})
}

// Assignment is one caregiver in front of one resident.
//
// The resident is an id and not a name. residents is PHI and the records package is the only
// thing that reads it - a join from here would be a second disclosure route with nothing
// auditing it, and records_test.go fails the build for exactly that. The screen already has
// the residents it may see and matches them up.
type Assignment struct {
	ID          uuid.UUID  `json:"id"`
	ResidentID  uuid.UUID  `json:"residentId"`
	MemberID    uuid.UUID  `json:"memberId"`
	DisplayName string     `json:"displayName"`
	StartedAt   time.Time  `json:"startedAt"`
	EndedAt     *time.Time `json:"endedAt,omitempty"`
}

// Assignments is every assignment at one building, including the ones that have ended.
func (s *Store) Assignments(ctx context.Context, c db.Caller, facility uuid.UUID) ([]Assignment, error) {
	out := []Assignment{}
	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `
			SELECT a.id, a.resident_id, a.facility_member_id, u.display_name,
			       a.started_at, a.ended_at
			  FROM assignments a
			  JOIN facility_members fm ON fm.id = a.facility_member_id
			  JOIN users u ON u.id = fm.user_id
			 WHERE a.facility_id = $1
			 ORDER BY a.ended_at NULLS FIRST, u.display_name`, facility)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var a Assignment
			if err := rows.Scan(&a.ID, &a.ResidentID, &a.MemberID, &a.DisplayName,
				&a.StartedAt, &a.EndedAt); err != nil {
				return err
			}
			out = append(out, a)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// Assign is a care manager deciding that this caregiver may read this resident.
//
// assigned_by is passed as app_user_id() rather than as an argument. The policy pins it to
// the requester, so sending anything else is refused - which makes the column an answer to
// "who gave them access to her" rather than a field a client fills in.
//
// A resident at another building is refused by the foreign key on the pair rather than by
// the policy, and a caregiver who is not a member of this one by the policy. Both arrive
// here as the same refusal, which is the right amount of detail to give back.
func (s *Store) Assign(ctx context.Context, c db.Caller,
	facility, resident, member uuid.UUID) (Assignment, error) {

	var a Assignment
	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		// ON CONFLICT against assignments_one_open_per_pair, which one-open-assignment.sql
		// added after a screen listed the same caregiver against one resident six times.
		// Assigning somebody who is already assigned is not a failure - it is the state the
		// caller wanted - so it returns the row that already says so rather than a second one
		// saying it again. The DO NOTHING leaves id unset, which is why the read below is a
		// separate statement rather than a RETURNING.
		var id uuid.UUID
		err := tx.QueryRow(ctx, `
			INSERT INTO assignments (facility_id, resident_id, facility_member_id, assigned_by)
			VALUES ($1, $2, $3, app_user_id())
			ON CONFLICT (resident_id, facility_member_id) WHERE ended_at IS NULL DO NOTHING
			RETURNING id`, facility, resident, member).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			err = tx.QueryRow(ctx, `
				SELECT id FROM assignments
				 WHERE resident_id = $1 AND facility_member_id = $2 AND ended_at IS NULL`,
				resident, member).Scan(&id)
		}
		if err != nil {
			return refusal(err)
		}
		return tx.QueryRow(ctx, `
			SELECT a.id, a.resident_id, a.facility_member_id, u.display_name,
			       a.started_at, a.ended_at
			  FROM assignments a
			  JOIN facility_members fm ON fm.id = a.facility_member_id
			  JOIN users u ON u.id = fm.user_id
			 WHERE a.id = $1`, id).Scan(&a.ID, &a.ResidentID, &a.MemberID, &a.DisplayName,
			&a.StartedAt, &a.EndedAt)
	})
	if err != nil {
		return Assignment{}, err
	}
	return a, nil
}

// EndAssignment closes one on a date. The days they filed while it stood are untouched.
//
// Read, then write, for the reason the whole package is built that way: the update policy
// filters rather than raises, so an assignment at a building the caller does not manage
// would otherwise look like a success.
func (s *Store) EndAssignment(ctx context.Context, c db.Caller, assignment uuid.UUID) error {
	return s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		var seen bool
		if err := tx.QueryRow(ctx,
			`SELECT true FROM assignments WHERE id = $1`, assignment).Scan(&seen); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNotVisible
			}
			return err
		}
		tag, err := tx.Exec(ctx,
			`UPDATE assignments SET ended_at = now() WHERE id = $1 AND ended_at IS NULL`,
			assignment)
		if err != nil {
			return refusal(err)
		}
		if tag.RowsAffected() == 1 {
			return nil
		}
		// Visible, unchanged, and no exception. Either a caregiver asked, or it had already
		// ended - and the second is not a failure worth a status of its own, because the
		// state the caller wanted is the state it is in.
		var already bool
		if err := tx.QueryRow(ctx,
			`SELECT ended_at IS NOT NULL FROM assignments WHERE id = $1`, assignment).Scan(&already); err != nil {
			return err
		}
		if already {
			return nil
		}
		return ErrNotTheirs
	})
}
