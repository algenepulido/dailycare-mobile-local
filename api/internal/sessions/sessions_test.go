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

func TestNobodySignsAnybodyElseOutOfEverything(t *testing.T) {
	s, _, mine := store(t)
	ctx := context.Background()

	// The database refuses to end sessions for anybody but the caller.
	_, err := s.SignOutEverywhere(ctx, db.Caller{UserID: uuid.New(), Role: "caregiver"})
	if err == nil {
		t.Fatal("signed somebody else out of everything")
	}

	if _, err := s.SignIn(ctx, knownEmail, knownPass, "a test"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SignOutEverywhere(ctx, db.Caller{UserID: mine, Role: "caregiver"}); err != nil {
		t.Fatalf("a person could not sign themselves out everywhere: %v", err)
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
