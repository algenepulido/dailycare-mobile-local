package records

import (
	"context"
	"errors"
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

// A family member reads the record and cannot write to it, and the database is what says so.
//
// The point of the test is not that filing fails - it is which failure. Until M4 the policy
// refusal came back as "that day was not something the record accepts", which is what a
// malformed mood gets, so a daughter was told her data was wrong when the truth was that
// recording care is not hers to do. Both are errors; only one of them is true.
//
// Also the other half of the same answer: she can read the day she cannot file.
func TestFamilyMayReadTheRecordAndNotWriteToIt(t *testing.T) {
	s, caregiver, resident := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	// Something to read, filed by the caregiver whose job it is.
	if _, err := s.File(ctx, caregiver, resident, on, aDay()); err != nil {
		t.Fatalf("the caregiver filing: %v", err)
	}

	daughter := grantFamily(t, resident)

	if _, err := s.Day(ctx, daughter, resident, on); err != nil {
		t.Fatalf("a family member reading the day they hold a grant for: %v", err)
	}

	// A day nobody has filed, and the one that is already there. Both go through the
	// insert, by different routes - the second retires the standing row first - and the
	// answer has to be the same refusal either way.
	for _, when := range []time.Time{
		time.Date(2026, 9, 24, 0, 0, 0, 0, time.UTC),
		on,
	} {
		if _, err := s.File(ctx, daughter, resident, when, aDay()); !errors.Is(err, ErrNotTheirsToFile) {
			t.Errorf("a family member filing %s: got %v, want ErrNotTheirsToFile",
				when.Format("2006-01-02"), err)
		}
	}
}

// A second account on the same resident, holding an active family grant and no membership.
// Seeded as the owner, like everything else here: creating a user and granting access are
// administrative acts and the application has no handler for either.
func grantFamily(t *testing.T, resident uuid.UUID) db.Caller {
	t.Helper()
	ctx := context.Background()
	c, err := pgx.Connect(ctx, os.Getenv("DAILYCARE_TEST_ADMIN_DSN"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close(ctx)

	var facility uuid.UUID
	if err := c.QueryRow(ctx,
		`SELECT facility_id FROM residents WHERE id = $1`, resident).Scan(&facility); err != nil {
		t.Fatal(err)
	}

	user := uuid.New()
	if _, err := c.Exec(ctx,
		`INSERT INTO users (id, email, display_name) VALUES ($1, $2, 'A Daughter')`,
		user, uuid.NewString()+"@example.test"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Exec(ctx,
		`INSERT INTO resident_contacts (facility_id, resident_id, user_id, relation, state)
		 VALUES ($1, $2, $3, 'child', 'active')`, facility, resident, user); err != nil {
		t.Fatal(err)
	}
	return db.Caller{UserID: user, RequestID: "t"}
}

// A day that was corrected says so on the day itself, not only in the history.
//
// The history selected amends_id and the single day did not, so the one screen a family
// member actually opens was the only place that could not tell them the record had changed.
// Which is the sentence this package's own comment makes - that a family can be shown a
// correction happened rather than a different past.
func TestADayThatWasCorrectedSaysSo(t *testing.T) {
	s, caller, resident := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	if _, err := s.File(ctx, caller, resident, on, aDay()); err != nil {
		t.Fatal(err)
	}
	first, err := s.Day(ctx, caller, resident, on)
	if err != nil {
		t.Fatal(err)
	}
	if first.Corrected {
		t.Error("a day filed once reports itself as corrected")
	}

	corrected := aDay()
	corrected.Note = "and a second look at it"
	if _, err := s.File(ctx, caller, resident, on, corrected); err != nil {
		t.Fatal(err)
	}
	after, err := s.Day(ctx, caller, resident, on)
	if err != nil {
		t.Fatal(err)
	}
	if !after.Corrected {
		t.Error("a day that replaced an earlier one does not report itself as corrected")
	}
	if after.Note == nil || *after.Note != "and a second look at it" {
		t.Errorf("the day that stands is not the correction: %+v", after.Note)
	}
}

// A family member is told who looked after their resident.
//
// They cannot resolve filed_by themselves: users is closed to them outside their own row,
// which is right and stays right - a family should not be able to read a building's staff
// list. care_day_filed_by_name is scoped to the record instead, so the name arrives attached
// to a day they may already read and gives no way to ask about anybody else.
func TestTheDaySaysWhoFiledIt(t *testing.T) {
	s, caregiver, resident := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	if _, err := s.File(ctx, caregiver, resident, on, aDay()); err != nil {
		t.Fatal(err)
	}

	// The caregiver seeded by ward() is called "A Nurse".
	got, err := s.Day(ctx, caregiver, resident, on)
	if err != nil {
		t.Fatal(err)
	}
	if got.FiledByName != "A Nurse" {
		t.Errorf("the caregiver reading their own day: got %q, want %q", got.FiledByName, "A Nurse")
	}

	daughter := grantFamily(t, resident)
	fromFamily, err := s.Day(ctx, daughter, resident, on)
	if err != nil {
		t.Fatalf("a family member reading the day: %v", err)
	}
	if fromFamily.FiledByName != "A Nurse" {
		t.Errorf("a family member reading the same day: got %q, want %q",
			fromFamily.FiledByName, "A Nurse")
	}
}

// Medication reaches a family as the caregiver's own record of it.
//
// Held back until milestone four on the reasoning that a tick is not a dispensing record.
// That was half the picture: medication_source has carried both 'caregiver' and
// 'pointclickcare' since the schema was written, and its comment says the family should be
// able to see which one they are reading. So it travels, marked.
func TestMedicationReachesTheFamilyAsTheCaregiversOwn(t *testing.T) {
	s, caregiver, resident := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	f := aDay()
	f.Medication = Medication{AM: true, PM: false, Supplemental: "Tylenol 500mg twice today"}
	if _, err := s.File(ctx, caregiver, resident, on, f); err != nil {
		t.Fatalf("filing: %v", err)
	}

	daughter := grantFamily(t, resident)
	got, err := s.Day(ctx, daughter, resident, on)
	if err != nil {
		t.Fatalf("a family member reading the day: %v", err)
	}

	byslot := map[string]MedicationRecord{}
	for _, m := range got.Medication {
		byslot[m.Slot] = m
	}
	if am, ok := byslot["am"]; !ok || am.Status != "given" {
		t.Errorf("the A.M tick did not reach the family: %+v", got.Medication)
	} else if am.RecordedBy != "A Nurse" {
		t.Errorf("the A.M tick is not attributed: got %q", am.RecordedBy)
	}
	// Not ticked is not a row. medication_status has 'not_recorded' for exactly that, and
	// absence says it more plainly than a row claiming nothing happened.
	if _, ok := byslot["pm"]; ok {
		t.Error("a slot nobody ticked produced a row")
	}
	if sup, ok := byslot["supplemental"]; !ok || sup.Detail != "Tylenol 500mg twice today" {
		t.Errorf("the supplemental dose did not reach the family: %+v", got.Medication)
	}
}

// A correction cannot take back a dose, and cannot duplicate one either.
//
// The form a correction opens does not carry medication forward - deliberately - so the
// second filing arrives with nothing ticked and the first filing's record stands. Re-sending
// the same tick is a no-op rather than a failure, which is what medication_events_one_per_slot
// and ON CONFLICT DO NOTHING are doing between them.
func TestCorrectingADayLeavesMedicationAlone(t *testing.T) {
	s, caregiver, resident := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	first := aDay()
	first.Medication = Medication{AM: true, PM: true, Supplemental: "Paracetamol"}
	if _, err := s.File(ctx, caregiver, resident, on, first); err != nil {
		t.Fatal(err)
	}

	// A correction as the app sends one: medication empty, because the form does not load it.
	corrected := aDay()
	corrected.Note = "and a second look at it"
	if _, err := s.File(ctx, caregiver, resident, on, corrected); err != nil {
		t.Fatalf("correcting: %v", err)
	}

	got, err := s.Day(ctx, caregiver, resident, on)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Medication) != 3 {
		t.Fatalf("medication changed with the correction: %+v", got.Medication)
	}

	// And filing the same ticks again neither fails nor doubles them.
	if _, err := s.File(ctx, caregiver, resident, on, first); err != nil {
		t.Fatalf("re-sending the same ticks: %v", err)
	}
	again, err := s.Day(ctx, caregiver, resident, on)
	if err != nil {
		t.Fatal(err)
	}
	if len(again.Medication) != 3 {
		t.Errorf("re-filing duplicated medication: %+v", again.Medication)
	}
}
