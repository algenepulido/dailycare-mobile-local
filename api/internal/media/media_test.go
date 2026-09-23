package media

import (
	"context"
	"errors"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/dailycare-hq/dailycare-api/internal/db"
)

// A signer that records what it was asked and hands back something recognisable. The real
// one talks to Cloud Storage; what is under test here is what it gets asked for.
type recorder struct {
	bucket, object, contentType string
	until                       time.Time
	err                         error
}

func (r *recorder) SignedPutURL(_ context.Context, bucket, object, contentType string,
	until time.Time) (string, error) {
	r.bucket, r.object, r.contentType, r.until = bucket, object, contentType, until
	if r.err != nil {
		return "", r.err
	}
	return "https://storage.example/" + object + "?signed", nil
}

func (r *recorder) SignedGetURL(_ context.Context, bucket, object string,
	until time.Time) (string, error) {
	r.bucket, r.object, r.until = bucket, object, until
	// No content type on a read, and the recorder keeps whatever the last call set so a
	// test can assert that this one did not pin one.
	if r.err != nil {
		return "", r.err
	}
	return "https://storage.example/" + object + "?read", nil
}

func ward(t *testing.T) (*Store, *recorder, db.Caller, uuid.UUID, uuid.UUID) {
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
		{`INSERT INTO facilities (id, name, timezone) VALUES ($1,'Cedar','America/Chicago')`, []any{facility}},
		{`INSERT INTO users (id, email, display_name) VALUES ($1,$2,'A Nurse')`,
			[]any{user, uuid.NewString() + "@example.test"}},
		{`INSERT INTO facility_members (id, facility_id, user_id, role, state)
		  VALUES ($1,$2,$3,'caregiver','active')`, []any{member, facility, user}},
		{`INSERT INTO residents (id, facility_id, display_name) VALUES ($1,$2,'Cathy')`,
			[]any{resident, facility}},
		{`INSERT INTO assignments (facility_id, resident_id, facility_member_id)
		  VALUES ($1,$2,$3)`, []any{facility, resident, member}},
	} {
		if _, err := c.Exec(ctx, q.sql, q.args...); err != nil {
			t.Fatalf("seeding: %v", err)
		}
	}
	r := &recorder{}
	return New(d, "dc-test-media", r), r, db.Caller{UserID: user, Role: "caregiver"}, resident, facility
}

func TestOfferingSomewhereToPutAPhotograph(t *testing.T) {
	s, sig, caller, resident, facility := ward(t)
	up, err := s.Offer(context.Background(), caller, resident, nil, "image/jpeg", 2_400_000)
	if err != nil {
		t.Fatalf("offering: %v", err)
	}
	if up.URL == "" || up.ObjectID == uuid.Nil {
		t.Fatal("nothing came back")
	}
	// The facility first, because that is what the CHECK constraint reads.
	if !strings.HasPrefix(sig.object, facility.String()+"/") {
		t.Fatalf("the object path does not start with the facility: %s", sig.object)
	}
	if !strings.Contains(sig.object, resident.String()) {
		t.Fatalf("the object path does not name the resident: %s", sig.object)
	}
	if sig.contentType != "image/jpeg" {
		t.Fatalf("signed for %q", sig.contentType)
	}
	if d := time.Until(sig.until); d > UploadWindow+time.Minute || d < time.Minute {
		t.Fatalf("the window is %v", d)
	}
}

// The caller does not choose the path, and the table would refuse one that pointed
// elsewhere even if this package were wrong about it. Worth its own check, because that
// constraint is the thing standing between a crafted request and another building's
// photograph.
func TestARowCannotPointAtAnotherBuildingsObject(t *testing.T) {
	_, _, _, _, facility := ward(t)
	ctx := context.Background()
	admin, _ := pgx.Connect(ctx, os.Getenv("DAILYCARE_TEST_ADMIN_DSN"))
	defer admin.Close(ctx)

	var resident uuid.UUID
	if err := admin.QueryRow(ctx,
		`SELECT id FROM residents WHERE facility_id = $1`, facility).Scan(&resident); err != nil {
		t.Fatal(err)
	}
	var user uuid.UUID
	admin.QueryRow(ctx, `SELECT user_id FROM facility_members WHERE facility_id = $1`, facility).Scan(&user)

	elsewhere := uuid.New().String() + "/somebody-elses/photo.jpg"
	_, err := admin.Exec(ctx, `
		INSERT INTO media_objects
		  (facility_id, resident_id, bucket, object_path, content_type, byte_size, uploaded_by)
		VALUES ($1,$2,'dc-test-media',$3,'image/jpeg',1,$4)`,
		facility, resident, elsewhere, user)
	if err == nil {
		t.Fatal("a row was written pointing at another facility's object")
	}
	if !strings.Contains(err.Error(), "object_path_is_under_its_facility") {
		t.Fatalf("refused, but not by the constraint that should have: %v", err)
	}
}

