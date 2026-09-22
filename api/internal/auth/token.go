package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

// The access token. Short-lived, never stored anywhere, and the only thing the API reads
// to decide whose uuid goes into app.user_id.
//
// Not a JWT, and the reason is the header. A JWT carries the algorithm inside the token,
// which means the verifier is told how to verify by the thing it is verifying - that is
// the alg=none and the RS256-to-HS256 confusion, and libraries have kept shipping both for
// a decade. There is one algorithm here, it is not negotiable, and it is not in the token.
//
// The payload is a user id and an expiry and nothing else. A token that carried a role or
// a facility would be a second copy of the access model, made at sign-in and stale by the
// time somebody's shift changed - the database decides who may see what, every request.

const (
	tokenVersion = "dc1"
	AccessTTL    = 15 * time.Minute
)

var (
	ErrTokenMalformed = errors.New("auth: the access token is not one of ours")
	ErrTokenSignature = errors.New("auth: the access token's signature does not verify")
	ErrTokenExpired   = errors.New("auth: the access token has expired")
)

type Signer struct{ key []byte }

// NewSigner refuses a short key rather than accepting one and being weaker than it looks.
// Thirty-two bytes is the output of the hash; less than that and the signature is the
// weakest part of the system rather than the strongest.
func NewSigner(key []byte) (*Signer, error) {
	if len(key) < 32 {
		return nil, fmt.Errorf("auth: the signing key is %d bytes, want at least 32", len(key))
	}
	return &Signer{key: key}, nil
}

// Issue returns a token for a user, valid for AccessTTL.
func (s *Signer) Issue(user uuid.UUID, now time.Time) string {
	payload := fmt.Sprintf("%s.%s.%d", tokenVersion, user, now.Add(AccessTTL).Unix())
	return payload + "." + s.sign(payload)
}

// Verify returns the user the token is for, or an error. The expiry is checked after the
// signature, so an expired token that has been tampered with reports the tampering.
func (s *Signer) Verify(token string, now time.Time) (uuid.UUID, error) {
	i := strings.LastIndex(token, ".")
	if i < 0 {
		return uuid.Nil, ErrTokenMalformed
	}
	payload, sig := token[:i], token[i+1:]

	// Constant time, and on the signature before anything is parsed out of the payload:
	// a verifier that reads the claims first is a verifier that can be made to do work on
	// behalf of somebody with no key.
	if !hmac.Equal([]byte(sig), []byte(s.sign(payload))) {
		return uuid.Nil, ErrTokenSignature
	}

	parts := strings.Split(payload, ".")
	if len(parts) != 3 || parts[0] != tokenVersion {
		return uuid.Nil, ErrTokenMalformed
	}
	user, err := uuid.Parse(parts[1])
	if err != nil {
		return uuid.Nil, ErrTokenMalformed
	}
	exp, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return uuid.Nil, ErrTokenMalformed
	}
	if now.After(time.Unix(exp, 0)) {
		return uuid.Nil, ErrTokenExpired
	}
	return user, nil
}

func (s *Signer) sign(payload string) string {
	m := hmac.New(sha256.New, s.key)
	m.Write([]byte(payload))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}
