// Package media is where a photograph of a resident goes.
//
// The photograph does not pass through this process. The app asks for a place to put one,
// gets a URL good for a few minutes and for that one object, and uploads to Cloud Storage
// directly - so a care photo is never in the API's memory, its logs, or a load balancer's
// buffers on the way through.
//
// Two things the API cannot do with a photograph once it exists, and both are IAM rather
// than code: it cannot delete one, and it cannot overwrite one. The service account holds
// objectCreator and objectViewer; objectAdmin, which includes objects.delete, belongs to
// the retention job alone. GCS needs objects.delete to overwrite as well as to remove, so
// the split is what stops a filed photograph being replaced with a different one.
package media

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"path"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/dailycare-hq/dailycare-api/internal/db"
)

// How long an upload URL is good for. Long enough for a photograph over a ward's wifi,
// short enough that one copied out of a log is no use by the time anybody reads it.
const UploadWindow = 10 * time.Minute

var ErrNotVisible = errors.New("media: no such resident, or not one this session may read")

// Signer is whatever can sign a URL for the bucket. In a deployed environment it is the
// Cloud Storage client using the service account's own signBlob, so no key exists anywhere
// - which is what makes iam.disableServiceAccountKeyCreation possible to enforce.
type Signer interface {
	SignedPutURL(ctx context.Context, bucket, object, contentType string, until time.Time) (string, error)
	SignedGetURL(ctx context.Context, bucket, object string, until time.Time) (string, error)
}

type Store struct {
	db     *db.DB
	bucket string
	signer Signer
}

func New(d *db.DB, bucket string, s Signer) *Store {
	return &Store{db: d, bucket: bucket, signer: s}
}