func TestAResidentYouCannotSeeGetsNoUploadURL(t *testing.T) {
	s, _, caller, _, _ := ward(t)
	_, err := s.Offer(context.Background(), caller, uuid.New(), nil, "image/jpeg", 1000)
	if !errors.Is(err, ErrNotVisible) {
		t.Fatalf("got %v, want ErrNotVisible", err)
	}
}

func TestOnlyPhotographs(t *testing.T) {
	s, _, caller, resident, _ := ward(t)
	for _, ct := range []string{"application/pdf", "text/html", "", "image/svg+xml"} {
		if _, err := s.Offer(context.Background(), caller, resident, nil, ct, 100); err == nil {
			t.Errorf("%q was accepted", ct)
		}
	}
}

// Two photographs never land on the same object, which would be one overwriting the other
// - and the API cannot overwrite, so the second upload would fail rather than replace.
func TestTwoOffersNeverNameTheSameObject(t *testing.T) {
	s, sig, caller, resident, _ := ward(t)
	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		if _, err := s.Offer(context.Background(), caller, resident, nil, "image/jpeg", 1); err != nil {
			t.Fatal(err)
		}
		if seen[sig.object] {
			t.Fatalf("the same object path came up twice: %s", sig.object)
		}
		seen[sig.object] = true
	}
}

// If signing fails the row must not be left behind: a media_objects row with no object is
// a photograph the retention job will look for and not find.
func TestAFailedSigningLeavesNoRow(t *testing.T) {
	s, sig, caller, resident, _ := ward(t)
	sig.err = errors.New("signBlob said no")
	ctx := context.Background()

	before := countRows(t)
	if _, err := s.Offer(ctx, caller, resident, nil, "image/jpeg", 1); err == nil {
		t.Fatal("offering succeeded with a broken signer")
	}
	if after := countRows(t); after != before {
		t.Fatalf("a row survived a failed signing: %d then %d", before, after)
	}
}

func countRows(t *testing.T) int {
	t.Helper()
	ctx := context.Background()
	admin, _ := pgx.Connect(ctx, os.Getenv("DAILYCARE_TEST_ADMIN_DSN"))
	defer admin.Close(ctx)
	var n int
	admin.QueryRow(ctx, `SELECT count(*) FROM media_objects`).Scan(&n)
	return n
}

// The same rule internal/records holds itself to, in the package that shares its
// exemption. Every method here that queries has to audit first, unless it is named below
// with a reason - which is a small enough act to do by accident and a loud enough one to
// notice in review.
func TestEveryQueryInThisPackageAuditsFirst(t *testing.T) {
	declared := map[string]string{
		"Arrived": "Not a read of a resident. It says the object the caller just uploaded " +
			"is in the bucket, and the row it touches is one this session created - the " +
			"UPDATE is keyed on uploaded_by being the caller, so it cannot reach anybody " +
			"else's. Auditing it would record a read that did not happen, on a resident " +
			"whose record was not opened.",
	}

	body, err := os.ReadFile("media.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(body)
	method := regexp.MustCompile(`func \(s \*Store\) ([A-Z]\w*)\(`)
	for _, m := range method.FindAllStringSubmatchIndex(src, -1) {
		name := src[m[2]:m[3]]
		end := len(src)
		if next := method.FindStringIndex(src[m[1]:]); next != nil {
			end = m[1] + next[0]
		}
		block := src[m[0]:end]
		if !strings.Contains(block, "tx.Query") && !strings.Contains(block, "tx.Exec") {
			continue
		}
		if strings.Contains(block, "audit_read") {
			continue
		}
		why, ok := declared[name]
		if !ok {
			t.Errorf("%s queries without calling audit_read first, and is not declared. "+
				"Either audit it, or say here why the query is not a read of a resident.", name)
			continue
		}
		if len(why) < 40 {
			t.Errorf("%s is declared with a reason too short to be one", name)
		}
	}
}

// A day to hang a photograph on, written as the application so the policies apply.
func aDay(t *testing.T, s *Store, c db.Caller, facility, resident uuid.UUID,
	on time.Time) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	err := s.db.InSession(context.Background(), c, func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `
			INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite,
			                       sleep, filed_by)
			VALUES ($1,$2,$3,'calm','good','slept_well',$4) RETURNING id`,
			facility, resident, on, c.UserID).Scan(&id)
	})
	if err != nil {
		t.Fatalf("writing a care day: %v", err)
	}
	return id
}

// A correction, the way records.File makes one: retire the old row, insert a new one
// pointing back at it. The photograph is not touched, which is the point.
func correct(t *testing.T, s *Store, c db.Caller, facility, resident, previous uuid.UUID,
	on time.Time) {
	t.Helper()
	err := s.db.InSession(context.Background(), c, func(tx pgx.Tx) error {
		if _, err := tx.Exec(context.Background(),
			`UPDATE care_days SET superseded_at = now() WHERE id = $1`, previous); err != nil {
			return err
		}
		_, err := tx.Exec(context.Background(), `
			INSERT INTO care_days (facility_id, resident_id, care_date, mood, appetite,
			                       sleep, filed_by, amends_id)
			VALUES ($1,$2,$3,'anxious','poor','restless',$4,$5)`,
			facility, resident, on, c.UserID, previous)
		return err
	})
	if err != nil {
		t.Fatalf("correcting the day: %v", err)
	}
}

