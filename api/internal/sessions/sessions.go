// Package sessions turns an email and a password into an identity, and a refresh token
// into a new one.
//
// Almost none of the thinking is here. The database holds the session rules - validity,
// rotation, idle expiry, revocation, and the refusal to issue a session to a deactivated
// account - in functions this package calls. What is left is the part PostgreSQL cannot
// do: verifying an argon2id digest, and signing something short-lived to carry the answer.
package sessions

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/dailycare-hq/dailycare-api/internal/auth"
	"github.com/dailycare-hq/dailycare-api/internal/db"
)

// One error for every way signing in can fail.
//
// An unknown address, a deactivated account, an invitation nobody accepted and a wrong
// password are four different things and the caller is told none of them. Anything else
// is an account-enumeration oracle: "this address exists" is worth having if the next
// step is a phishing mail to a caregiver about a resident they know by name.
var ErrSignInFailed = errors.New("sessions: that email and password do not match an account")

type Store struct {
	db     *db.DB
	signer *auth.Signer
}

func New(d *db.DB, s *auth.Signer) *Store { return &Store{db: d, signer: s} }

type Session struct {
	AccessToken  string    `json:"accessToken"`
	RefreshToken string    `json:"refreshToken"`
	ExpiresAt    time.Time `json:"expiresAt"`
	UserID       uuid.UUID `json:"userId"`
}

// What an account is: staff who record care, family who read it, or neither.
//
// Not a label the application decides. M3 had the application tell the database that every
// caller was a caregiver, and the audit trail then said "caregiver" for a care manager -
// the lesson being that the one place that knows is the one holding the rows. Both answers
// below are read under the caller's own identity through the ordinary policies:
// members_own_facilities shows a staff member their own building and a family member
// nothing, and contacts_read shows a family member their own grants. If either policy is
// ever widened, this answer moves with it rather than drifting away from it.
type Kind string

const (
	// Staff: a live facility membership. They file care.
	Staff Kind = "staff"
	// Family: no membership, and at least one active grant. They read one person's record.
	Family Kind = "family"
	// None: an account linked to nobody. A caregiver whose membership ended, or a family
	// member whose last grant was withdrawn - which is a real state and not a fault, and
	// the app has to say something true about it rather than show an empty list.
	None Kind = "none"
)

// Account is what a session is, as the database has it.
type Account struct {
	UserID      uuid.UUID `json:"userId"`
	DisplayName string    `json:"displayName"`
	Kind        Kind      `json:"kind"`
	// The buildings this account runs, which is empty for almost everybody.
	//
	// Here rather than discovered by the app trying an administrative route and reading the
	// refusal: a screen that exists only when a request fails is a screen whose condition
	// lives in an error path. app_is_care_manager() is the predicate every administrative
	// policy is built on, so what the app believes and what the policies allow are the same
	// sentence.
	Manages []Building `json:"manages"`
}

// Building is one facility, named, for a screen to put at the top of itself.
type Building struct {
	ID   uuid.UUID `json:"id"`
	Name string    `json:"name"`
}

