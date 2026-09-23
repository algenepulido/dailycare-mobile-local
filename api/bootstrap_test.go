package main

import (
	"strings"
	"testing"

	"github.com/dailycare-hq/dailycare-api/internal/auth"
)

// The passphrase this hands a caregiver has to be one they can sign in with.
//
// That sounds tautological and is not: the whole reason bootstrap lives in the API's own
// binary is that a second Argon2id implementation, in a script, with its own parameters,
// produces a hash the API will refuse. The failure appears at the caregiver's first shift
// rather than at the command that created them, so it is pinned here.
func TestAGeneratedPassphraseCanSignIn(t *testing.T) {
	for i := 0; i < 20; i++ {
		p, err := newPassphrase()
		if err != nil {
			t.Fatal(err)
		}
		hash, err := auth.Hash(p)
		if err != nil {
			t.Fatal(err)
		}
		if err := auth.Verify(p, hash); err != nil {
			t.Fatalf("%q does not verify against its own hash: %v", p, err)
		}
		if err := auth.Verify(p+"x", hash); err == nil {
			t.Fatalf("a passphrase with a character added still verified")
		}
	}
}

// Six words, and two calls that agree would mean it is not reading the random source.
func TestPassphrasesAreNotRepeated(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		p, err := newPassphrase()
		if err != nil {
			t.Fatal(err)
		}
		if got := len(strings.Fields(p)); got != 6 {
			t.Fatalf("wanted six words, got %d: %q", got, p)
		}
		if seen[p] {
			t.Fatalf("the same passphrase came back twice: %q", p)
		}
		seen[p] = true
	}
}

// A caregiver reads this off a screen and types it into a phone, standing up, once. The
// word list is what makes that bearable, so it has to stay long enough to be worth it -
// six words from 88 is a little over 38 bits, and shrinking the list silently weakens
// every account made afterwards.
func TestTheWordListIsLargeEnoughToBeWorthIt(t *testing.T) {
	p, err := newPassphrase()
	if err != nil {
		t.Fatal(err)
	}
	words := map[string]bool{}
	for i := 0; i < 4000; i++ {
		p, err = newPassphrase()
		if err != nil {
			t.Fatal(err)
		}
		for _, w := range strings.Fields(p) {
			words[w] = true
		}
	}
	if len(words) < 80 {
		t.Fatalf("the list is down to %d words, which is weaker than it was", len(words))
	}
}
