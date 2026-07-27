{{/*
The pod selector shared by default-deny.yaml (which denies everything for the
pods it selects) and allow-dns.yaml (which imposes an egress whitelist on the
pods IT selects — any pod matched by any Egress-type policy gets
whitelist-only egress, so a broader selector there than here would silently
restrict the excluded releases to DNS-only egress even though default-deny
skips them). Keep the two in lockstep by always using this helper.

Selects every pod in the namespace EXCEPT the three vendored third-party
stacks that deploy into it via their own Flux HelmReleases — the observability
stack, MinIO, and Authentik (see default-deny.yaml's doc comment for the full
reasoning). None of their internal flows are enumerated in .Values.edges, and
NetworkPolicy IS enforced on k3s via its embedded kube-router controller, so
selecting them would strangle their own internal traffic for real — which is
exactly how PR #224 broke twice in CI (CNPG plumbing, then Authentik's
server<->bundled-Postgres<->worker).

A NotIn matchExpression also matches pods that lack the label entirely, so
everything else — this umbrella's own Go services, pwa, powersync, and the
CNPG Postgres cluster — stays selected and default-denied.

Authentik's server, worker AND its bundled `authentik-postgresql-0` all share
`app.kubernetes.io/instance: authentik` (their `app.kubernetes.io/name`
differs — authentik vs postgresql — so selecting on `instance` catches the
whole stack in one predicate; selecting on `name` would miss the bundled
Postgres, verified live). It piggybacks on the observability entry since both
use the `instance` key.
*/}}
{{- define "networkpolicy.managedPodSelector" -}}
matchExpressions:
  - { key: app.kubernetes.io/instance, operator: NotIn, values: [observability, authentik] }
  - { key: app.kubernetes.io/managed-by, operator: NotIn, values: [prometheus-operator] }
  - { key: release, operator: NotIn, values: [minio] }
{{- end -}}