// Account answers who is holding this session and which face of the app is theirs.
//
// Staff before family, because somebody can be both: resident_relation has 'self' and
// 'child', so a care manager whose mother lives in their own building holds a membership
// and a grant at once. They can file, so they get the app that files.
//
// No audit_read. Reading your own name and your own membership is not a disclosure of
// anybody's record, and a row per app launch would fill the trail with the one event that
// carries no information - the same reason Residents does not write one.
func (s *Store) Account(ctx context.Context, c db.Caller) (*Account, error) {
	out := &Account{UserID: c.UserID}
	var staff, family bool

	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		// Through the two functions the policies themselves are built on, rather than by
		// querying the membership and grant tables here. Two reasons, and the second is
		// the one that matters: app_my_facilities() and app_my_contact_facilities() are
		// the exact predicates app_may_read_resident() is assembled from, so what the app
		// believes an account is and what the policies will let it do cannot drift apart.
		// And both read app_user_id() themselves, so this asks about the same identity the
		// policies will ask about rather than an id handed in alongside it.
		return tx.QueryRow(ctx, `
			SELECT u.display_name,
			       EXISTS (SELECT 1 FROM app_my_facilities()),
			       EXISTS (SELECT 1 FROM app_my_contact_facilities())
			  FROM users u
			 WHERE u.id = app_user_id()`).
			Scan(&out.DisplayName, &staff, &family)
	})
	if err == nil && staff {
		err = s.db.InSession(ctx, c, func(tx pgx.Tx) error {
			rows, e := tx.Query(ctx, `
				SELECT f.id, f.name
				  FROM facilities f
				 WHERE app_is_care_manager(f.id)
				 ORDER BY f.name`)
			if e != nil {
				return e
			}
			defer rows.Close()
			for rows.Next() {
				var b Building
				if e := rows.Scan(&b.ID, &b.Name); e != nil {
					return e
				}
				out.Manages = append(out.Manages, b)
			}
			return rows.Err()
		})
	}
	if errors.Is(err, pgx.ErrNoRows) {
		// The token verified but names nobody this database has. A deactivated account
		// cannot get a session in the first place, so this is a signing key outliving the
		// account it was issued for, and the answer is the sign-in screen.
		return nil, ErrSignInFailed
	}
	if err != nil {
		return nil, fmt.Errorf("sessions: reading the account: %w", err)
	}

	switch {
	case staff:
		out.Kind = Staff
	case family:
		out.Kind = Family
	default:
		out.Kind = None
	}
	return out, nil
}

// SignIn is the only place a password is looked at.
func (s *Store) SignIn(ctx context.Context, email, password, device string) (*Session, error) {
	var userID uuid.UUID
	var digest string

	// Unidentified: credential_for_sign_in refuses to run for anybody who already has a
	// session, which is what keeps it from being a way to read digests.
	err := s.db.Unidentified(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx,
			`SELECT user_id, password_hash FROM credential_for_sign_in($1)`, email).
			Scan(&userID, &digest)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		// No account, or deactivated, or invited and never accepted. The password is
		// still verified against a throwaway digest so that the answer takes about as
		// long either way: a sign-in that returns faster for an unknown address is the
		// same oracle by a different route.
		_ = auth.Verify(password, decoyDigest)
		return nil, ErrSignInFailed
	}
	if err != nil {
		return nil, fmt.Errorf("sessions: looking up the credential: %w", err)
	}

	if err := auth.Verify(password, digest); err != nil {
		return nil, ErrSignInFailed
	}
	return s.issue(ctx, userID, device)
}

var (
	// Said the same way for a link that never existed, one already used, one that has
	// expired, and one for an account that was never activated. A caller who can tell
	// those apart can test links.
	ErrLinkNotUsable = errors.New("sessions: that link cannot be used")
	// Different, because it is actionable and says nothing about anybody else: the link
	// is fine and the account is not, and the link stays unused so it can be tried again
	// after somebody reactivates it.
	ErrAccountNotActive = errors.New("sessions: that account is not active")
)

