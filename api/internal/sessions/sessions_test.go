package sessions

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/dailycare-hq/dailycare-api/internal/auth"
	"github.com/dailycare-hq/dailycare-api/internal/db"
)

const (
	knownEmail = "nurse@example.test"
	knownPass  = "a reasonable passphrase"
)

func store(t *testing.T) (*Store, *db.DB, uuid.UUID) {
	t.Helper()
	dsn := os.Getenv("DAILYCARE_TEST_DSN")
	if dsn == "" {
		t.Skip("DAILYCARE_TEST_DSN is not set; run ./test.sh")
	}
	d, err := db.Open(context.Background(), dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(d.Close)

	// Seeded as the owner, because the application cannot create a user - that is an
	// administrative act and there is no handler for it yet.
	admin := os.Getenv("DAILYCARE_TEST_ADMIN_DSN")
	c, err := pgx.Connect(context.Background(), admin)
	if err != nil {
		t.Fatalf("admin connect: %v", err)
	}
	defer c.Close(context.Background())

	digest, err := auth.Hash(knownPass)
	if err != nil {
		t.Fatal(err)
	}
	// One user, upserted by address. Every test in this file signs in as the same person,
	// and giving each its own would make the sessions in the table belong to different
	// people - which is the thing some of them are checking.
	var namedID uuid.UUID
	if err := c.QueryRow(context.Background(),
		`INSERT INTO users (email, display_name, password_hash) VALUES ($1, 'A Nurse', $2)
		 ON CONFLICT (email) DO UPDATE SET password_hash = excluded.password_hash
		 RETURNING id`, knownEmail, digest).Scan(&namedID); err != nil {
		t.Fatalf("seeding: %v", err)
	}

	signer, err := auth.NewSigner([]byte("0123456789abcdef0123456789abcdef"))
	if err != nil {
		t.Fatal(err)
	}
	return New(d, signer), d, namedID
}

func TestSignInAndTheSessionWorks(t *testing.T) {
	s, _, want := store(t)
	ctx := context.Background()

	got, err := s.SignIn(ctx, knownEmail, knownPass, "a test")
	if err != nil {
		t.Fatalf("signing in: %v", err)
	}
	if got.UserID != want {
		t.Fatalf("signed in as %s, want %s", got.UserID, want)
	}
	if got.AccessToken == "" || got.RefreshToken == "" {
		t.Fatal("a session with no tokens in it")
	}

	caller, err := s.Identify(got.AccessToken, "req-1")
	if err != nil {
		t.Fatalf("the access token it just issued does not verify: %v", err)
	}
	if caller.UserID != want {
		t.Fatalf("the token identifies %s, want %s", caller.UserID, want)
	}
}

// The four ways to fail have to be one answer. "This address exists" is worth having if
// the next step is a mail to a caregiver about a resident they know by name.
func TestEveryFailureLooksTheSame(t *testing.T) {
	s, _, _ := store(t)
	ctx := context.Background()

	for _, c := range []struct{ name, email, pass string }{
		{"wrong password", knownEmail, "not the passphrase"},
		{"unknown address", "nobody@example.test", knownPass},
		{"empty password", knownEmail, ""},
		{"empty everything", "", ""},
	} {
		if _, err := s.SignIn(ctx, c.email, c.pass, "a test"); !errors.Is(err, ErrSignInFailed) {
			t.Errorf("%s: got %v, want ErrSignInFailed", c.name, err)
		}
	}
}

func TestRefreshRotatesAndTheOldTokenDies(t *testing.T) {
	s, _, _ := store(t)
	ctx := context.Background()
	first, err := s.SignIn(ctx, knownEmail, knownPass, "a test")
	if err != nil {
		t.Fatal(err)
	}

	second, err := s.Refresh(ctx, first.RefreshToken)
	if err != nil {
		t.Fatalf("refreshing: %v", err)
	}
	if second.RefreshToken == first.RefreshToken {
		t.Fatal("the refresh token did not change, so nothing rotated")
	}
	if second.UserID != first.UserID {
		t.Fatal("the rotation changed who the session is for")
	}

	// The one that matters: a stolen token stops working the moment the real client uses
	// theirs. Not an error - a client that has been offline gets a sign-in screen.
	if _, err := s.Refresh(ctx, first.RefreshToken); !errors.Is(err, ErrSignInFailed) {
		t.Fatalf("the old refresh token still works: %v", err)
	}
}

func TestSignOutEndsThisDeviceAndLeavesOthers(t *testing.T) {
	s, _, _ := store(t)
	ctx := context.Background()
	phone, err := s.SignIn(ctx, knownEmail, knownPass, "her phone")
	if err != nil {
		t.Fatal(err)
	}
	tablet, err := s.SignIn(ctx, knownEmail, knownPass, "the ward tablet")
	if err != nil {
		t.Fatal(err)
	}

	if err := s.SignOut(ctx, phone.RefreshToken); err != nil {
		t.Fatalf("signing out: %v", err)
	}
	if _, err := s.Refresh(ctx, phone.RefreshToken); !errors.Is(err, ErrSignInFailed) {
		t.Fatal("the signed-out device can still refresh")
	}
	if _, err := s.Refresh(ctx, tablet.RefreshToken); err != nil {
		t.Fatalf("signing out one device ended another: %v", err)
	}
}

// Two layers, and they are different claims.
//
// The API cannot express the attack: SignOutEverywhere takes a Caller and uses its UserID
// as the target, so there is no parameter for somebody else. The first version of this
// test passed a different uuid and expected a refusal, which could never happen - it was
// asserting something it had no way to reach.
//
// The database refuses it independently, and that is worth its own check because the API
// is not the only thing that will ever call these functions.
func TestSigningOutEverywhereOnlyEverEndsYourOwn(t *testing.T) {
	s, d, mine := store(t)
	ctx := context.Background()

	if _, err := s.SignIn(ctx, knownEmail, knownPass, "a test"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SignOutEverywhere(ctx, db.Caller{UserID: mine, Role: "caregiver"}); err != nil {
		t.Fatalf("a person could not sign themselves out everywhere: %v", err)
	}

	// The same function, asked directly with an identity that is not the target. This is
	// the shape the API has no way to produce, and the database still has to refuse it.
	stranger := uuid.New()
	err := d.InSession(ctx, db.Caller{UserID: stranger, Role: "caregiver"}, func(tx pgx.Tx) error {
		var n int
		return tx.QueryRow(ctx, `SELECT revoke_all_sessions($1)`, mine).Scan(&n)
	})
	if err == nil {
		t.Fatal("the database let one person end another's sessions")
	}
}

func TestAnExpiredAccessTokenIsRefused(t *testing.T) {
	s, _, _ := store(t)
	got, err := s.SignIn(context.Background(), knownEmail, knownPass, "a test")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.signer.Verify(got.AccessToken, time.Now().Add(auth.AccessTTL+time.Minute)); err == nil {
		t.Fatal("an expired access token verified")
	}
}

// Which face of the app an account gets, asked of the database rather than decided here.
//
// Four states from one account, because the interesting one is the account that is both: a
// care manager whose own mother lives in their building holds a membership and a grant at
// the same time, and resident_relation has 'self' and 'child' precisely because that
// happens. They can file, so they must get the app that files.
func TestWhatKindOfAccountThisIs(t *testing.T) {
	s, _, user := store(t)
	ctx := context.Background()
	caller := db.Caller{UserID: user, RequestID: "t"}

	admin, err := pgx.Connect(ctx, os.Getenv("DAILYCARE_TEST_ADMIN_DSN"))
	if err != nil {
		t.Fatalf("admin connect: %v", err)
	}
	defer admin.Close(ctx)

	// A building with somebody in it, so there is a membership and a grant to give.
	facility, resident, member := uuid.New(), uuid.New(), uuid.New()
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO facilities (id, name, timezone) VALUES ($1, 'Cedar', 'America/Chicago')`,
			[]any{facility}},
		{`INSERT INTO residents (id, facility_id, display_name) VALUES ($1, $2, 'Cathy')`,
			[]any{resident, facility}},
	} {
		if _, err := admin.Exec(ctx, q.sql, q.args...); err != nil {
			t.Fatalf("seeding: %v", err)
		}
	}

	kind := func(t *testing.T) Kind {
		t.Helper()
		got, err := s.Account(ctx, caller)
		if err != nil {
			t.Fatalf("reading the account: %v", err)
		}
		if got.DisplayName != "A Nurse" || got.UserID != user {
			t.Fatalf("got %q / %s, want A Nurse / %s", got.DisplayName, got.UserID, user)
		}
		return got.Kind
	}

	// Nothing. An account that exists and is linked to nobody - a caregiver whose
	// membership ended, or a family member whose last grant was withdrawn. Not a fault,
	// and the app has to say something true about it.
	if got := kind(t); got != None {
		t.Errorf("linked to nobody: got %q, want %q", got, None)
	}

	if _, err := admin.Exec(ctx,
		`INSERT INTO facility_members (id, facility_id, user_id, role, state)
		 VALUES ($1, $2, $3, 'caregiver', 'active')`, member, facility, user); err != nil {
		t.Fatalf("seeding a membership: %v", err)
	}
	if got := kind(t); got != Staff {
		t.Errorf("a live membership: got %q, want %q", got, Staff)
	}

	// Ended by its date, not deleted and not a state: access_state is invited, active,
	// revoked, and a caregiver who leaves is none of those - ended_at is the column the
	// schema gives that, and app_my_facilities() requires it to be null.
	if _, err := admin.Exec(ctx,
		`UPDATE facility_members SET ended_at = now() WHERE id = $1`,
		member); err != nil {
		t.Fatal(err)
	}
	if got := kind(t); got != None {
		t.Errorf("a membership that ended: got %q, want %q", got, None)
	}

	if _, err := admin.Exec(ctx,
		`INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state)
		 VALUES ($1, $2, $3, 'child', 'active')`, facility, resident, user); err != nil {
		t.Fatalf("seeding a grant: %v", err)
	}
	if got := kind(t); got != Family {
		t.Errorf("an active grant and no membership: got %q, want %q", got, Family)
	}

	// Both at once, which is the case the order exists for.
	if _, err := admin.Exec(ctx,
		`UPDATE facility_members SET ended_at = NULL WHERE id = $1`,
		member); err != nil {
		t.Fatal(err)
	}
	if got := kind(t); got != Staff {
		t.Errorf("a membership and a grant together: got %q, want %q", got, Staff)
	}

	// A grant that was withdrawn stops counting, which is the whole of what revoking does.
	if _, err := admin.Exec(ctx,
		`UPDATE facility_members SET ended_at = now() WHERE id = $1`, member); err != nil {
		t.Fatal(err)
	}
	if _, err := admin.Exec(ctx,
		`UPDATE resident_contacts SET state = 'revoked', revoked_at = now()
		  WHERE user_id = $1 AND resident_id = $2`, user, resident); err != nil {
		t.Fatal(err)
	}
	if got := kind(t); got != None {
		t.Errorf("a withdrawn grant: got %q, want %q", got, None)
	}
}
