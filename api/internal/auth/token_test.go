package auth

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func signer(t *testing.T) *Signer {
	t.Helper()
	s, err := NewSigner([]byte("0123456789abcdef0123456789abcdef"))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestAShortKeyIsRefused(t *testing.T) {
	if _, err := NewSigner([]byte("too short")); err == nil {
		t.Fatal("a nine-byte signing key was accepted")
	}
}

func TestRoundTripAndExpiry(t *testing.T) {
	s := signer(t)
	id := uuid.New()
	now := time.Now()
	tok := s.Issue(id, now)

	got, err := s.Verify(tok, now)
	if err != nil {
		t.Fatalf("a fresh token did not verify: %v", err)
	}
	if got != id {
		t.Fatalf("verified as %s, want %s", got, id)
	}
	if _, err := s.Verify(tok, now.Add(AccessTTL+time.Second)); err != ErrTokenExpired {
		t.Fatalf("an expired token gave %v, want ErrTokenExpired", err)
	}
}

// The point of the design. Each of these is a real attack on a token format.
//
// What is asserted is that every one is refused. Where the shape is right and only the
// contents were changed, the refusal has to be the signature - anything else would mean
// the verifier read the claims before checking them. A string with no separator in it is
// refused as malformed instead, which is the accurate answer and not a weaker one: both
// are a 401, and neither tells the caller anything they did not already know about what
// they sent.
func TestForgeryIsRefused(t *testing.T) {
	s := signer(t)
	mine, theirs := uuid.New(), uuid.New()
	now := time.Now()
	tok := s.Issue(mine, now)
	parts := strings.Split(tok, ".")

	cases := []struct {
		name  string
		token string
		want  error
	}{
		{"somebody else's id, same signature",
			strings.Join([]string{parts[0], theirs.String(), parts[2], parts[3]}, "."), ErrTokenSignature},
		{"a later expiry, same signature",
			strings.Join([]string{parts[0], parts[1], "9999999999", parts[3]}, "."), ErrTokenSignature},
		{"no signature at all",
			strings.Join(parts[:3], "."), ErrTokenSignature},
		{"an empty signature",
			strings.Join(parts[:3], ".") + ".", ErrTokenSignature},
		{"somebody else's key", "", ErrTokenSignature},
		{"not a token", "hello", ErrTokenMalformed},
		{"nothing", "", ErrTokenMalformed},
	}
	other, _ := NewSigner([]byte("ffffffffffffffffffffffffffffffff"))
	cases[4].token = other.Issue(mine, now)

	for _, c := range cases {
		got, err := s.Verify(c.token, now)
		if err == nil {
			t.Errorf("%s: accepted, and returned %s", c.name, got)
			continue
		}
		if err != c.want {
			t.Errorf("%s: refused with %v, want %v", c.name, err, c.want)
		}
	}
}

// A token carrying a role or a facility would be a copy of the access model made at
// sign-in, and stale the moment somebody's shift changed. It carries a user and an expiry.
func TestTheTokenSaysNothingButWhoAndUntilWhen(t *testing.T) {
	s := signer(t)
	id := uuid.New()
	tok := s.Issue(id, time.Now())
	parts := strings.Split(tok, ".")
	if len(parts) != 4 {
		t.Fatalf("the token has %d parts, want version, user, expiry, signature", len(parts))
	}
	if parts[1] != id.String() {
		t.Fatal("the second part is not the user")
	}
}
