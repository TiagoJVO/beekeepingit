{{/*
Common labels every subchart's resources should carry, alongside their own
app.kubernetes.io/name. Helm loads parent + subchart templates into one shared
namespace, so subcharts can `include "beekeepingit.labels" .` directly.

Include this on the POD TEMPLATE of every Deployment too, not only on the
Deployment's own metadata (#246). `app.kubernetes.io/part-of=beekeepingit` is
the umbrella's one "everything this release owns" selector, and its two
consumers read different object kinds:

  - `kubectl rollout restart deployment -l ...` / `kubectl wait deployment -l ...`
    (helm-e2e.yml's backoff reset and readiness gate) select DEPLOYMENTS — for
    those the Deployment's own metadata labels are enough;
  - `kubectl logs -l ...` (helm-e2e.yml's on-failure diagnostics) selects PODS.

While the label lived only on the Deployments, that logs line matched no
running pod at all and silently dumped nothing — the reason the PowerSync
download-stream flake of run 29251456225 had no server-side evidence at all
(#246; the explicit per-deployment dumps #242 added were the stopgap). Pods
inherit only what the pod template carries, so the helper has to be on both.

The helper emits app.kubernetes.io/instance, so a pod template that includes it
must NOT also set that key explicitly (duplicate YAML mapping keys). Both
selector labels (name + instance) are still present either way, so a
Deployment's immutable spec.selector keeps matching.
*/}}
{{- define "beekeepingit.labels" -}}
app.kubernetes.io/part-of: beekeepingit
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
