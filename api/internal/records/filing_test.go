package records

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/dailycare-hq/dailycare-api/internal/db"
)

// A caregiver, a facility, a resident, and the assignment that lets one see the other.
// Seeded as the owner because none of it is something the application may create.
func ward(t *testing.T) (*Store, db.Caller, uuid.UUID) {
	t.Helper()
	dsn, admin := os.Getenv("DAILYCARE_TEST_DSN"), os.Getenv("DAILYCARE_TEST_ADMIN_DSN")
	if dsn == "" || admin == "" {
		t.Skip("DAILYCARE_TEST_DSN is not set; run ./test.sh")
	}
	d, err := db.Open(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(d.Close)

	c, err := pgx.Connect(context.Background(), admin)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(context.Background())
	ctx := context.Background()

	facility, user, resident, member := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO facilities (id, name, timezone) VALUES ($1, 'Cedar', 'America/Chicago')`,
			[]any{facility}},
		{`INSERT INTO users (id, email, display_name) VALUES ($1, $2, 'A Nurse')`,
			[]any{user, uuid.NewString() + "@example.test"}},
		{`INSERT INTO facility_members (id, facility_id, user_id, role, state)
		  VALUES ($1, $2, $3, 'caregiver', 'active')`, []any{member, facility, user}},
		{`INSERT INTO residents (id, facility_id, display_name) VALUES ($1, $2, 'Cathy')`,
			[]any{resident, facility}},
		{`INSERT INTO assignments (facility_id, resident_id, facility_member_id)
		  VALUES ($1, $2, $3)`, []any{facility, resident, member}},
	} {
		if _, err := c.Exec(ctx, q.sql, q.args...); err != nil {
			t.Fatalf("seeding: %v", err)
		}
	}
	return New(d), db.Caller{UserID: user, Role: "caregiver", RequestID: "t"}, resident
}

func aDay() Filing {
	return Filing{
		Mood: "calm", Appetite: "fair", Sleep: "restless",
		Note: "settled evening", Shower: true,
		Meals:    []Meal{{Slot: "breakfast", Happened: true, Amount: ptr("most")}},
		Concerns: []string{"pain"},
	}
}

func ptr(s string) *string { return &s }

func TestFilingADayAndReadingItBack(t *testing.T) {
	s, caller, resident := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	id, err := s.File(ctx, caller, resident, on, aDay())
	if err != nil {
		t.Fatalf("filing: %v", err)
	}
	if id == uuid.Nil {
		t.Fatal("no id came back")
	}

	got, err := s.Day(ctx, caller, resident, on)
	if err != nil {
		t.Fatalf("reading it back: %v", err)
	}
	if got.Note == nil || *got.Note != "settled evening" {
		t.Fatalf("the note did not come back: %+v", got)
	}
}

// The design, and the reason care_days carries a trigger and a partial unique index rather
// than an UPDATE. A correction is a new row; the original stays readable; a family can be
// shown that a correction happened rather than a different past.
func TestAmendingLeavesTheOriginalReadable(t *testing.T) {
	s, caller, resident := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	first, err := s.File(ctx, caller, resident, on, aDay())
	if err != nil {
		t.Fatal(err)
	}

	corrected := aDay()
	corrected.Note = "fall in the corridor, GP called"
	corrected.Concerns = []string{"fall_or_near_fall"}
	second, err := s.File(ctx, caller, resident, on, corrected)
	if err != nil {
		t.Fatalf("amending: %v", err)
	}
	if second == first {
		t.Fatal("the same row came back, so this was an update rather than an amendment")
	}

	admin, _ := pgx.Connect(ctx, os.Getenv("DAILYCARE_TEST_ADMIN_DSN"))
	defer admin.Close(ctx)

	var note string
	var superseded *time.Time
	if err := admin.QueryRow(ctx,
		`SELECT note, superseded_at FROM care_days WHERE id = $1`, first).Scan(&note, &superseded); err != nil {
		t.Fatalf("the original is gone: %v", err)
	}
	if note != "settled evening" {
		t.Fatalf("the original now reads %q, so it was rewritten", note)
	}
	if superseded == nil {
		t.Fatal("the original was not stamped superseded, so two rows are current")
	}

	var amends *uuid.UUID
	if err := admin.QueryRow(ctx,
		`SELECT amends_id FROM care_days WHERE id = $1`, second).Scan(&amends); err != nil {
		t.Fatal(err)
	}
	if amends == nil || *amends != first {
		t.Fatal("the correction does not point back at what it corrected")
	}

	// And the current day is the correction, not the original.
	got, err := s.Day(ctx, caller, resident, on)
	if err != nil {
		t.Fatal(err)
	}
	if got.Note == nil || *got.Note != "fall in the corridor, GP called" {
		t.Fatalf("reading the day gave the old note: %+v", got)
	}
}

// The database refuses to rewrite a filed day. Worth its own check, because the trigger is
// what makes the amendment design a property of the table rather than of this package.
func TestTheDatabaseRefusesToRewriteAFiledDay(t *testing.T) {
	s, caller, resident := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	id, err := s.File(ctx, caller, resident, on, aDay())
	if err != nil {
		t.Fatal(err)
	}
	admin, _ := pgx.Connect(ctx, os.Getenv("DAILYCARE_TEST_ADMIN_DSN"))
	defer admin.Close(ctx)

	_, err = admin.Exec(ctx, `UPDATE care_days SET note = 'settled evening, no concerns' WHERE id = $1`, id)
	if err == nil {
		t.Fatal("a filed care note was rewritten in place")
	}
	// And the message names the column without repeating what it said.
	if got := err.Error(); !contains(got, "note") {
		t.Fatalf("the refusal does not say which column: %v", got)
	}
	if contains(err.Error(), "no concerns") {
		t.Fatalf("the refusal quotes the value it refused: %v", err)
	}
}

func contains(haystack, needle string) bool {
	return len(haystack) >= len(needle) && (haystack == needle ||
		len(needle) == 0 || indexOf(haystack, needle) >= 0)
}

func indexOf(h, n string) int {
	for i := 0; i+len(n) <= len(h); i++ {
		if h[i:i+len(n)] == n {
			return i
		}
	}
	return -1
}

// The whole day, not a quarter of it.
//
// Day() used to select mood, note, filed_by and filed_at and nothing else, so an endpoint
// called "the day" answered with a fraction of one and the meals, the concerns, the
// hygiene, the appetite and the sleep were all simply absent. Nothing had noticed because
// nothing read a day back yet.
func TestReadingADayReturnsEveryPartOfIt(t *testing.T) {
	s, caller, resident := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	filed := Filing{
		Mood: "anxious", Appetite: "poor", Sleep: "up_a_lot",
		Note: "restless after lunch", Shower: true, Grooming: false,
		Meals: []Meal{
			{Slot: "dinner", Happened: false},
			{Slot: "breakfast", Happened: true, Amount: ptr("all")},
			{Slot: "lunch", Happened: true, Amount: ptr("half")},
		},
		Concerns: []string{"pain", "fall_or_near_fall"},
	}
	if _, err := s.File(ctx, caller, resident, on, filed); err != nil {
		t.Fatalf("filing: %v", err)
	}

	got, err := s.Day(ctx, caller, resident, on)
	if err != nil {
		t.Fatalf("reading it back: %v", err)
	}

	for _, c := range []struct {
		field string
		got   *string
		want  string
	}{
		{"mood", got.Mood, "anxious"},
		{"appetite", got.Appetite, "poor"},
		{"sleep", got.Sleep, "up_a_lot"},
		{"note", got.Note, "restless after lunch"},
	} {
		if c.got == nil || *c.got != c.want {
			t.Errorf("%s: wanted %q, got %v", c.field, c.want, c.got)
		}
	}
	if got.Shower == nil || !*got.Shower {
		t.Errorf("shower: wanted true, got %v", got.Shower)
	}
	if got.Grooming == nil || *got.Grooming {
		t.Errorf("grooming: wanted false, got %v", got.Grooming)
	}

	// Filed out of order on purpose. A caregiver reads breakfast, lunch, dinner, and the
	// order a row happened to be inserted in is not that.
	if len(got.Meals) != 3 {
		t.Fatalf("wanted three meals, got %d: %+v", len(got.Meals), got.Meals)
	}
	for i, want := range []string{"breakfast", "lunch", "dinner"} {
		if got.Meals[i].Slot != want {
			t.Errorf("meal %d: wanted %s, got %s", i, want, got.Meals[i].Slot)
		}
	}
	if got.Meals[1].Amount == nil || *got.Meals[1].Amount != "half" {
		t.Errorf("lunch amount did not come back: %+v", got.Meals[1])
	}
	if got.Meals[2].Happened {
		t.Error("dinner was filed as not happened and came back as happened")
	}

	if len(got.Concerns) != 2 {
		t.Fatalf("wanted two concerns, got %+v", got.Concerns)
	}
}

// A day nobody has filed is an empty day, and the difference has to be readable. Absent
// rather than false: "no shower recorded" and "they did not have a shower" are different
// things to put in front of a family.
func TestAnUnfiledDayIsEmptyRatherThanMissing(t *testing.T) {
	s, caller, resident := ward(t)
	ctx := context.Background()

	got, err := s.Day(ctx, caller, resident, time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("reading a day nobody filed: %v", err)
	}
	if got.FiledAt != nil || got.Mood != nil || got.Shower != nil {
		t.Errorf("an unfiled day came back with something in it: %+v", got)
	}
	// Never null, so a caller can range over them without checking first.
	if got.Meals == nil || got.Concerns == nil {
		t.Errorf("meals and concerns should be empty, not absent: %+v", got)
	}
	if len(got.Meals) != 0 || len(got.Concerns) != 0 {
		t.Errorf("an unfiled day has no meals and no concerns: %+v", got)
	}
}
