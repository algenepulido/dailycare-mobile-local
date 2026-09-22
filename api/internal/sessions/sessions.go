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
	return db.Caller{UserID: user, Role: "caregiver", RequestID: requestID}, nil
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
