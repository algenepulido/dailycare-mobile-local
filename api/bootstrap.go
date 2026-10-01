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
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/dailycare-hq/dailycare-api/internal/auth"
	"github.com/dailycare-hq/dailycare-api/internal/db"
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
	role := fs.String("role", "caregiver", "caregiver, care_manager or family")
	relation := fs.String("relation", "",
		"for -role family: spouse, child, sibling, other_family, friend, power_of_attorney or self")
	by := fs.String("by", "", "the address of the person doing this, recorded against the grant")
	reset := fs.Bool("reset", false,
		"issue a password reset for an account that already exists, instead of creating one")
	revoke := fs.Bool("revoke", false,
		"withdraw a family member's access to one resident, instead of creating anything")
	var residents residentList
	fs.Var(&residents, "resident", "a resident to assign them to; repeat for more")
	if err := fs.Parse(args); err != nil {
		return err
	}

	// Environment as well as flags, because this runs as a Cloud Run job and a job's
	// arguments are fixed when it is created - `gcloud run jobs execute` can override the
	// environment and not the command line. Flags win, so the same binary is usable by
	// hand without the environment getting a say it was not asked for.
	if !*reset && strings.EqualFold(os.Getenv("BOOTSTRAP_RESET"), "true") {
		*reset = true
	}
	if !*revoke && strings.EqualFold(os.Getenv("BOOTSTRAP_REVOKE"), "true") {
		*revoke = true
	}
	fallback(facility, "BOOTSTRAP_FACILITY")
	fallback(email, "BOOTSTRAP_EMAIL")
	fallback(name, "BOOTSTRAP_NAME")
	fallback(by, "BOOTSTRAP_BY")
	// Not fallback(). That reads the environment only when the flag is empty, and this
	// flag has a default, so it never is - which meant BOOTSTRAP_ROLE was read by nobody
	// and every account this job created came out a caregiver whatever it was told. A job's
	// arguments are fixed when it is created and execute can only override the environment,
	// so the -role flag could not reach it either: there was no way to make a care manager
	// in a deployed environment at all. Found by running it and reading what it made.
	if *role == "caregiver" {
		if v := os.Getenv("BOOTSTRAP_ROLE"); v != "" {
			*role = v
		}
	}
	fallback(relation, "BOOTSTRAP_RELATION")

	if len(residents) == 0 {
		for _, r := range strings.Split(os.Getenv("BOOTSTRAP_RESIDENTS"), ",") {
			if r = strings.TrimSpace(r); r != "" {
				if err := residents.Set(r); err != nil {
					return fmt.Errorf("BOOTSTRAP_RESIDENTS: %w", err)
				}
			}
		}
	}

	// After the environment, not before it. This ran above the BOOTSTRAP_RESIDENTS block
	// and refused a correct request: a family grant was rejected for naming no resident
	// while the resident was sitting in an environment variable nothing had read yet. A
	// check on a value has to come after everything that can set that value.
	// The database would refuse an unknown value anyway - both of these are enums - but it
	// would refuse it after the user row was written, leaving an account attached to
	// nothing. Checked here, before anything is created.
	switch *role {
	case "caregiver", "care_manager":
	case "family":
		switch *relation {
		case "self", "spouse", "child", "sibling", "other_family", "friend", "power_of_attorney":
		case "":
			return fmt.Errorf("-role family needs -relation: how this person is related to the resident")
		default:
			return fmt.Errorf("relation %q is not one resident_relation has", *relation)
		}
		if len(residents) != 1 {
			// A grant names one resident. Two parents of one resident, or one person
			// linked to two, are both ordinary - and both are more than one row, written
			// one at a time, because authorisation is per resident and never per family.
			return fmt.Errorf("-role family needs exactly one -resident, and got %d", len(residents))
		}
	default:
		return fmt.Errorf("role %q is not one this creates: caregiver, care_manager or family", *role)
	}

	// A reset needs the address and nothing else: the account is already there, with a
	// facility and assignments it is not this command's business to change.
	if *reset {
		if *email == "" {
			fs.Usage()
			return errors.New("--reset needs --email")
		}
		return issueReset(ctx, *email)
	}

	if *revoke {
		if *email == "" || len(residents) != 1 || *by == "" {
			fs.Usage()
			return errors.New("--revoke needs --email, exactly one --resident, and --by")
		}
		return revokeAccess(ctx, *email, residents[0], *by)
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
	conn, err := connect(ctx, dsn)
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

	// An email that is already there belongs to somebody, and what to do about that
	// depends on what is being asked for.
	//
	// Creating an account is still refused: the difference between that and resetting a
	// stranger's password is not one this should decide for whoever typed the command.
	//
	// A second family grant is not that, and the plan for this milestone says so in as many
	// words - a second resident is another row, not another account, because two parents in
	// the same building is the ordinary case. Refusing it meant a facility could link a
	// daughter to her mother and then had no way to link her to her father; measured on
	// staging, where the second grant was refused with the password sentence above and the
	// switcher the app had been built for could never appear.
	var existing *uuid.UUID
	var found uuid.UUID
	err = tx.QueryRow(ctx,
		`SELECT id FROM users WHERE lower(email) = lower($1)`, *email).Scan(&found)
	if err == nil {
		existing = &found
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if existing != nil && *role != "family" {
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
	//
	// Not written at all for somebody who is already here. Their name is theirs - they may
	// have corrected it through users_update_self since - and overwriting it from a command
	// line would be an administrator renaming a person to add a grant.
	var userID uuid.UUID
	if existing != nil {
		userID = *existing
	} else if err := tx.QueryRow(ctx,
		`INSERT INTO users (email, display_name) VALUES ($1,$2) RETURNING id`,
		*email, *name).Scan(&userID); err != nil {
		return err
	}

	grantState := ""
	if *role == "family" {
		// The grant is made as the person making it, not as whatever role this job
		// connects with.
		//
		// resident_contacts is forced, so the owner of the schema is subject to its
		// policies like anybody else, and contacts_insert admits a care manager of that
		// facility and nobody else. Refused here at first, correctly: a migration identity
		// is not a care manager and a family grant is not a migration. facility_members is
		// not forced, which is why the caregiver path never met this.
		//
		// So -by stops being only a column. It is who this is being done as, and if they
		// are not a care manager of this facility the database refuses - which is the
		// check that was always written down and had nothing asking it.
		if actor == nil {
			return fmt.Errorf("-role family needs -by: a grant is made by a named care manager")
		}
		if _, err := tx.Exec(ctx,
			`SELECT set_config('app.user_id', $1, true)`, actor.String()); err != nil {
			return fmt.Errorf("identifying %s: %w", *by, err)
		}

		// Not a facility member. A family member works for nobody; they hold a grant
		// against one resident, and resident_contacts is where that lives.
		//
		// 'invited' rather than 'active', which is the state the enum has always described
		// and nothing could produce until now. A caregiver's membership opens active
		// because for staff the only open question is whether they have a password. A
		// family grant is a disclosure, and a facility that has sent an invitation and one
		// that has a reader are different things for it to see. redeem_token moves it when
		// they accept - see family-access.sql - and app_is_contact() reads nothing until
		// it does.
		// 'invited' only while there is something to wait for.
		//
		// The first grant waits because nobody has yet proved they hold that address, and
		// redeem_token is what both establishes the password and activates the grant. An
		// account that can already sign in has nothing pending: there is no accept button in
		// this product, and the only thing that ever moved a grant to active was redeeming a
		// credential. So a second grant written 'invited' would sit there forever - a
		// facility would be told a daughter could read her father and she would open the app
		// and see only her mother.
		//
		// Which is the same shape as the fault this milestone already produced once, when
		// the activation reported success and changed nothing. Measured rather than
		// reasoned about this time: see the live check after it.
		state := "invited"
		if existing != nil {
			var canSignIn bool
			if err := tx.QueryRow(ctx,
				`SELECT password_hash IS NOT NULL FROM users WHERE id = $1`, userID).
				Scan(&canSignIn); err != nil {
				return err
			}
			if canSignIn {
				state = "active"
			}
		}

		if _, err := tx.Exec(ctx,
			`INSERT INTO resident_contacts
			   (facility_id, resident_id, user_id, relation, state, granted_by, granted_at)
			 VALUES ($1,$2,$3,$4,$5,$6, now())`,
			*facility, residents[0], userID, *relation, state, actor); err != nil {
			// UNIQUE (resident_id, user_id) is what says they already hold one, and the
			// constraint is allowed to be the thing that says it. Asking first would mean
			// reading resident_contacts here, which is a read of who is linked to whom
			// that no audit_read would record - the one thing the guard in
			// internal/records exists to stop, and it stopped this.
			//
			// Which state the existing grant is in is therefore not reported, and does not
			// need to be: none of the three is this command's to move. An invitation is
			// outstanding, a reader is live, or access was withdrawn - and putting a
			// withdrawn grant back is a decision with a person behind it, which belongs to
			// the care manager's own screen rather than to a job asked to make a new one.
			var pg *pgconn.PgError
			if errors.As(err, &pg) && pg.Code == "23505" {
				return fmt.Errorf("%s already holds a grant for that resident. This creates "+
					"grants and does not change the ones that are there", *email)
			}
			return fmt.Errorf("granting access to %s: %w", residents[0], err)
		}
		grantState = state
	} else {
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
	}

	// An invitation only for somebody who has no way in yet.
	//
	// A second grant for an account that already exists needs none: they have a password, or
	// an invitation already outstanding, and a fresh one would be a second credential for
	// the same person issued because a facility added a resident. The grant still waits at
	// 'invited' - accepting it is the next sign-in, because redeem_token activates every
	// invited grant the account holds and signing in is enough for one made this way.
	invite := existing == nil
	if invite {
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at)
			 VALUES ($1, 'invitation', $2, now() + interval '7 days')`,
			userID, digest); err != nil {
			return err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return err
	}

	// Everything the operator needs to read is on stderr; the passphrase alone is on
	// stdout, so it can be piped somewhere without the commentary and so a log that
	// captures one stream does not necessarily capture both.
	fmt.Fprintf(os.Stderr, "\n%s is %s, %s in %s\n", *name, userID, *role, *facility)
	if *role == "family" {
		fmt.Fprintf(os.Stderr, "They read this one resident and nothing else, and cannot record anything.\n")
		if grantState == "active" {
			fmt.Fprintf(os.Stderr,
				"This is a further resident for an account that already exists, so no second\n"+
					"invitation is issued and the grant is live now. They see them on their next\n"+
					"refresh.\n")
		} else {
			fmt.Fprintf(os.Stderr, "The grant is not live until they accept the invitation below.\n")
		}
	} else if *role == "care_manager" {
		// A care manager is not assigned to anybody and does not need to be: the policies
		// give them every resident in their own facility. Printed separately because the
		// line below is written for a caregiver and is wrong here in both directions - it
		// asks for assignments that do nothing, and it says they can see nothing when they
		// can see the building. Measured on staging: a care manager with no assignments
		// reads two residents, and a caregiver with no assignments reads none.
		fmt.Fprintf(os.Stderr,
			"As a care manager they see every resident in this facility. Assignments are\n"+
				"for caregivers and are not needed here.\n")
	} else if len(residents) == 0 {
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
	if !invite {
		return nil
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

// revokeAccess withdraws one family member's access to one resident.
//
// Not a delete. The row stays, with who took it away and when, because a reviewer asks
// both and neither can be reconstructed from a row that is gone - which is also why
// access-policies.sql has no DELETE policy on this table at all.
//
// Per resident, like the grant. Somebody linked to two residents who should only lose one
// keeps the other, and that is the ordinary case rather than the awkward one.
//
// Run as the care manager doing it, for the same reason the grant is: contacts_update
// admits a care manager of that facility and the table is forced, so an unidentified
// session changes nothing. revoked_by is then a name the database agreed to rather than
// one it was handed.
func revokeAccess(ctx context.Context, email, resident, by string) error {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return errors.New("DATABASE_URL is not set")
	}
	conn, err := connect(ctx, dsn)
	if err != nil {
		return err
	}
	defer conn.Close(ctx)

	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var actor uuid.UUID
	if err := tx.QueryRow(ctx,
		`SELECT id FROM users WHERE lower(email) = lower($1)`, by).Scan(&actor); err != nil {
		return fmt.Errorf("--by %s: no account with that address", by)
	}
	if _, err := tx.Exec(ctx,
		`SELECT set_config('app.user_id', $1, true)`, actor.String()); err != nil {
		return err
	}

	var holder uuid.UUID
	if err := tx.QueryRow(ctx,
		`SELECT id FROM users WHERE lower(email) = lower($1)`, email).Scan(&holder); err != nil {
		return fmt.Errorf("no account for %s", email)
	}

	// Only a grant that is live. Revoking one already revoked would move revoked_at to
	// today and lose the date it actually happened, which is the one thing this row is for.
	tag, err := tx.Exec(ctx,
		`UPDATE resident_contacts
		    SET state = 'revoked', revoked_by = $1, revoked_at = now(), updated_at = now()
		  WHERE user_id = $2 AND resident_id = $3 AND state <> 'revoked'`,
		actor, holder, resident)
	if err != nil {
		return fmt.Errorf("withdrawing access: %w", err)
	}
	if tag.RowsAffected() == 0 {
		// Nothing changed, and an update a policy filters out says nothing either - so the
		// two cases are reported together rather than guessed between. The caller knows
		// which they meant.
		return fmt.Errorf(
			"nothing was withdrawn: %s holds no live grant for that resident, or %s is not a care manager of their facility",
			email, by)
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}

	fmt.Fprintf(os.Stderr, "\n%s no longer reads %s.\n", email, resident)
	fmt.Fprintf(os.Stderr,
		"The row is kept, with who withdrew it and when. Their account and any other\n"+
			"resident they are linked to are untouched.\n")
	return nil
}

// issueReset gives an existing account a way back in.
//
// The other half of the same mechanism: redeem_token takes the purpose, so a reset link
// and an invitation are the same act with a different row behind them. It is manual for
// the same reason account creation is - there is nothing that can send an email yet, and
// a reset somebody can request for themselves without one is a way to hand an account to
// whoever asks.
//
// It does not say whether the address exists. Somebody running this command knows who
// they meant; the refusal is for the case where they mistyped, and it costs one look.
func issueReset(ctx context.Context, email string) error {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return errors.New("DATABASE_URL is not set")
	}
	conn, err := connect(ctx, dsn)
	if err != nil {
		return err
	}
	defer conn.Close(ctx)

	var userID uuid.UUID
	var active bool
	if err := conn.QueryRow(ctx,
		`SELECT id, deactivated_at IS NULL FROM users WHERE lower(email) = lower($1)`,
		email).Scan(&userID, &active); err != nil {
		return fmt.Errorf("no account for %s", email)
	}
	if !active {
		// Reactivating is a different decision and this is not it. A reset issued here
		// would be refused at redemption anyway, and the person holding it would have no
		// way to know why.
		return fmt.Errorf("%s is deactivated. Reactivate the account first", email)
	}

	link, digest, err := auth.NewToken()
	if err != nil {
		return err
	}
	// An hour, not a week. An invitation is expected to sit in somebody's inbox until
	// their next shift; a reset is somebody standing there now, and the window is the only
	// thing limiting a link that is read off a screen.
	if _, err := conn.Exec(ctx,
		`INSERT INTO user_tokens (user_id, purpose, token_hash, expires_at)
		 VALUES ($1, 'password_reset', $2, now() + interval '1 hour')`,
		userID, digest); err != nil {
		return err
	}

	fmt.Fprintf(os.Stderr, "\nA reset for %s. It lasts one hour, works once, and every\n"+
		"session they have open now will end when they use it:\n\n", email)
	fmt.Println(link)
	return nil
}

// One connection, authenticated the way the API authenticates.
//
// This runs as a Cloud Run job with no password when the migration identity is in play,
// and with one while the old path is still there. db.Authenticate decides by looking at
// what it was given rather than by a flag.
func connect(ctx context.Context, dsn string) (*pgx.Conn, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("bootstrap: %w", err)
	}
	if err := db.Authenticate(ctx, cfg); err != nil {
		return nil, err
	}
	return pgx.ConnectConfig(ctx, cfg)
}
