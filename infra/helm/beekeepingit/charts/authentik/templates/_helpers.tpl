{{/*
Shared secret-value resolution for the two Authentik Secrets this subchart owns.

The bundled-Postgres password must be IDENTICAL in both `beekeepingit-authentik-config`
(as `AUTHENTIK_POSTGRESQL__PASSWORD`, read by the server/worker) and
`beekeepingit-authentik-postgresql` (as `password`, read by the bundled Postgres). It
must also PERSIST across `helm upgrade` — regenerating it would lock Authentik out of
its own database.

Same `lookup` (preserve existing) + `randAlphaNum` (generate on first install) idiom as
the other subcharts' credential Secrets, but with one extra twist for the cross-Secret
consistency: because two templates that each called `randAlphaNum` independently would
diverge on a fresh install (no cluster state for `lookup` to find), the generated values
are computed ONCE here and MEMOIZED on the shared root context (`$.Values.__authentikGenerated`),
so whichever of the two Secret templates renders first wins and the other reads back the
exact same value. On `helm upgrade`, `lookup` finds the persisted Secret and reuses it, so
`randAlphaNum` is never reached. During `helm template`/`helm lint` (no live cluster)
`lookup` always returns nil, so a fresh value is generated every render — harmless, since
nothing is applied.
*/}}
{{- define "authentik.secrets" -}}
{{- if not (hasKey .Values "__authentikGenerated") -}}
  {{- $ns := .Values.global.namespace -}}
  {{- $config := lookup "v1" "Secret" $ns "beekeepingit-authentik-config" -}}
  {{- $pg := lookup "v1" "Secret" $ns "beekeepingit-authentik-postgresql" -}}
  {{- $secretKey := "" -}}
  {{- $bootstrapPassword := "" -}}
  {{- $bootstrapToken := "" -}}
  {{- $pgPassword := "" -}}
  {{- if $config -}}
    {{- $secretKey = index $config.data "AUTHENTIK_SECRET_KEY" | b64dec -}}
    {{- $bootstrapPassword = index $config.data "AUTHENTIK_BOOTSTRAP_PASSWORD" | b64dec -}}
    {{- $bootstrapToken = index $config.data "AUTHENTIK_BOOTSTRAP_TOKEN" | b64dec -}}
    {{- $pgPassword = index $config.data "AUTHENTIK_POSTGRESQL__PASSWORD" | b64dec -}}
  {{- else -}}
    {{- $secretKey = randAlphaNum 50 -}}
    {{- $bootstrapPassword = randAlphaNum 32 -}}
    {{- $bootstrapToken = randAlphaNum 60 -}}
    {{- /* Prefer an already-persisted Postgres password even if the config Secret is
           somehow missing, so a partial-recreate can't orphan the database. */ -}}
    {{- if $pg -}}
      {{- $pgPassword = index $pg.data "password" | b64dec -}}
    {{- else -}}
      {{- $pgPassword = randAlphaNum 32 -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set .Values "__authentikGenerated" (dict
        "secretKey" $secretKey
        "bootstrapPassword" $bootstrapPassword
        "bootstrapToken" $bootstrapToken
        "pgPassword" $pgPassword) -}}
{{- end -}}
{{- end -}}
