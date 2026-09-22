package records

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// The model's metadata, not its data. dailycare_app is refused the classification table on
// purpose - a list of where the sensitive columns are is not application data - so a
// source-level guard asks with a connection that is not pretending to be the application.
func conn(t *testing.T) *pgx.Conn {
	t.Helper()
	dsn := os.Getenv("DAILYCARE_TEST_ADMIN_DSN")
	if dsn == "" {
		t.Skip("DAILYCARE_TEST_DSN is not set; run ./test.sh")
	}
	c, err := pgx.Connect(context.Background(), dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(func() { c.Close(context.Background()) })
	return c
}

// The one that makes this package mean something.
//
// "Resident data is only read through here" is a sentence until something checks it. The
// list of tables comes from data_classification rather than from a slice in this file, so
// a PHI table added to the model next month is covered without anybody remembering to add
// it - the same reason the completeness views in docs/architecture are queries rather than
// checklists.
func TestNothingOutsideThisPackageReadsPHI(t *testing.T) {
	c := conn(t)
	rows, err := c.Query(context.Background(),
		`SELECT DISTINCT table_name FROM data_classification WHERE class = 'phi' ORDER BY 1`)
	if err != nil {
		t.Fatalf("asking which tables hold PHI: %v", err)
	}
	defer rows.Close()

	var phi []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		phi = append(phi, name)
	}
	if len(phi) == 0 {
		t.Fatal("the classification named no PHI tables, so this test is checking nothing")
	}
	t.Logf("checking %d PHI tables against the rest of the API", len(phi))

	// FROM/JOIN/INTO/UPDATE <table>. Not every mention of the word - a comment that says
	// "care_days" is not a read, and a test that fails on prose teaches people to stop
	// writing prose.
	patterns := make(map[string]*regexp.Regexp, len(phi))
	for _, table := range phi {
		patterns[table] = regexp.MustCompile(
			`(?i)\b(from|join|into|update)\s+` + regexp.QuoteMeta(table) + `\b`)
	}

	// The module root, so the walk covers handlers and anything added beside them rather
	// than only this package's neighbours.
	root := "../.."
	err = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(path, ".go") {
			return err
		}
		// This package is the exception, which is the whole point of it.
		if strings.Contains(filepath.ToSlash(path), "internal/records/") {
			return nil
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for table, re := range patterns {
			if loc := re.FindIndex(body); loc != nil {
				line := 1 + strings.Count(string(body[:loc[0]]), "\n")
				t.Errorf("%s:%d reads %s directly. Resident data goes through internal/records, "+
					"which records the read in the same transaction; a query here is a read that "+
					"never reaches the audit trail.", path, line, table)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking the source: %v", err)
	}
}

// Proof the test above can fail, rather than passing because the regex never matches
// anything. Without this it would also pass on an empty repository.
func TestTheGuardWouldCatchADirectRead(t *testing.T) {
	re := regexp.MustCompile(`(?i)\b(from|join|into|update)\s+` + regexp.QuoteMeta("care_days") + `\b`)
	offending := []string{
		`tx.Query(ctx, "SELECT * FROM care_days WHERE id = $1")`,
		`tx.Exec(ctx, "UPDATE care_days SET notes = $1")`,
		"tx.Query(ctx, `SELECT c.* FROM residents r JOIN care_days c ON c.resident_id = r.id`)",
	}
	for _, s := range offending {
		if !re.MatchString(s) {
			t.Errorf("the guard missed: %s", s)
		}
	}
	innocent := []string{
		`// care_days is filed at the end of a shift`,
		`subject := "care_days"`,
	}
	for _, s := range innocent {
		if re.MatchString(s) {
			t.Errorf("the guard fired on prose: %s", s)
		}
	}
}

// Inside this package the boundary cannot be a path check, so it is a list. Every query
// here either goes through read(), which audits first, or is named below with a reason.
// Adding an unaudited read means adding a line to this list, which is a small enough act
// to do by accident and a loud enough one to notice in review.
func TestEveryUnauditedQueryInThisPackageIsDeclared(t *testing.T) {
	declared := map[string]string{
		"Residents": "The list is exactly who the session is assigned to - the policies " +
			"decide it, and the caregiver could not see another facility's residents here " +
			"if they tried. Recording a row per resident on every app launch would add the " +
			"one event that carries no information, in the volume that makes the rest hard " +
			"to read. Revisit if the list ever stops being the assignment.",
	}

	body, err := os.ReadFile("records.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(body)

	// Every method that runs a query without reaching read() has to be in the map.
	method := regexp.MustCompile(`func \(s \*Store\) ([A-Z]\w*)\(`)
	for _, m := range method.FindAllStringSubmatchIndex(src, -1) {
		name := src[m[2]:m[3]]
		end := len(src)
		if next := method.FindStringIndex(src[m[1]:]); next != nil {
			end = m[1] + next[0]
		}
		body := src[m[0]:end]
		queries := strings.Contains(body, "tx.Query") || strings.Contains(body, "tx.Exec")
		audits := strings.Contains(body, "s.read(")
		if queries && !audits {
			if why, ok := declared[name]; !ok {
				t.Errorf("%s queries without going through read() and is not declared. "+
					"Either route it through read(), or add it to the list in this test with "+
					"why the read does not belong in the trail.", name)
			} else if len(why) < 40 {
				t.Errorf("%s is declared with a reason too short to be one", name)
			}
		}
	}
}