type Upload struct {
	URL       string    `json:"url"`
	ObjectID  uuid.UUID `json:"objectId"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// Offer returns somewhere to put a photograph, and records that it did.
//
// The caller does not choose the path. It is built here from the facility, the resident
// and a random name, and the table carries a constraint that the path starts with the
// facility the row belongs to - so a row cannot be made to point at another building's
// object even if this function were wrong about it.
func (s *Store) Offer(ctx context.Context, c db.Caller, resident uuid.UUID,
	careDay *uuid.UUID, contentType string, size int64) (*Upload, error) {

	if !allowedType[contentType] {
		return nil, fmt.Errorf("media: %q is not a kind of photograph this takes", contentType)
	}

	var out Upload
	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		// audit_read first, and it is also the access check: it refuses to record a read
		// of a resident this session cannot see, so a caller who cannot see the resident
		// never gets as far as a path with that facility in it.
		if _, err := tx.Exec(ctx, `SELECT audit_read($1, $2)`, resident, "media_objects"); err != nil {
			return ErrNotVisible
		}

		var facility uuid.UUID
		if err := tx.QueryRow(ctx,
			`SELECT facility_id FROM residents WHERE id = $1`, resident).Scan(&facility); err != nil {
			return ErrNotVisible
		}

		object := objectPath(facility, resident, contentType)
		if err := tx.QueryRow(ctx, `
			INSERT INTO media_objects
			  (facility_id, resident_id, care_day_id, bucket, object_path,
			   content_type, byte_size, uploaded_by)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
			RETURNING id`,
			facility, resident, careDay, s.bucket, object,
			contentType, size, c.UserID).Scan(&out.ObjectID); err != nil {
			return err
		}

		out.ExpiresAt = time.Now().Add(UploadWindow)
		url, err := s.signer.SignedPutURL(ctx, s.bucket, object, contentType, out.ExpiresAt)
		if err != nil {
			return fmt.Errorf("media: signing: %w", err)
		}
		out.URL = url
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}

// The types a phone camera produces, and nothing else. Not because an arbitrary type would
// break anything here, but because a bucket that accepts anything is a bucket somebody
// eventually uses for something else.
var allowedType = map[string]bool{
	"image/jpeg": true,
	"image/png":  true,
	"image/heic": true,
	// Android's picker returns these for a screenshot or a shared image, and the client
	// will send one. A type the client can produce and the server refuses is an upload
	// that fails after the day is already filed, which is the worst moment for it.
	"image/webp": true,
}

// facility/resident/random.ext
//
// The facility first, because that is what the CHECK constraint reads and what a lifecycle
// rule or an export would be scoped by. Random rather than sequential: an object name that
// counts tells anybody who sees one how many there are.
func objectPath(facility, resident uuid.UUID, contentType string) string {
	name := make([]byte, 16)
	rand.Read(name)
	return path.Join(facility.String(), resident.String(), hex.EncodeToString(name)+extensionFor(contentType))
}

func extensionFor(contentType string) string {
	switch contentType {
	case "image/png":
		return ".png"
	case "image/heic":
		return ".heic"
	default:
		return ".jpg"
	}
}

// Arrived records that the object is actually in the bucket.
//
// Between Offer and this there is a row describing a photograph that may never come: a
// phone that lost signal, or a signature that did not match. Those rows are real and
// media_never_arrived lists them; what must not happen is one of them being counted as a
// photograph - shown to a family, or looked for by retention.
//
// Only the account that asked for the place may say it arrived, and only once.
func (s *Store) Arrived(ctx context.Context, c db.Caller, object uuid.UUID) error {
	return s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `
			UPDATE media_objects SET uploaded_at = now()
			WHERE id = $1 AND uploaded_by = $2 AND uploaded_at IS NULL`,
			object, c.UserID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			// Unknown, somebody else's, or already said. All three are the same answer
			// to the caller: nothing changed and there is nothing to tell them about it.
			return ErrNotVisible
		}
		return nil
	})
}

// How long a link to look at a photograph lasts.
//
// Short because it cannot be taken back. media_read decides who may have one and is
// consulted before it is minted, but a link already handed out keeps working whatever
// happens to that row afterwards - so the lifetime is the control, and it is the only one.
const viewFor = 5 * time.Minute

type Photograph struct {
	ID        uuid.UUID `json:"id"`
	URL       string    `json:"url"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// ForDay returns links to the photographs filed for a resident on a date.
//
// Resolved by the resident and the date rather than by one care_days row. A correction
// makes a new row and the photograph stays attached to the one it was filed against, so
// `WHERE care_day_id = <the current row>` returns nothing the moment somebody fixes a
// typo - which is exactly the trap schema-invariants.sql names and tests.
//
// Only photographs that actually arrived, and are not deleted. A row whose upload never
// finished describes an object that is not there, and a link to it is a broken image in
// front of a family.
func (s *Store) ForDay(ctx context.Context, c db.Caller, resident uuid.UUID,
	on time.Time) ([]Photograph, error) {
	type found struct {
		id     uuid.UUID
		bucket string
		path   string
	}
	var rows []found

	err := s.db.InSession(ctx, c, func(tx pgx.Tx) error {
		// audit_read first, in the same transaction, so a read that is not in the trail is
		// a read that did not happen. It is also the access check: it refuses to record a
		// read of a resident this session cannot see, and it does that before any row is
		// fetched and long before any link is minted.
		//
		// This was missing on the first attempt and the package's own source-level guard
		// caught it - looking at a family's photographs is exactly the read HIPAA's audit
		// controls are about, and it would have left no trace.
		if _, err := tx.Exec(ctx, `SELECT audit_read($1, $2)`, resident, "media_objects"); err != nil {
			return ErrNotVisible
		}

		// media_read is what admits the caller to the rows themselves.
		r, err := tx.Query(ctx, `
			SELECT m.id, m.bucket, m.object_path
			FROM media_objects m
			JOIN care_days cd ON cd.id = m.care_day_id
			WHERE cd.resident_id = $1 AND cd.care_date = $2
			  AND m.uploaded_at IS NOT NULL AND m.deleted_at IS NULL
			ORDER BY m.uploaded_at`, resident, on)
		if err != nil {
			return err
		}
		defer r.Close()
		for r.Next() {
			var f found
			if err := r.Scan(&f.id, &f.bucket, &f.path); err != nil {
				return err
			}
			rows = append(rows, f)
		}
		return r.Err()
	})
	if err != nil {
		return nil, err
	}

	// Signing outside the transaction. Each one is a network call to IAM, and holding a
	// database session open across them would keep a connection for the length of the
	// slowest thing in the request.
	until := time.Now().Add(viewFor)
	out := make([]Photograph, 0, len(rows))
	for _, f := range rows {
		url, err := s.signer.SignedGetURL(ctx, f.bucket, f.path, until)
		if err != nil {
			return nil, err
		}
		out = append(out, Photograph{ID: f.id, URL: url, ExpiresAt: until})
	}
	return out, nil
}
