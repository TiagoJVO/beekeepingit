#!/usr/bin/env bash
# Verification aid for #87 (NFR-OBS-1): fires one correlated trace + log + metric
# through the OTel Collector and prints where to check the result in Grafana.
#
# This is a stand-in for a real service's telemetry — #23 (walking-skeleton
# services) hasn't landed yet, so nothing in the cluster emits OTel data on its own.
# Once #23 ships and its Go service is wired to the collector endpoint used here,
# re-run the same checks against its real traffic instead (see FOLLOWUPS.md) and
# this script can retire.
#
# Requires: kubectl pointed at the cluster where the beekeepingit release is
# installed, and the `beekeepingit-dev` namespace (adjust NAMESPACE below for
# other environments).
set -euo pipefail

NAMESPACE="${NAMESPACE:-beekeepingit-dev}"
TRACE_ID="$(printf '%032x' $((RANDOM * RANDOM)))"
LOCAL_GRPC_PORT=4317

echo "== Port-forwarding otel-collector:4317 from namespace ${NAMESPACE} =="
kubectl -n "${NAMESPACE}" port-forward svc/otel-collector "${LOCAL_GRPC_PORT}:4317" >/tmp/otel-pf.log 2>&1 &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
sleep 2

echo "== Sending a trace (trace_id=${TRACE_ID}) =="
docker run --rm --network host \
  otel/opentelemetry-collector-contrib:latest \
  telemetrygen traces --traces 1 --otlp-insecure \
  --otlp-endpoint "localhost:${LOCAL_GRPC_PORT}" \
  --telemetry-attributes "trace_id=\"${TRACE_ID}\""

echo "== Sending a correlated log line (references trace_id=${TRACE_ID}) =="
docker run --rm --network host \
  otel/opentelemetry-collector-contrib:latest \
  telemetrygen logs --logs 1 --otlp-insecure \
  --otlp-endpoint "localhost:${LOCAL_GRPC_PORT}" \
  --body "sample request handled trace_id=${TRACE_ID}"

echo "== Sending a metric point =="
docker run --rm --network host \
  otel/opentelemetry-collector-contrib:latest \
  telemetrygen metrics --metrics 1 --otlp-insecure \
  --otlp-endpoint "localhost:${LOCAL_GRPC_PORT}"

cat <<EOF

Done. In Grafana (kube-prometheus-stack-grafana service):
  - Explore > Tempo > search for trace ID ${TRACE_ID} -> should show the span.
  - Explore > Loki > {job=~".+"} |= "${TRACE_ID}" -> should show the log line,
    with a "TraceID" derived-field link back to the trace above (the
    trace<->log correlation AC).
  - Explore > Prometheus > otelcol_receiver_accepted_metric_points_total ->
    should have just incremented.
  - Dashboards > BeekeepingIT Platform Overview -> all three panels should show
    the blip from this run.
EOF
