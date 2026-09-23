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
	"errors"
	"flag"
	"fmt"
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

	// Environment as well as flags, because this runs as a Cloud Run job and a job's
	// arguments are fixed when it is created - `gcloud run jobs execute` can override the
	// environment and not the command line. Flags win, so the same binary is usable by
	// hand without the environment getting a say it was not asked for.
	fallback(facility, "BOOTSTRAP_FACILITY")
	fallback(email, "BOOTSTRAP_EMAIL")
	fallback(name, "BOOTSTRAP_NAME")
	fallback(by, "BOOTSTRAP_BY")
	if *role == "caregiver" {
		fallback(role, "BOOTSTRAP_ROLE")
	}
	if len(residents) == 0 {
		for _, r := range strings.Split(os.Getenv("BOOTSTRAP_RESIDENTS"), ",") {
			if r = strings.TrimSpace(r); r != "" {
				if err := residents.Set(r); err != nil {
					return fmt.Errorf("BOOTSTRAP_RESIDENTS: %w", err)
				}
			}
		}
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

	// A link, not a password.
	//
	// This used to generate a passphrase and hand it over, which meant whoever ran the
	// command knew the caregiver's password. That weakens the one thing the audit trail
	// is for: "who filed this record" has a different answer if somebody else could have
	// signed in as them. The caregiver chooses their own and nobody else ever sees it.
	link, digest, err := auth.NewToken()
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

	// No password_hash. An account with none cannot be signed in to - credential_for_sign_in
	// returns nothing for it - so the invitation is the only way in until it is accepted.
	var userID uuid.UUID
	if err := tx.QueryRow(ctx,
		`INSERT INTO users (email, display_name) VALUES ($1,$2) RETURNING id`,
		*email, *name).Scan(&userID); err != nil {
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

	if _, err := tx.Exec(ctx,
		`INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at)
		 VALUES ($1, 'invitation', $2, now() + interval '7 days')`,
		userID, digest); err != nil {
		return err
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
	fmt.Fprintf(os.Stderr,
		"\nThe invitation is printed once. Only its digest is stored, so this cannot be\n"+
			"asked for again - run this command for another if it goes astray. It lasts\n"+
			"seven days, admits one person, and is how they choose their own password:\n\n")
	fmt.Println(link)
	return nil
}

func fallback(flagValue *string, env string) {
	if *flagValue == "" {
		*flagValue = os.Getenv(env)
	}
}
