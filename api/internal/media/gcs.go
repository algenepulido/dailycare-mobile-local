package media

import (
	"context"
	"fmt"
	"time"

	"cloud.google.com/go/storage"
)

// GCS signs with the service account's own identity rather than with a key.
//
// SignedURL with no PrivateKey falls back to the IAM signBlob API, which is why the api
// account holds serviceAccountTokenCreator on itself and why
// iam.disableServiceAccountKeyCreation can be enforced at all: there is no key to
// download because nothing here ever needed one.
type GCS struct {
	client *storage.Client
	// The account doing the signing. Empty when running on Cloud Run, where the metadata
	// server answers with the identity the revision runs as.
	serviceAccount string
}

func NewGCS(ctx context.Context, serviceAccount string) (*GCS, error) {
	c, err := storage.NewClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("media: cloud storage: %w", err)
	}
	return &GCS{client: c, serviceAccount: serviceAccount}, nil
}

func (g *GCS) Close() error { return g.client.Close() }

func (g *GCS) SignedPutURL(ctx context.Context, bucket, object, contentType string,
	until time.Time) (string, error) {
	opts := &storage.SignedURLOptions{
		Scheme:  storage.SigningSchemeV4,
		Method:  "PUT",
		Expires: until,
		// Pinned, and the upload has to send the same one. Without it a URL signed for a
		// photograph would take anything at all, which is how a media bucket becomes a
		// file host.
		ContentType: contentType,
	}
	if g.serviceAccount != "" {
		opts.GoogleAccessID = g.serviceAccount
	}
	url, err := g.client.Bucket(bucket).SignedURL(object, opts)
	if err != nil {
		return "", fmt.Errorf("media: signing %s: %w", object, err)
	}
	return url, nil
}
