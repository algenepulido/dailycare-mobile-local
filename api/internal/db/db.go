// Package db opens the pool and runs every request inside a transaction that has said who
// it is.
//
// The policies in docs/architecture read app.user_id. A statement outside such a
// transaction sees nothing at all, which is the right default and also an easy one to
// arrive at by accident - a handler that forgets returns an empty list rather than an
// error, and an empty list looks like a resident with no care records.
//
// So there is no way to get a connection out of this package without saying who is asking.
// Pool is unexported and the only way through is InSession.
package db

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/oauth2/google"
)

type DB struct{ pool *pgxpool.Pool }

// Who the database is being asked as. Every field goes into a setting the audit triggers
// read, so an audit row can say which request wrote it without the handler remembering to
// pass anything along.
type Caller struct {
	UserID    uuid.UUID
	Role      string // the application role name, for the audit row
	RequestID string
}

var ErrNoCaller = errors.New("db: a query was attempted without a caller")

// Authenticate puts a token where the password goes, when the user is an IAM one and no
// password was given.
//
// Open uses it for the pool the API serves from. bootstrap uses it for a single
// connection, and it has to be the same code: an administrative command that authenticates
// differently from the thing it is administering is a second way in, and the second way is
// the one nobody tests.
func Authenticate(ctx context.Context, cfg *pgx.ConnConfig) error {
	if cfg.Password != "" || !strings.HasSuffix(cfg.User, ".iam") {
		return nil
	}
	source, err := google.DefaultTokenSource(ctx,
		"https://www.googleapis.com/auth/sqlservice.login")
	if err != nil {
		return fmt.Errorf("db: no identity to authenticate as: %w", err)
	}
	token, err := source.Token()
	if err != nil {
		return fmt.Errorf("db: getting a database token: %w", err)
	}
	cfg.Password = token.AccessToken
	return nil
}

func Open(ctx context.Context, dsn string) (*DB, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("db: %w", err)
	}

	// Cloud SQL's IAM authentication puts an OAuth access token where the password goes.
	// Nothing holds a database password anywhere - not this process, not Secret Manager,
	// not a developer's shell - which is the whole reason for turning it on.
	//
	// The token is fetched per connection rather than once. They last an hour and the pool
	// outlives that, so a token read at start-up would work until the first idle stretch
	// and then fail in a way that looks like the database going away.
	// Per connection rather than once here, because a token lasts an hour and the pool
	// outlives that: reading one at start-up works until the first idle stretch and then
	// fails in a way that looks like the database going away.
	if cfg.ConnConfig.Password == "" && strings.HasSuffix(cfg.ConnConfig.User, ".iam") {
		cfg.BeforeConnect = func(ctx context.Context, c *pgx.ConnConfig) error {
			return Authenticate(ctx, c)
		}
	}
	// Small. Cloud SQL counts connections, and a caregiver app's traffic is a few requests
	// per shift per phone rather than a firehose.
	cfg.MaxConns = 8
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("db: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		return nil, fmt.Errorf("db: %w", err)
	}
	return &DB{pool: pool}, nil
}

func (d *DB) Close() { d.pool.Close() }

// InSession runs fn inside one transaction with the caller's identity set for its
// duration. SET LOCAL rather than SET, so the setting cannot outlive the transaction and
// reach the next request that borrows the same pooled connection - which would hand one
// caregiver another one's identity, silently, under load.
func (d *DB) InSession(ctx context.Context, c Caller, fn func(pgx.Tx) error) error {
	if c.UserID == uuid.Nil {
		return ErrNoCaller
	}
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx,
		`SELECT set_config('app.user_id', $1, true),
		        set_config('app.role', $2, true),
		        set_config('app.request_id', $3, true)`,
		c.UserID.String(), c.Role, c.RequestID); err != nil {
		return fmt.Errorf("db: setting the caller: %w", err)
	}
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Unidentified is for the handful of things that happen before anybody is identified:
// looking up a session, consuming an invitation. It sets no identity, so the policies hide
// everything the application role is not explicitly granted - which is why sign-in reads
// through SECURITY DEFINER functions rather than selecting from users.
func (d *DB) Unidentified(ctx context.Context, fn func(pgx.Tx) error) error {
	tx, err := d.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
