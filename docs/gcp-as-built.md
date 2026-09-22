# DailyCare on GCP — as built

**For:** Algene Pulido
**From:** Inktree (Trevor / production@inktree.ai)
**Date:** 21 September 2026, revised 22 September after your reply

---

## The short version

**The projects exist.** All three were created on 10 September 2026 and the Google Cloud BAA was accepted the same day. Your `docs/architecture/README.md` and `architecture-diagram.md` say "the platform agreement is signed, the project is not created" — that was true when you wrote it and nobody told you otherwise. Apologies for the gap; it was ours.

As of today dev and staging are fully provisioned: guardrails, audit logging, the four service accounts you asked for, a deploy-only CI identity, secret shells, an image registry, and your access. **M2 is not blocked on us.**

What follows is what is there, what is deliberately not there, and the handful of things that will behave differently from a vanilla project.

---

## The projects

| Project ID | Number | Purpose | Data |
|---|---|---|---|
| `inktree-dailycare-dev` | `144065101336` | Your sandbox | Synthetic only |
| `inktree-dailycare-staging` | `1020149956206` | Pre-production | Synthetic only |
| `inktree-dailycare-prod` | `692675456098` | Production | Nothing until the M6 gate |

Region is `us-central1` everywhere. They are separate from the Inktree platform projects — no shared services, buckets, logging or IAM — which is the project-level separation your open-questions list asked for.

Production currently has guardrails and nothing else: no service accounts, no registry, no access for anyone but the org admin. We will build it out alongside M6 rather than leaving an unfinished production project sitting there.

## Signing in

Use **`jenith.dev1202@gmail.com`**. That is the account every binding below was granted to.

```bash
gcloud auth login
gcloud config set project inktree-dailycare-dev
gcloud projects describe inktree-dailycare-dev    # should work
```

**Please confirm that is the right address.** If you intend to use a different Google account, tell us and we will move the bindings — a binding on the wrong address grants nothing and fails in a way that looks identical to a policy problem, which is an afternoon nobody enjoys.

## What you can do, where

| | dev | staging | prod |
|---|---|---|---|
| Access | Self-serve build | **Same as dev** | None |

**Dev** is yours to build in. You hold named admin roles across Cloud Run, Cloud SQL, Storage, Secret Manager, Artifact Registry, VPC, Service Networking, Cloud Scheduler, and Service Usage — enough to stand up everything in your architecture diagram without asking us for anything.

What you deliberately do not have, in any project: `roles/owner`, `roles/editor`, `resourcemanager.projectIamAdmin`, and — since 22 September, at your request — `roles/viewer`, `roles/iam.serviceAccountAdmin`, and project-level `roles/iam.serviceAccountTokenCreator`. Impersonation is now per account: `serviceAccountUser` and `serviceAccountTokenCreator` on each of the four workload accounts, in both environments. If you need a role that is not on the list, ask and we will add it — that is a two-minute change, not a negotiation.

You also hold a custom role, `dailycareIamReader`, in both projects. Ten permissions: `get` and `getIamPolicy` on the project, `list` and `getIamPolicy` on service accounts, secrets, buckets and repositories. That is what your checker needs to read every scope in `gcp_iam`, and it is what replaced `viewer`. We chose it over `roles/browser` because browser only reads project scope — it would miss the bucket bindings, which is where the photo-delete control lives — and it reaches folders and the organisation, which nobody needs.

**Staging** was the nine deploy-only roles from your handover. As of 22 September it is the same set as dev, so you can stand staging up — instance, VPC, connector, buckets — the way you did dev, without waiting on us for each piece. Staging holds synthetic data only until M6, which is the same reasoning Trevor applied to dev. Your point that the deploy-only set could not read its own policy is what prompted it; a read role alone would have left you filing a request for every bucket.

Every staging binding carries an IAM condition expiring **2026-12-20T00:00:00Z**. That is 90 days, sized for M2 at 40 hours. It is enforced by Google, not by anyone remembering — if M2 runs long, say so and we extend it. It is not a deadline, just a default that fails closed.

## Four guardrails you will notice

These are project-level org policies and they apply to everyone equally, including us.

**1. Service-account keys cannot be created.** `iam.disableServiceAccountKeyCreation`. There is no JSON key to download, for you or for CI. Use impersonation:

