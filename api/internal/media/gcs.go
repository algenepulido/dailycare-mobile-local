package media

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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

	// Set only by NewGCSWithToken. Empty everywhere it matters.
	token string
}

func NewGCS(ctx context.Context, serviceAccount string) (*GCS, error) {
	c, err := storage.NewClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("media: cloud storage: %w", err)
	}
	return &GCS{client: c, serviceAccount: serviceAccount}, nil
}

// NewGCSWithToken signs through the IAM signBlob API using a bearer token supplied by the
// caller, for running against a real bucket from somewhere that has no
// application-default credentials - which is every machine here, since these projects
// deliberately do not use ADC.
//
// On Cloud Run none of this is needed: the metadata server answers, the library finds the
// revision's identity, and NewGCS is the constructor. This one exists so the path can be
// exercised before it is deployed rather than after.
func NewGCSWithToken(serviceAccount, token string) *GCS {
	return &GCS{serviceAccount: serviceAccount, token: token}
}

func (g *GCS) Close() error {
	if g.client == nil {
		return nil
	}
	return g.client.Close()
}

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

	return g.sign(ctx, bucket, object, opts)
}

// SignedGetURL is a link to look at one photograph, and nothing else.
//
// No ContentType: that option pins what an upload may send and has no meaning for a read,
// and setting it would put a Content-Type into the signature that a plain GET does not
// send - which fails as SignatureDoesNotMatch and reads like a permissions problem. The
// same trap the upload path fell into from the other side.
//
// Minted only when somebody is about to look. A signed URL cannot be withdrawn once it
// exists, so the control is its lifetime, and issuing one per photograph on every read of
// a day would hand out links nobody asked to see.
func (g *GCS) SignedGetURL(ctx context.Context, bucket, object string,
	until time.Time) (string, error) {
	opts := &storage.SignedURLOptions{
		Scheme:  storage.SigningSchemeV4,
		Method:  "GET",
		Expires: until,
	}
	if g.serviceAccount != "" {
		opts.GoogleAccessID = g.serviceAccount
	}
	return g.sign(ctx, bucket, object, opts)
}

// One place that knows how the signing actually happens, so the GET and the PUT cannot
// drift into signing differently.
func (g *GCS) sign(ctx context.Context, bucket, object string,
	opts *storage.SignedURLOptions) (string, error) {
	if g.token != "" {
		opts.SignBytes = func(b []byte) ([]byte, error) { return g.signBlob(ctx, b) }
		url, err := storage.SignedURL(bucket, object, opts)
		if err != nil {
			return "", fmt.Errorf("media: signing %s: %w", object, err)
		}
		return url, nil
	}

	url, err := g.client.Bucket(bucket).SignedURL(object, opts)
	if err != nil {
		return "", fmt.Errorf("media: signing %s: %w", object, err)
	}
	return url, nil
}

// What the storage library does for itself when there is no private key: asks IAM to sign
// the bytes as the service account. There is no key to hold, which is what makes
// iam.disableServiceAccountKeyCreation enforceable rather than aspirational.
func (g *GCS) signBlob(ctx context.Context, payload []byte) ([]byte, error) {
	body, err := json.Marshal(map[string]string{
		"payload": base64.StdEncoding.EncodeToString(payload),
	})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/"+
			g.serviceAccount+":signBlob", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+g.token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		// The status, not the body. A signBlob refusal quotes the caller's identity.
		return nil, fmt.Errorf("media: signBlob returned %d", resp.StatusCode)
	}
	var out struct {
		SignedBlob string `json:"signedBlob"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return base64.StdEncoding.DecodeString(out.SignedBlob)
}
