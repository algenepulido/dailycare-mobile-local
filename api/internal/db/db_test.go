package db

import (
	"context"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// These run against a real database with the model applied, because the thing under test
// is what the policies do, and a fake would only prove that the fake agrees with itself.
// DAILYCARE_TEST_DSN is set by api/test.sh, which builds one in a container.
func open(t *testing.T) *DB {
	t.Helper()
	dsn := os.Getenv("DAILYCARE_TEST_DSN")
	if dsn == "" {
		t.Skip("DAILYCARE_TEST_DSN is not set; run ./test.sh")
	}
	d, err := Open(context.Background(), dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(d.Close)
	return d
}

func TestInSessionRefusesAnEmptyCaller(t *testing.T) {
	d := open(t)
	err := d.InSession(context.Background(), Caller{}, func(pgx.Tx) error {
		t.Fatal("the function ran, and it should not have")
		return nil
	})
	if err != ErrNoCaller {
		t.Fatalf("want ErrNoCaller, got %v", err)
	}
}

func TestTheIdentityIsActuallySet(t *testing.T) {
	d := open(t)
	id := uuid.New()
	var got string
	err := d.InSession(context.Background(),
		Caller{UserID: id, Role: "caregiver", RequestID: "req-1"},
		func(tx pgx.Tx) error {
			return tx.QueryRow(context.Background(),
				`SELECT current_setting('app.user_id', true)`).Scan(&got)
		})
	if err != nil {
		t.Fatalf("in session: %v", err)
	}
	if got != id.String() {
		t.Fatalf("app.user_id is %q, want %q", got, id)
	}
}

// The one that matters for a pooled connection. SET rather than SET LOCAL would leave the
// previous caller's identity in place for whoever borrows the connection next, and under
// load that is one caregiver reading another's facility with nothing in the logs to say
// so. Run enough times to be sure a connection is being reused.
func TestTheIdentityDoesNotOutliveTheTransaction(t *testing.T) {
	d := open(t)
	ctx := context.Background()
	for i := 0; i < 20; i++ {
		if err := d.InSession(ctx, Caller{UserID: uuid.New(), Role: "caregiver"},
			func(pgx.Tx) error { return nil }); err != nil {
			t.Fatalf("in session: %v", err)
		}
		var leaked string
		if err := d.Unidentified(ctx, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx,
				`SELECT coalesce(current_setting('app.user_id', true), '')`).Scan(&leaked)
		}); err != nil {
			t.Fatalf("unidentified: %v", err)
		}
		if leaked != "" {
			t.Fatalf("round %d: the previous caller's id survived the transaction: %q", i, leaked)
		}
	}
}

// Not a claim about the application. The application role is what Cloud Run connects as,
// and a test that quietly ran as the owner would pass while proving nothing - which is the
// failure the whole architecture directory is built around.
func TestWeAreNotConnectedAsAnOwnerOrSuperuser(t *testing.T) {
	d := open(t)
	var user string
	var super bool
	err := d.Unidentified(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(),
			`SELECT current_user, coalesce((SELECT rolsuper FROM pg_roles WHERE rolname = current_user), false)`).
			Scan(&user, &super)
	})
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	if super {
		t.Fatalf("connected as %q, which is a superuser: every policy under test is bypassed", user)
	}
	if user != "dailycare_app" {
		t.Fatalf("connected as %q, want dailycare_app", user)
	}
}
