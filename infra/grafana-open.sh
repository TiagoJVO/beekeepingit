#!/usr/bin/env bash
# Dev convenience: fetch Grafana's auto-generated admin password (#87 — never
# committed, chart-generated into a Secret), port-forward the service, and open it
# in a browser. See docs/architecture/platform.md#observability.
#
# Requires: kubectl pointed at the cluster where the beekeepingit release is
# installed. Adjust NAMESPACE/LOCAL_PORT via env vars for other environments.
set -euo pipefail

NAMESPACE="${NAMESPACE:-beekeepingit-dev}"
SERVICE_NAME="kube-prometheus-stack-grafana"
SECRET_NAME="kube-prometheus-stack-grafana"
LOCAL_PORT="${LOCAL_PORT:-3000}"
URL="http://localhost:${LOCAL_PORT}"

if ! kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "No Secret '${SECRET_NAME}' in namespace '${NAMESPACE}' —" \
    "is the beekeepingit release installed there? See infra/README.md." >&2
  exit 1
fi

PASSWORD="$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" \
  -o jsonpath="{.data.admin-password}" | base64 -d)"

echo "Grafana admin password: ${PASSWORD}"

# Best-effort only — never let a clipboard failure abort the port-forward below.
# (Verified live: clip.exe can be on PATH yet fail with "Exec format error" when
# WSL's Windows-interop isn't available in the current session.)
if printf '%s' "${PASSWORD}" | clip.exe 2>/dev/null; then
  echo "(copied to the Windows clipboard via clip.exe — just paste)"
elif printf '%s' "${PASSWORD}" | pbcopy 2>/dev/null; then
  echo "(copied to the clipboard via pbcopy)"
elif printf '%s' "${PASSWORD}" | xclip -selection clipboard 2>/dev/null; then
  echo "(copied to the clipboard via xclip)"
else
  echo "(couldn't reach a clipboard — copy the password above manually)"
fi

echo "== Port-forwarding ${SERVICE_NAME}:80 -> localhost:${LOCAL_PORT} (namespace ${NAMESPACE}) =="
kubectl port-forward -n "${NAMESPACE}" "svc/${SERVICE_NAME}" "${LOCAL_PORT}:80" >/tmp/grafana-pf.log 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
sleep 2

echo "== Opening ${URL} =="
# Best-effort, like the clipboard above. wslview (wslu) first — it reports
# failure honestly; explorer.exe opens the Windows default browser but returns
# nonzero even on success (known interop quirk), so it goes last and blind.
if wslview "${URL}" 2>/dev/null || xdg-open "${URL}" 2>/dev/null || open "${URL}" 2>/dev/null; then
  :
else
  explorer.exe "${URL}" >/dev/null 2>&1 || true
fi

echo "If no browser opened, open manually: ${URL}"
echo "Log in as 'admin' with the password above. Ctrl+C to stop the port-forward."
wait "${PF_PID}"
