// The DailyCare API.
//
// Everything it is allowed to do is decided elsewhere - by roles.sql, by the policies in
// access-policies.sql, and by which functions grants.sql lets it call. This process
// authenticates a request, says whose uuid it is carrying, and gets out of the way.
package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/dailycare-hq/dailycare-api/internal/auth"
	"github.com/dailycare-hq/dailycare-api/internal/db"
	"github.com/dailycare-hq/dailycare-api/internal/httpapi"
	"github.com/dailycare-hq/dailycare-api/internal/logging"
	"github.com/dailycare-hq/dailycare-api/internal/records"
	"github.com/dailycare-hq/dailycare-api/internal/sessions"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "dailycare-api: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		return errors.New("DATABASE_URL is not set")
	}

	// From Secret Manager in a deployed environment, where the api account is granted
	// jwt_signing_key and three others and nothing else.
	key := os.Getenv("JWT_SIGNING_KEY")
	if key == "" {
		return errors.New("JWT_SIGNING_KEY is not set")
	}
	signer, err := auth.NewSigner([]byte(key))
	if err != nil {
		return err
	}

	database, err := db.Open(ctx, dsn)
	if err != nil {
		return err
	}
	defer database.Close()

	// The list of fields that must never be logged is read from the database at start-up,
	// not written down here. never_log is computed from the classification, so a column
	// added to the model is on the list without this file changing - and if the query
	// fails, the process does not start. A logger that quietly fell back to an empty list
	// would be a logger with no rules, at exactly the moment nobody was watching.
	neverLog, err := loadNeverLog(ctx, database)
	if err != nil {
		return fmt.Errorf("reading never_log: %w", err)
	}
	log := logging.New(os.Stdout, neverLog)
	log.Info("starting", logging.F("fields_that_will_be_redacted", len(neverLog)))

	api := httpapi.New(sessions.New(database, signer), records.New(database), log)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	server := &http.Server{
		Addr:    ":" + port,
		Handler: api.Routes(),
		// A caregiver on a ward's wifi is slow, not malicious, but a socket held open
		// costs the same either way.
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		<-ctx.Done()
		// Cloud Run sends SIGTERM and then waits. Finishing the request in flight is the
		// difference between a caregiver's care note being filed and being retyped.
		shutdown, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		server.Shutdown(shutdown)
	}()

	log.Info("listening", logging.F("port", port))
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	log.Info("stopped")
	return nil
}

func loadNeverLog(ctx context.Context, database *db.DB) ([]string, error) {
	var fields []string
	err := database.Unidentified(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT field FROM never_log ORDER BY field`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var f string
			if err := rows.Scan(&f); err != nil {
				return err
			}
			fields = append(fields, f)
		}
		return rows.Err()
	})
	if err != nil {
		return nil, err
	}
	if len(fields) == 0 {
		return nil, errors.New("never_log came back empty, which would mean no rules at all")
	}
	return fields, nil
}
