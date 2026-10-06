package facility

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/dailycare-hq/dailycare-api/internal/auth"
	"github.com/dailycare-hq/dailycare-api/internal/db"
)

// A building, somebody who runs it, somebody who works in it, and a second building that is
// a real place rather than a hypothetical. Every refusal below is aimed at something: a
// check that tries to administer a facility nobody is in proves nothing about the policies.
type world struct {
	store             *Store
	cedar, birch      uuid.UUID
	priya, maria, ben db.Caller
	priyaMember       uuid.UUID
	mariaMember       uuid.UUID
	benMember         uuid.UUID
}

func seed(t *testing.T) world {
	t.Helper()
	dsn, admin := os.Getenv("DAILYCARE_TEST_DSN"), os.Getenv("DAILYCARE_TEST_ADMIN_DSN")
	if dsn == "" || admin == "" {
		t.Skip("DAILYCARE_TEST_DSN is not set; run ./test.sh")
	}
	d, err := db.Open(context.Background(), dsn)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(d.Close)

	c, err := pgx.Connect(context.Background(), admin)
	if err != nil {
		t.Fatalf("admin connect: %v", err)
	}
	defer c.Close(context.Background())
	ctx := context.Background()

	w := world{store: New(d), cedar: uuid.New(), birch: uuid.New()}
	tag := uuid.NewString()[:8]

	for _, f := range []struct {
		id   uuid.UUID
		name string
	}{{w.cedar, "Cedar " + tag}, {w.birch, "Birch " + tag}} {
		if _, err := c.Exec(ctx,
			`INSERT INTO facilities (id, name, timezone) VALUES ($1, $2, 'America/Chicago')`,
			f.id, f.name); err != nil {
			t.Fatalf("seeding a facility: %v", err)
		}
	}

	person := func(name, role string, at uuid.UUID) (db.Caller, uuid.UUID) {
		id := uuid.New()
		if _, err := c.Exec(ctx,
			`INSERT INTO users (id, email, display_name) VALUES ($1, $2, $3)`,
			id, fmt.Sprintf("%s-%s@example.test", name, tag), name); err != nil {
			t.Fatalf("seeding %s: %v", name, err)
		}
		member := uuid.New()
		if _, err := c.Exec(ctx,
			`INSERT INTO facility_members (id, facility_id, user_id, role, state)
			 VALUES ($1, $2, $3, $4, 'active')`, member, at, id, role); err != nil {
			t.Fatalf("seeding %s's membership: %v", name, err)
		}
		return db.Caller{UserID: id, RequestID: "test"}, member
	}

	w.priya, w.priyaMember = person("priya", "care_manager", w.cedar)
	w.maria, w.mariaMember = person("maria", "caregiver", w.cedar)
	w.ben, w.benMember = person("ben", "care_manager", w.birch)
	return w
}

func invite(t *testing.T, w world, as db.Caller, at uuid.UUID, who, role string) (Invited, error) {
	t.Helper()
	token, digest, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	return w.store.Invite(context.Background(), as, at,
		who+"-"+uuid.NewString()[:8]+"@example.test", who, role, digest, token)
}

func TestAManagerPutsSomebodyInTheirBuilding(t *testing.T) {
	w := seed(t)
	got, err := invite(t, w, w.priya, w.cedar, "tomas", "caregiver")
	if err != nil {
		t.Fatalf("inviting: %v", err)
	}
	if got.Member.State != "invited" {
		t.Errorf("a new membership should open invited, got %q", got.Member.State)
	}
	if got.Member.EndedAt != nil {
		t.Error("a new membership should not already be over")
	}
	// The one time this exists outside the recipient's hands.
	if got.Link == "" {
		t.Error("somebody with no way in should be handed one")
	}

	members, err := w.store.Members(context.Background(), w.priya, w.cedar)
	if err != nil {
		t.Fatalf("reading the building: %v", err)
	}
	var found bool
	for _, m := range members {
		if m.ID == got.Member.ID {
			found = true
		}
	}
	if !found {
		t.Error("the person just invited is not in the building they were invited to")
	}
}