// Redeem accepts an invitation or a password reset: the password is set, every session
// already open for that account ends, and a new one is issued.
//
// Signing them in here rather than sending them back to the sign-in screen is deliberate.
// The password was just chosen on this device; asking for it again proves nothing and is
// one more chance to mistype it standing in a corridor.
//
// The purpose is not taken from the caller. A link is one row with one purpose, so this
// tries invitation and then reset - and it does each in its own transaction, because a
// link belonging to a deactivated account raises, and a raised error inside a transaction
// takes the second attempt down with it.
func (s *Store) Redeem(ctx context.Context, token, password, device string) (*Session, error) {
	if err := auth.Acceptable(password); err != nil {
		return nil, err
	}
	digest, err := auth.Hash(password)
	if err != nil {
		return nil, fmt.Errorf("sessions: hashing: %w", err)
	}

	for _, purpose := range []string{"invitation", "password_reset"} {
		var userID *uuid.UUID
		err := s.db.Unidentified(ctx, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT redeem_token($1, $2, $3)`,
				auth.Digest(token), purpose, digest).Scan(&userID)
		})
		if err != nil {
			if strings.Contains(err.Error(), "that account is not active") {
				return nil, ErrAccountNotActive
			}
			return nil, fmt.Errorf("sessions: redeeming: %w", err)
		}
		if userID != nil {
			return s.issue(ctx, *userID, device)
		}
	}
	return nil, ErrLinkNotUsable
}

// Refresh rotates. The old token is revoked in the same statement that issues the new one,
// so a stolen refresh token stops working the moment the real client uses theirs.
func (s *Store) Refresh(ctx context.Context, refreshToken string) (*Session, error) {
	newToken, newDigest, err := auth.NewToken()
	if err != nil {
		return nil, err
	}

	var sessionID *uuid.UUID
	var userID uuid.UUID
	err = s.db.Unidentified(ctx, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT rotate_session($1, $2)`,
			auth.Digest(refreshToken), newDigest).Scan(&sessionID); err != nil {
			return err
		}
		if sessionID == nil {
			return nil
		}
		// Through the function rather than the table. Nothing here is identified yet -
		// that is what this call is for - so every policy on sessions hides every row,
		// and selecting from it returned nothing for a session rotated a line earlier.
		return tx.QueryRow(ctx, `SELECT session_owner($1)`, newDigest).Scan(&userID)
	})
	if err != nil {
		return nil, fmt.Errorf("sessions: rotating: %w", err)
	}
	if sessionID == nil {
		// Unknown, revoked or expired. An ordinary thing for a client that has been
		// offline, answered with a sign-in screen rather than an error page.
		return nil, ErrSignInFailed
	}

	return &Session{
		AccessToken:  s.signer.Issue(userID, time.Now()),
		RefreshToken: newToken,
		ExpiresAt:    time.Now().Add(auth.AccessTTL),
		UserID:       userID,
	}, nil
}

// SignOut ends this device's session and leaves the others alone.
func (s *Store) SignOut(ctx context.Context, refreshToken string) error {
	return s.db.Unidentified(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `SELECT revoke_session($1)`, auth.Digest(refreshToken))
		return err
	})
}

// SignOutEverywhere is for the person in the session and nobody else - the database
// refuses any other caller, so this is identified where the others are not.
func (s *Store) SignOutEverywhere(ctx context.Context, c db.Caller) (int, error) {
	var n int
	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT revoke_all_sessions($1)`, c.UserID).Scan(&n)
	})
	return n, err
}

// Identify turns an access token into a caller, or refuses.
func (s *Store) Identify(accessToken, requestID string) (db.Caller, error) {
	user, err := s.signer.Verify(accessToken, time.Now())
	if err != nil {
		return db.Caller{}, err
	}
	// No role. This used to say "caregiver" for every caller there was, and the trail
	// believed it - a care manager reading a whole building was written down as a
	// caregiver doing it. The database decides it now, from the membership that grants
	// the access, so there is nothing true for this to say and a guess would only be
	// waiting to be trusted again. See audit-attribution.sql.
	return db.Caller{UserID: user, RequestID: requestID}, nil
}

func (s *Store) issue(ctx context.Context, user uuid.UUID, device string) (*Session, error) {
	token, digest, err := auth.NewToken()
	if err != nil {
		return nil, err
	}
	err = s.db.Unidentified(ctx, func(tx pgx.Tx) error {
		var id uuid.UUID
		return tx.QueryRow(ctx, `SELECT start_session($1, $2, $3)`, user, digest, device).Scan(&id)
	})
	if err != nil {
		return nil, fmt.Errorf("sessions: starting: %w", err)
	}
	return &Session{
		AccessToken:  s.signer.Issue(user, time.Now()),
		RefreshToken: token,
		ExpiresAt:    time.Now().Add(auth.AccessTTL),
		UserID:       user,
	}, nil
}

// A real argon2id digest of a value nobody knows, used only to spend the same time on an
// address that does not exist as on one that does.
const decoyDigest = "$argon2id$v=19$m=19456,t=2,p=1$" +
	"Y2xvY2tjbG9ja2Nsb2Nr$" + "ZGVjb3lkZWNveWRlY295ZGVjb3lkZWNveWRlY295ZGVj"
