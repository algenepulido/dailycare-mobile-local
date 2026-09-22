package auth

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func conn(t *testing.T) *pgx.Conn {
	t.Helper()
	dsn := os.Getenv("DAILYCARE_TEST_DSN")
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

func TestRoundTrip(t *testing.T) {
	h, err := Hash("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify("correct horse battery staple", h); err != nil {
		t.Fatalf("the right password did not verify: %v", err)
	}
	if err := Verify("correct horse battery stapl", h); err != ErrWrongPassword {
		t.Fatalf("a wrong password gave %v, want ErrWrongPassword", err)
	}
}

func TestTwoHashesOfTheSamePasswordDiffer(t *testing.T) {
	a, _ := Hash("same")
	b, _ := Hash("same")
	if a == b {
		t.Fatal("identical digests, so the salt is not random")
	}
}

// The check that matters: the database is the authority on the shape, so ask it rather
// than reading the regex and agreeing with myself.
func TestTheDatabaseAcceptsWhatWeProduce(t *testing.T) {
	c := conn(t)
	h, err := Hash("whatever")
	if err != nil {
		t.Fatal(err)
	}
	var ok bool
	if err := c.QueryRow(context.Background(), `SELECT is_argon2id($1)`, h).Scan(&ok); err != nil {
		t.Fatalf("asking the database: %v", err)
	}
	if !ok {
		t.Fatalf("is_argon2id refused %q", h)
	}
}

// Padded base64 is the specific way to get this wrong, because it looks right.
func TestPaddedBase64WouldHaveBeenRefused(t *testing.T) {
	c := conn(t)
	h, _ := Hash("whatever")
	padded := strings.ReplaceAll(h, "$argon2id", "$argon2id") // shape kept
	parts := strings.Split(padded, "$")
	parts[5] = parts[5] + "==" // what encoding/base64.StdEncoding would have given us
	var ok bool
	if err := c.QueryRow(context.Background(), `SELECT is_argon2id($1)`,
		strings.Join(parts, "$")).Scan(&ok); err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("the constraint accepted padded base64, so this test is not the guard it claims to be")
	}
}

func TestTheDatabaseAcceptsOurTokenDigests(t *testing.T) {
	c := conn(t)
	_, digest, err := NewToken()
	if err != nil {
		t.Fatal(err)
	}
	var ok bool
	if err := c.QueryRow(context.Background(), `SELECT is_sha256_hex($1)`, digest).Scan(&ok); err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatalf("is_sha256_hex refused %q", digest)
	}
}

func TestTheTokenItselfIsNeverTheDigest(t *testing.T) {
	token, digest, _ := NewToken()
	if token == digest {
		t.Fatal("the token and its digest are the same string")
	}
	if Digest(token) != digest {
		t.Fatal("Digest does not reproduce what NewToken returned")
	}
}