func TestInvitingIsNotACaregiversToDo(t *testing.T) {
	w := seed(t)
	if _, err := invite(t, w, w.maria, w.cedar, "nope", "caregiver"); !errors.Is(err, ErrNotTheirs) {
		t.Fatalf("a caregiver inviting should be refused, got %v", err)
	}
}

func TestAManagerCannotReachAnotherBuilding(t *testing.T) {
	w := seed(t)
	// Priya runs Cedar. Birch is Ben's, and she has no business adding anybody to it.
	if _, err := invite(t, w, w.priya, w.birch, "nope", "caregiver"); !errors.Is(err, ErrNotTheirs) {
		t.Fatalf("inviting into another building should be refused, got %v", err)
	}
}

func TestAMembershipEndsOnADateRatherThanBeingDeleted(t *testing.T) {
	w := seed(t)
	ctx := context.Background()
	if err := w.store.End(ctx, w.priya, w.mariaMember); err != nil {
		t.Fatalf("ending: %v", err)
	}
	members, err := w.store.Members(ctx, w.priya, w.cedar)
	if err != nil {
		t.Fatal(err)
	}
	var seen bool
	for _, m := range members {
		if m.ID == w.mariaMember {
			seen = true
			if m.EndedAt == nil {
				t.Error("an ended membership should carry the date it ended")
			}
			if m.State != "revoked" {
				t.Errorf("an ended membership should be revoked, got %q", m.State)
			}
		}
	}
	// "Without losing what they filed" starts here: the row is still readable, so a day
	// with their name on it still has somebody behind it.
	if !seen {
		t.Error("an ended membership disappeared from the building")
	}
}

func TestTheLastCareManagerCannotBeEnded(t *testing.T) {
	w := seed(t)
	err := w.store.End(context.Background(), w.priya, w.priyaMember)
	if !errors.Is(err, ErrLastManager) {
		t.Fatalf("ending the last manager should say so by name, got %v", err)
	}
	// And it is the last-manager answer rather than a flat refusal, which is the whole
	// reason End asks the database a second question.
	if errors.Is(err, ErrNotTheirs) {
		t.Error("the refusal lost the reason that makes it actionable")
	}
}

func TestEndingSomebodyElsesBuildingIsNotEvenVisible(t *testing.T) {
	w := seed(t)
	// Ben's membership is at Birch. Priya cannot read it, so she is told it does not exist
	// rather than that it is not hers - a uuid should not be a way to find out who works
	// where.
	if err := w.store.End(context.Background(), w.priya, w.benMember); !errors.Is(err, ErrNotVisible) {
		t.Fatalf("a membership at another building should be invisible, got %v", err)
	}
}

func TestACaregiverSeesTheBuildingAndCannotAdministerIt(t *testing.T) {
	w := seed(t)
	ctx := context.Background()
	members, err := w.store.Members(ctx, w.maria, w.cedar)
	if err != nil {
		t.Fatalf("a caregiver reading their own building: %v", err)
	}
	if len(members) == 0 {
		t.Fatal("a caregiver should see the building they work in")
	}
	// Visible, and not theirs. The two halves of the same table, which is why these are
	// different errors and different statuses.
	if err := w.store.End(ctx, w.maria, w.priyaMember); !errors.Is(err, ErrNotTheirs) {
		t.Fatalf("a caregiver ending a membership should be refused as theirs-not, got %v", err)
	}
}

func TestAnAddressThatAlreadyHasAnAccount(t *testing.T) {
	w := seed(t)
	ctx := context.Background()
	token, digest, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	email := "taken-" + uuid.NewString()[:8] + "@example.test"
	if _, err := w.store.Invite(ctx, w.priya, w.cedar, email, "Tomas", "caregiver", digest, token); err != nil {
		t.Fatalf("the first invitation: %v", err)
	}
	token2, digest2, err := auth.NewToken()
	if err != nil {
		t.Fatal(err)
	}
	// Deferred rather than solved. The manager is told plainly instead of being handed a
	// constraint name, and nothing half-written is left behind because it is one transaction.
	if _, err := w.store.Invite(ctx, w.priya, w.cedar, email, "Tomas", "caregiver", digest2, token2); !errors.Is(err, ErrAccountExists) {
		t.Fatalf("a second account on one address should say so, got %v", err)
	}
}
