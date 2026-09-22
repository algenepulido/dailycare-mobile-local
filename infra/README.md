# Infrastructure

The application layer — Cloud SQL, the buckets, the VPC connector, Cloud Run. The projects
themselves, the org policies, the service accounts, the secret shells and CI are Inktree's
and live in their monorepo; `docs/gcp-as-built.md` is the handover that says which is which.

Two rules from that handover, both of them load-bearing:

**Separate state.** This layer keeps its own state file under a prefix of its own in the
state bucket Inktree made. If both layers try to own the same service account, they take
turns deleting each other's work.

**Read their identities, never recreate them.** Every service account here is a
`data` block. Terraform that creates a service account it does not own will happily destroy
it on the next apply that thinks it should not exist.

    cd dev
    export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)
    terraform init
    terraform plan

The token export is not optional: these projects do not use application-default
credentials, which is the handover's one auth quirk and the first thing that will look like
a broken provider.

## What it builds, and the one control that is not obvious

The photo bucket's object roles are the retention design, expressed as IAM:

| Identity | Role | Why |
|---|---|---|
| `dc-dev-api` | `objectCreator` | Writes a photograph. Cannot replace one — GCS needs `objects.delete` to overwrite, so `objectCreator` forbids both. |
| `dc-dev-api` | `objectViewer` | Reads it back. |
| `dc-dev-retention` | `objectAdmin` | The only identity that may delete, and only on the schedule the retention policy sets. |

Giving the API `objectAdmin` instead would collapse that into nothing, silently: it looks
like one role rather than two and it includes delete. That happened in the first draft of
`gcp-iam.sql` and the checks caught it.