```bash
gcloud run deploy ... --impersonate-service-account=dc-dev-api@inktree-dailycare-dev.iam.gserviceaccount.com
```

This is the one your `encryption-and-secrets.sql` calls the classic breach vector, so we made it structural rather than a rule.

One practical note: org policies take **up to ~15 minutes** to reach the enforcement point. We watched a key creation succeed one minute after the policy was written and be correctly refused ten minutes later. If you test a freshly-changed policy, wait before concluding anything.

**2. Cloud SQL cannot have a public IP.** `sql.restrictPublicIp`. Your design says the instance has no public address; this makes that unskippable. You will need a VPC connector for Cloud Run to reach it — `vpcaccess.admin` is on your list.

While you are there: set `ssl_mode = "ENCRYPTED_ONLY"` on the instance. Our platform's database module does not, and the security scanner flags it; your `in_transit_database` control wants TLS, so this is the one place not to copy us.

**3. Buckets cannot be made public.** `storage.publicAccessPrevention`. Signed URLs still work normally; this only forecloses `allUsers`.

**4. Resources must be in the US.** `gcp.resourceLocations` = `in:us-locations`. Pick `us-central1` and you will never see this one.

Plus **Data Access audit logging is on for all services** — `ADMIN_READ`, `DATA_READ`, `DATA_WRITE`. This is the "who looked at which resident's record" trail your M3 needs, and GCP does not do it by default. Please do not turn it off.

## The four identities

One service account per Postgres role in your `roles.sql`, so a leaked credential is not all four:

| Service account (dev; swap `dc-dev` for `dc-stg`) | Your Postgres role | Holds |
|---|---|---|
| `dc-dev-api@inktree-dailycare-dev.iam.gserviceaccount.com` | `dailycare_app` | Cloud SQL client + IAM auth, logging, trace, metrics |
| `dc-dev-retention@…` | `dailycare_retention` | Cloud SQL client + IAM auth, logging |
| `dc-dev-integration@…` | `dailycare_integration` | Cloud SQL client + IAM auth, logging |
| `dc-dev-backup@…` | `dailycare_backup` | Cloud SQL client + IAM auth, logging |

The api account also holds `iam.serviceAccountTokenCreator` **on itself**, which is what lets it sign photo URLs through the IAM signBlob API without ever holding a key. That is the mechanism behind the `platform_managed` row for `media_signing_key` in your secrets inventory.

**`cloudsql.instanceUser` is inert until you do two things:** set the `cloudsql.iam_authentication=on` flag on the instance, and create a `CLOUD_IAM_SERVICE_ACCOUNT` database user for each account. Until then the grants exist and do nothing.

## Secrets

Four shells exist in both dev and staging, empty. The IDs match your `secrets_inventory` exactly, so the register and the store agree:

| Secret | Readable by |
|---|---|
| `db_password` | api |
| `jwt_signing_key` | api |
| `twilio_token` | api |
| `pointclickcare_client` | **integration only** |

The split is deliberate and is the one from your own note: a compromised API session cannot reach the clinical-feed credentials, which is what stops it writing a medication event attributed to PointClickCare.

Add values yourself in dev (`secretmanager.admin`):

```bash
gcloud secrets versions add db_password --data-file=- --project=inktree-dailycare-dev <<< 'the-value'
```

In staging you have read access only; tell us what needs setting. Terraform never holds secret values, in either direction — same rule as the Inktree platform.

## The photo bucket — your call, and one trap

**No buckets exist yet.** Creating them is yours, in dev.

The control you flagged in your own review — API can create and read, only retention deletes — is **not yet in place**, because there is nothing to bind it to. The identities that make it enforceable exist; the object-level roles must go on at the moment you create the bucket:

```bash
# API: create + read, never delete
gcloud storage buckets add-iam-policy-binding gs://BUCKET \
  --member=serviceAccount:dc-dev-api@inktree-dailycare-dev.iam.gserviceaccount.com \
  --role=roles/storage.objectCreator
gcloud storage buckets add-iam-policy-binding gs://BUCKET \
  --member=serviceAccount:dc-dev-api@inktree-dailycare-dev.iam.gserviceaccount.com \
  --role=roles/storage.objectViewer

# Retention: the only identity that may delete
gcloud storage buckets add-iam-policy-binding gs://BUCKET \
  --member=serviceAccount:dc-dev-retention@inktree-dailycare-dev.iam.gserviceaccount.com \
  --role=roles/storage.objectAdmin
```

