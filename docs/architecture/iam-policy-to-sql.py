#!/usr/bin/env python3
"""Turn a GCP project policy into rows for gcp_iam_observed.

Reads the JSON on stdin, writes SQL on stdout. Called by load-iam-policy.sh; kept as its
own file because the same thing written inline in a shell heredoc needs three levels of
quoting, and the first version of it had a bug that only showed up as an empty file.
"""
import json
import re
import sys
from datetime import datetime, timezone


def sql(s):
    return "'" + s.replace("'", "''") + "'"


def is_agent(member, role):
    """A service account Google created when an API was enabled.

    Nobody granted these and nobody can meaningfully remove them. They are recorded and
    marked rather than dropped - a reviewer should see the whole policy - but drift does
    not report them, because thirty of them would bury the two lines that matter.
    """
    return bool(
        role.endswith("ServiceAgent")
        or role.endswith(".serviceAgent")
        or re.match(r"^serviceAccount:service-\d+@", member)
        or re.match(r"^serviceAccount:\d+@cloudservices\.", member)
    )


def principal_of(member):
    if member.startswith("serviceAccount:"):
        return member[len("serviceAccount:"):].split("@")[0]
    if member.startswith("user:"):
        return member[len("user:"):]
    return member


def main():
    project, environment = sys.argv[1], sys.argv[2]
    policy = json.load(sys.stdin)

    rows = []
    for binding in policy.get("bindings", []):
        role = binding["role"]
        conditional = bool(binding.get("condition"))
        for member in binding.get("members", []):
            rows.append((principal_of(member), role, conditional, is_agent(member, role)))

    if not rows:
        sys.stderr.write("the policy had no bindings, which is not a thing a real project does\n")
        return 1

    agents = sum(1 for r in rows if r[3])
    when = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = sys.stdout.write

    out("-- Read from %s at %s.\n" % (project, when))
    out("-- %d bindings, %d of them Google's own service agents.\n" % (len(rows), agents))
    out("BEGIN;\n")
    for table in ("gcp_iam_observed", "gcp_iam_observations"):
        out("DELETE FROM %s WHERE environment = %s AND scope_kind = 'project';\n"
            % (table, sql(environment)))
    out("INSERT INTO gcp_iam_observations (environment, scope_kind, source) VALUES (%s, 'project', %s);\n"
        % (sql(environment), sql("gcloud projects get-iam-policy " + project)))
    out("INSERT INTO gcp_iam_observed\n"
        "  (environment, principal, role, scope_kind, has_condition, google_managed)\nVALUES\n")
    out(",\n".join(
        "  (%s, %s, %s, 'project', %s, %s)"
        % (sql(environment), sql(p), sql(r), str(c).lower(), str(a).lower())
        for p, r, c, a in rows) + ";\n")
    out("COMMIT;\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