// A photograph filed against a day that was later corrected is still that day's
// photograph.
//
// This is the trap schema-invariants.sql names: a correction makes a new care_days row,
// the photograph stays attached to the one it was filed against, and the obvious query -
// where care_day_id is the current row - returns nothing the moment somebody fixes a typo.
// Resolving by the resident and the date is what reaches every revision.
func TestPhotographsSurviveACorrection(t *testing.T) {
	s, _, caller, resident, facility := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)
	day := aDay(t, s, caller, facility, resident, on)

	up, err := s.Offer(ctx, caller, resident, &day, "image/jpeg", 1024)
	if err != nil {
		t.Fatalf("offering: %v", err)
	}
	if err := s.Arrived(ctx, caller, up.ObjectID); err != nil {
		t.Fatalf("confirming: %v", err)
	}

	before, err := s.ForDay(ctx, caller, resident, on)
	if err != nil {
		t.Fatalf("reading: %v", err)
	}
	if len(before) != 1 {
		t.Fatalf("wanted one photograph before the correction, got %d", len(before))
	}
	if before[0].URL == "" || before[0].ExpiresAt.IsZero() {
		t.Errorf("a photograph came back without a link: %+v", before[0])
	}

	correct(t, s, caller, facility, resident, day, on)

	after, err := s.ForDay(ctx, caller, resident, on)
	if err != nil {
		t.Fatalf("reading after the correction: %v", err)
	}
	if len(after) != 1 {
		t.Fatalf("the photograph was lost by a correction: got %d", len(after))
	}
	if after[0].ID != before[0].ID {
		t.Errorf("a different photograph came back: %v then %v", before[0].ID, after[0].ID)
	}
}

// An offer that was never confirmed describes an object that is not in the bucket. A link
// to it is a broken image in front of a family.
func TestAPhotographThatNeverArrivedIsNotOffered(t *testing.T) {
	s, _, caller, resident, facility := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)
	day := aDay(t, s, caller, facility, resident, on)

	if _, err := s.Offer(ctx, caller, resident, &day, "image/jpeg", 1024); err != nil {
		t.Fatalf("offering: %v", err)
	}
	// Deliberately no Arrived.

	got, err := s.ForDay(ctx, caller, resident, on)
	if err != nil {
		t.Fatalf("reading: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("an upload that never finished was offered as a photograph: %+v", got)
	}
}

// A real caregiver, in a real building, asking for a real resident's photographs in a
// building that is not theirs.
//
// An invented uuid proves less than this does: it fails because nothing is there, which
// is the same answer a broken policy would give. Two wards, both populated, and the
// question is whether the wall between them holds.
func TestAnotherBuildingsCaregiverGetsNoPhotographs(t *testing.T) {
	cedar, _, atCedar, cathy, cedarID := ward(t)
	birch, _, atBirch, _, _ := ward(t)
	ctx := context.Background()
	on := time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC)

	day := aDay(t, cedar, atCedar, cedarID, cathy, on)
	up, err := cedar.Offer(ctx, atCedar, cathy, &day, "image/jpeg", 2048)
	if err != nil {
		t.Fatalf("offering: %v", err)
	}
	if err := cedar.Arrived(ctx, atCedar, up.ObjectID); err != nil {
		t.Fatalf("confirming: %v", err)
	}

	// Cedar's own caregiver can see it, so the fixture is real and the next assertion
	// means something.
	mine, err := cedar.ForDay(ctx, atCedar, cathy, on)
	if err != nil || len(mine) != 1 {
		t.Fatalf("cedar's caregiver should see one photograph, got %d (%v)", len(mine), err)
	}

	got, err := birch.ForDay(ctx, atBirch, cathy, on)
	if len(got) != 0 {
		t.Fatalf("another building's caregiver got %d photographs of Cathy", len(got))
	}
	// Refused rather than empty: audit_read will not record a read of a resident this
	// session cannot see, and that refusal is the access check.
	if !errors.Is(err, ErrNotVisible) {
		t.Fatalf("got %v, want ErrNotVisible", err)
	}
}

// The same question with nothing behind it, which is the cheaper half of the pair.
func TestAResidentYouCannotSeeHasNoPhotographs(t *testing.T) {
	s, _, caller, _, _ := ward(t)
	got, err := s.ForDay(context.Background(), caller, uuid.New(),
		time.Date(2026, 9, 23, 0, 0, 0, 0, time.UTC))
	if len(got) != 0 {
		t.Fatalf("got %d photographs for a resident that is not there", len(got))
	}
	if !errors.Is(err, ErrNotVisible) {
		t.Fatalf("got %v, want ErrNotVisible", err)
	}
}