You have since verified this against the role reference and written it up better than we did — `objectCreator` forbids overwrite as well as delete, which is the property you want for a photograph attached to a care record. The trap, restated because it is the one that bites: **`objectAdmin` on the api account would silently reopen the hole you closed.** It includes `objects.delete`, and GCS also requires `objects.delete` to *overwrite* an existing object. So if you ever find yourself needing the API to overwrite a photo, that is the same permission as deleting one, and it belongs in the retention handshake instead.

## CI

Keyless, via Workload Identity Federation — a direct consequence of the no-keys policy. Your workflow authenticates with no stored credential at all.

| | dev | staging |
|---|---|---|
| Provider | `projects/144065101336/locations/global/workloadIdentityPools/dc-dev-github-pool/providers/github-provider` | `projects/1020149956206/locations/global/workloadIdentityPools/dc-stg-github-pool/providers/github-provider` |
| Service account | `dc-dev-github-actions@inktree-dailycare-dev.iam.gserviceaccount.com` | `dc-stg-github-actions@inktree-dailycare-staging.iam.gserviceaccount.com` |
| Registry | `us-central1-docker.pkg.dev/inktree-dailycare-dev/dc-dev-docker` | `us-central1-docker.pkg.dev/inktree-dailycare-staging/dc-stg-docker` |

Trust is pinned to `assertion.repository_owner == 'dailycare-hq'`, so any repo in that org works — no IAM change if you split the backend out of `dailycare-mobile`.

```yaml
permissions:
  contents: read
  id-token: write   # required, easy to forget

steps:
  - uses: google-github-actions/auth@v3
    with:
      workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
      service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}
```

The CI identity holds `run.developer` and `artifactregistry.writer` and **nothing else** — no secrets, no database. It pushes images and rolls revisions; anything else should come from Terraform. This is deliberately tighter than the Inktree platform's CI account.

## Terraform

The three projects are managed in Terraform in the Inktree monorepo — `terraform/modules/dailycare-project` plus a root per environment. That covers the project-level scaffolding: policies, audit config, identities, secret shells, WIF, registry, budgets.

**Your application infrastructure — Cloud SQL, Cloud Run, buckets, VPC — is yours**, and it is fine for it to live in the DailyCare repo. State buckets are ready:

| Environment | Bucket |
|---|---|
| dev | `gs://inktree-dailycare-dev-terraform-state` |
| staging | `gs://inktree-dailycare-staging-terraform-state` |

Use a distinct `prefix` from `dev/terraform.tfstate` or `staging/terraform.tfstate`, which we already occupy. Two requests: keep the two layers in separate state files, and read the identities you need as data sources rather than recreating them — if both layers try to own the same service account you get a fight nobody wins.

One auth quirk: this project does **not** use ADC. Before any terraform command:

```bash
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)
```

Budgets are set — dev USD 150/month, staging USD 300/month, alerting at 50/90/100% to us. Both are several times the expected spend, so an alert means something is wrong, not that you are working hard. Worth knowing the VPC connector bills ~USD 10/month flat with no idle discount, so if dev sits unused for a stretch it is the thing worth tearing down.

## The one rule

**No real resident, caregiver, or family data in dev or staging. Ever.** Not for one bug, not for ten minutes. Production is the only place it may exist, and not until the M6 readiness gate and signed agreements. Your `environments.sql` already enforces the scrub-before-connect mechanism; this is the same rule at the infrastructure layer.

If you hit a bug that only reproduces on real data, that is a conversation, not a copy.

## Your `gcp-iam.sql`, reconciled

We have read it, plus `iam-invariants.sql` and today's `objectCreator` note. The separation you designed is the separation that is built. Four differences, none of them a disagreement about intent.

**Names.** Everything in your file exists — under different names, because the projects were provisioned before we saw yours.

