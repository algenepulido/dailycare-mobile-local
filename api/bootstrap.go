package main

// Creating the first caregiver account, by hand, on purpose.
//
// There is no sign-up and no admin screen, and for milestone two there is deliberately not
// going to be one. A caregiver's account is made by somebody who already has the authority
// to grant access to a building's residents, and that is an administrative act rather than
// a feature.
//
// It lives in the API's own binary so the passphrase is hashed by exactly the code that
// verifies it. A second implementation of Argon2id, in a script, with its own parameters,
// is how an account gets created that cannot sign in - and the failure appears at the
// caregiver's first shift rather than here.
//
//	dailycare-api bootstrap --facility <uuid> --email <e> --name <n> [--by <email>]
//	                        [--resident <uuid>]...
//
// Run as a Cloud Run job inside the VPC, because the instance has no public address.

import (
	"context"
	"crypto/rand"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/dailycare-hq/dailycare-api/internal/auth"
)

type residentList []string

func (r *residentList) String() string { return strings.Join(*r, ",") }
func (r *residentList) Set(v string) error {
	if _, err := uuid.Parse(v); err != nil {
		return fmt.Errorf("%q is not a resident id", v)
	}
	*r = append(*r, v)
	return nil
}

func bootstrap(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("bootstrap", flag.ContinueOnError)
	facility := fs.String("facility", "", "the facility this caregiver works in (uuid)")
	email := fs.String("email", "", "the address they will sign in with")
	name := fs.String("name", "", "the name a family sees on a day they filed")
	role := fs.String("role", "caregiver", "caregiver or care_manager")
	by := fs.String("by", "", "the address of the person doing this, recorded against the grant")
	var residents residentList
	fs.Var(&residents, "resident", "a resident to assign them to; repeat for more")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *facility == "" || *email == "" || *name == "" {
		fs.Usage()
		return errors.New("facility, email and name are all required")
	}
	if _, err := uuid.Parse(*facility); err != nil {
		return fmt.Errorf("--facility %q is not a uuid", *facility)
	}

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return errors.New("DATABASE_URL is not set")
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return err
	}
	defer conn.Close(ctx)

	passphrase, err := newPassphrase()
	if err != nil {
		return err
	}
	hash, err := auth.Hash(passphrase)
	if err != nil {
		return err
	}

	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// Refused rather than updated. An email that is already there belongs to somebody, and
	// the difference between creating an account and resetting a stranger's password is
	// one this should not decide for whoever typed the command.
	var exists bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM users WHERE lower(email) = lower($1))`, *email).
		Scan(&exists); err != nil {
		return err
	}
	if exists {
		return fmt.Errorf("%s already has an account. Resetting a password is a different "+
			"operation and this is not it", *email)
	}

	var actor *uuid.UUID
	if *by != "" {
		var id uuid.UUID
		if err := tx.QueryRow(ctx,
			`SELECT id FROM users WHERE lower(email) = lower($1)`, *by).Scan(&id); err != nil {
			return fmt.Errorf("--by %s: no account with that address", *by)
		}
		actor = &id
	}

	var userID uuid.UUID
	if err := tx.QueryRow(ctx,
		`INSERT INTO users (email, display_name, password_hash) VALUES ($1,$2,$3)
		 RETURNING id`, *email, *name, hash).Scan(&userID); err != nil {
		return err
	}

	var memberID uuid.UUID
	if err := tx.QueryRow(ctx,
		`INSERT INTO facility_members (facility_id, user_id, role, state, invited_by)
		 VALUES ($1,$2,$3,'active',$4) RETURNING id`,
		*facility, userID, *role, actor).Scan(&memberID); err != nil {
		return err
	}

	for _, r := range residents {
		if _, err := tx.Exec(ctx,
			`INSERT INTO assignments (facility_id, resident_id, facility_member_id, assigned_by)
			 VALUES ($1,$2,$3,$4)`, *facility, r, memberID, actor); err != nil {
			return fmt.Errorf("assigning %s: %w", r, err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return err
	}

	// Everything the operator needs to read is on stderr; the passphrase alone is on
	// stdout, so it can be piped somewhere without the commentary and so a log that
	// captures one stream does not necessarily capture both.
	fmt.Fprintf(os.Stderr, "\n%s is %s, %s in %s\n", *name, userID, *role, *facility)
	if len(residents) == 0 {
		fmt.Fprintf(os.Stderr,
			"They can see no residents yet. Run this again with --resident to assign them,\n"+
				"or they will sign in to an empty list and reasonably assume it is broken.\n")
	} else {
		fmt.Fprintf(os.Stderr, "Assigned to %d resident(s).\n", len(residents))
	}
	if actor == nil {
		fmt.Fprintf(os.Stderr,
			"No --by given, so nothing records who granted this. That is expected for the\n"+
				"first account in a building and is listed by assignments_without_an_author.\n")
	}
	fmt.Fprintf(os.Stderr, "\nThe passphrase is printed once and is not stored anywhere:\n\n")
	fmt.Println(passphrase)
	return nil
}

// Words rather than characters.
//
// A caregiver reads this off a screen and types it into a phone, once, standing up. Six
// words from this list is about 62 bits, which is more than a person invents and far
// easier to get across a room without a typo than the same strength in punctuation.
func newPassphrase() (string, error) {
	words := []string{
		"amber", "anchor", "apple", "arbour", "autumn", "barley", "basin", "beacon",
		"birch", "bramble", "bridge", "bucket", "candle", "canvas", "cedar", "chalk",
		"cinder", "clover", "copper", "cotton", "crescent", "cricket", "damson", "dawn",
		"dovetail", "driftwood", "ember", "fathom", "fennel", "ferry", "flint", "furrow",
		"garland", "granite", "harbour", "hazel", "heather", "hollow", "ivory", "juniper",
		"kettle", "lantern", "lattice", "linden", "lupin", "marble", "meadow", "mint",
		"mosaic", "nettle", "orchard", "otter", "parsley", "pebble", "pewter", "pillar",
		"quarry", "quilt", "rafter", "reed", "ribbon", "rosemary", "saffron", "sandal",
		"satchel", "seabird", "shale", "sorrel", "spindle", "sprig", "starling", "sumac",
		"tallow", "tamarind", "thicket", "thimble", "thistle", "timber", "trellis", "tulip",
		"vellum", "verbena", "vessel", "walnut", "wicker", "willow", "windmill", "yarrow",
	}
	out := make([]string, 6)
	for i := range out {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(words))))
		if err != nil {
			return "", err
		}
		out[i] = words[n.Int64()]
	}
	return strings.Join(out, " "), nil
}
