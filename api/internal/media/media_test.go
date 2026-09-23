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
// exemption. Every method here that queries has to audit first, and adding one that does
// not means editing this list on purpose.
func TestEveryQueryInThisPackageAuditsFirst(t *testing.T) {
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
		if !strings.Contains(block, "audit_read") {
			t.Errorf("%s queries without calling audit_read first", name)
		}
	}
}