| Yours | Built |
|---|---|
| `dailycare-api` | `dc-dev-api` / `dc-stg-api` |
| `dailycare-retention` | `dc-dev-retention` / `dc-stg-retention` |
| `dailycare-integration` | `dc-dev-integration` / `dc-stg-integration` |
| `dailycare-backup` | `dc-dev-backup` / `dc-stg-backup` |
| `github-deploy` | `dc-dev-github-actions` / `dc-stg-github-actions` |
| `dailycare-db-password` | `db_password` |
| `dailycare-jwt-key` | `jwt_signing_key` |
| `dailycare-twilio` | `twilio_token` |
| `dailycare-pointclickcare` | `pointclickcare_client` |
| `dailycare` (registry) | `dc-dev-docker` / `dc-stg-docker` |
| `dailycare-media`, `dailycare-backup` (buckets) | do not exist yet — yours to create |

So **`cmds.txt` will not run as-is against these projects.** The principals and secrets are already there under the names on the right, and the two buckets do not exist. Say which naming you want and we will converge on it; ours has nothing depending on it yet.

**Dev's breadth** — kept, as you said. The three you named are gone: `viewer`, `serviceAccountAdmin`, and project-level `tokenCreator`. Staging now matches.

**Your checker, now that it reads a real policy.** You counted 46 bindings and 9 service agents; the live policy has 47 and 10. The one your classifier misses is `144065101336@cloudservices.gserviceaccount.com`, which holds `roles/editor`. It is Google's own API service agent, present on every project, and its name has no `service-` prefix — every other agent's does, which is almost certainly the pattern. It is benign, but your "nothing broad" assertion covers `roles/editor`, and right now it passes while that binding exists. Worth classifying explicitly as an expected agent rather than letting it fall through.

**Your register will show drift after this change.** Three bindings you documented on 22 September are gone (`viewer`, `serviceAccountAdmin`, project `tokenCreator`), and there are new ones: the custom role in both projects, `serviceAccountUser` + `serviceAccountTokenCreator` on each of the four accounts in both projects, and staging's eleven new project roles. All of it is in this document; that drift is ours, not something to chase.

**`github-deploy` actAs** covers all four service accounts, matching your file. CI still holds no secret and no database role — `run.developer` and `artifactregistry.writer`, nothing else.

**`cloudsql.instanceUser`** on the four service accounts is live: you set `cloudsql.iam_authentication=on` and created the four `CLOUD_IAM_SERVICE_ACCOUNT` users on `dc-dev-pg`, so it is the connection path now rather than a dormant grant.

**Your `CREATE ROLE` question** is Trevor's and he has it. Worth noting that `migrate.sh --with-roles` already handles the version where you get an elevated login for one run: it prints the `gcloud sql users set-password` rotation as the next step. In dev you hold `cloudsql.admin`, so you can run that rotation yourself; in staging we would run it. That makes the looser option meaningfully less loose than it first reads.

One thing your invariants already say better than we did: a person holding `objectAdmin` on the media bucket can remove evidence, which is fine over test images and not fine over a resident's. You marked it temporary and flagged it yourself. Worth carrying that into how the bucket gets built.

## What we need back

Nothing blocking. Two things when convenient:

1. Update `gcp_iam` for the change above so your drift check is clean again — the removals, the custom role, the per-account impersonation, and staging's wider set.
2. Push your application Terraform. We can see from the audit log that it runs (1.9.8, provider 6.50.0, state under `application/dev`, our accounts as data sources — all as we asked), but we cannot read it, and two Terraform states over one project is worth being able to review from both sides.

## Quick check

```bash
gcloud auth login                                          # jenith.dev1202@gmail.com
gcloud projects describe inktree-dailycare-dev             # works
gcloud iam service-accounts list --project=inktree-dailycare-dev   # 4 + CI
gcloud secrets list --project=inktree-dailycare-dev        # 4 shells, no versions
gcloud run services list --project=inktree-dailycare-prod  # must FAIL: no access, by design

# and the guardrail, which should be refused:
gcloud iam service-accounts keys create /tmp/k.json \
  --iam-account=dc-dev-api@inktree-dailycare-dev.iam.gserviceaccount.com
# expect: FAILED_PRECONDITION: Key creation is not allowed on this service account
```

Anything that does not behave as described above is our bug — tell us and we will fix it rather than have you work around it.
