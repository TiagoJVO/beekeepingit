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

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s' "${PASSWORD}" | clip.exe
  echo "(copied to the Windows clipboard via clip.exe — just paste)"
elif command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "${PASSWORD}" | pbcopy
  echo "(copied to the clipboard via pbcopy)"
elif command -v xclip >/dev/null 2>&1; then
  printf '%s' "${PASSWORD}" | xclip -selection clipboard
  echo "(copied to the clipboard via xclip)"
else
  echo "(no clipboard tool found — copy the password above manually)"
fi

echo "== Port-forwarding ${SERVICE_NAME}:80 -> localhost:${LOCAL_PORT} (namespace ${NAMESPACE}) =="
kubectl port-forward -n "${NAMESPACE}" "svc/${SERVICE_NAME}" "${LOCAL_PORT}:80" >/tmp/grafana-pf.log 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
sleep 2

echo "== Opening ${URL} =="
if command -v explorer.exe >/dev/null 2>&1; then
  # WSL2 -> Windows default browser. explorer.exe returns a nonzero exit code on
  # success too (a known WSL interop quirk), so don't let `set -e` treat it as failure.
  explorer.exe "${URL}" || true
elif command -v wslview >/dev/null 2>&1; then
  wslview "${URL}"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "${URL}"
elif command -v open >/dev/null 2>&1; then
  open "${URL}"
else
  echo "No way to auto-open a browser here — open manually: ${URL}"
fi

echo "Log in as 'admin' with the password above. Ctrl+C to stop the port-forward."
wait "${PF_PID}"
