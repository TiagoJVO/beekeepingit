{{/*
The pod selector shared by default-deny.yaml (which denies everything for the
pods it selects) and allow-dns.yaml (which imposes an egress whitelist on the
pods IT selects — any pod matched by any Egress-type policy gets
whitelist-only egress, so a broader selector there than here would silently
restrict the excluded releases to DNS-only egress even though default-deny
skips them). Keep the two in lockstep by always using this helper.

Selects every pod in the namespace EXCEPT the observability stack's and
MinIO's (see default-deny.yaml's doc comment for the full reasoning — their
internal flows aren't enumerated in .Values.edges yet, and NetworkPolicy IS
enforced on k3s via its embedded kube-router controller, so selecting them
would break them for real). A NotIn matchExpression also matches pods that
lack the label entirely, so everything else — this umbrella's workloads,
Authentik's server/worker/Postgres — stays selected.
*/}}
{{- define "networkpolicy.managedPodSelector" -}}
matchExpressions:
  - { key: app.kubernetes.io/instance, operator: NotIn, values: [observability] }
  - { key: app.kubernetes.io/managed-by, operator: NotIn, values: [prometheus-operator] }
  - { key: release, operator: NotIn, values: [minio] }
{{- end -}}
