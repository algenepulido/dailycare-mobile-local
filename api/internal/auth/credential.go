// Package auth turns a password into something the database will accept, and a token into
// the digest that is all the database ever sees of it.
//
// The shapes are not this package's choice. schema.sql refuses a users.password_hash that
// is not PHC-encoded argon2id and a refresh_hash that is not lowercase sha256 hex, so
// getting either wrong is a failed insert rather than a weak row written quietly. This
// package exists so the right thing is also the easy thing.
package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// OWASP's argon2id floor at the time of writing: 19 MiB, two passes, one lane. Stored in
// the encoding rather than assumed, so raising them later still verifies old rows.
const (
	argonMemory  = 19 * 1024
	argonTime    = 2
	argonThreads = 1
	argonKeyLen  = 32
	argonSaltLen = 16
)

var ErrWrongPassword = errors.New("auth: the password does not match")

// Hash returns a PHC string schema.sql will accept. Unpadded base64, which is what the
// argon2 reference encoding uses and what the constraint's character class allows - the
// '=' of padded base64 is not in it, so a padded digest is refused at the insert.
func Hash(password string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", fmt.Errorf("auth: %w", err)
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	b64 := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=19$m=%d,t=%d,p=%d$%s$%s",
		argonMemory, argonTime, argonThreads, b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

// Verify reads the parameters out of the stored string rather than using the constants
// above, so a row written before they were raised still verifies.
func Verify(password, encoded string) error {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" || parts[2] != "v=19" {
		return errors.New("auth: not an argon2id digest")
	}
	var m uint32
	var t uint32
	var p uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil {
		return fmt.Errorf("auth: unreadable parameters: %w", err)
	}
	b64 := base64.RawStdEncoding
	salt, err := b64.DecodeString(parts[4])
	if err != nil {
		return fmt.Errorf("auth: unreadable salt: %w", err)
	}
	want, err := b64.DecodeString(parts[5])
	if err != nil {
		return fmt.Errorf("auth: unreadable digest: %w", err)
	}
	got := argon2.IDKey([]byte(password), salt, t, m, p, uint32(len(want)))
	// Constant time. The difference between a wrong password and a nearly-right one should
	// not be measurable from outside.
	if subtle.ConstantTimeCompare(got, want) != 1 {
		return ErrWrongPassword
	}
	return nil
}

// NewToken returns a token and the digest of it. The token goes to the client and into one
// HTTP response; the digest is what gets stored. Nothing here ever writes the token down,
// which is why the pair comes back together and the caller has to decide where each half
// goes.
func NewToken() (token string, digest string, err error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", "", fmt.Errorf("auth: %w", err)
	}
	token = base64.RawURLEncoding.EncodeToString(raw)
	return token, Digest(token), nil
}

// Digest is the only representation of a token the database is allowed to hold. Lowercase
// hex, because is_sha256_hex says so.
func Digest(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
