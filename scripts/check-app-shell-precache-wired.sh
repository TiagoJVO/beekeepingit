#!/usr/bin/env bash
# Verify that every place which runs `flutter build web` also runs the app-shell
# precache generator afterwards (#619, FR-OF-1, FR-PL-1, D-10).
#
# WHY THIS CHECK EXISTS
# ---------------------
# `flutter build web` emits nothing content-hashed (#678), so the client's
# service worker (client/web/service_worker.js) gets its per-release cache key
# from a manifest that client/tool/build_app_shell_cache.dart injects into it
# AFTER the build. Skip that step and the worker ships with its placeholder
# manifest: it installs, caches nothing, handles no fetch, and the field app
# silently cannot start without a network connection — exactly the regression
# #619 fixed. Nothing else fails. `nginx -t` is green, the pod is Ready, the
# Lighthouse installability audit still passes, and only client/e2e's
# offline-boot spec would notice — and that spec does not run in
# release-deploy.yml, so a fifth build site could ship a dead offline shell to
# staging/prod with every gate green.
#
# The generator deliberately does NOT live in client/Dockerfile (that image
# "only COPYs the prebuilt artifact"), so the duplication across build sites is
# unavoidable — which is what this check is for, in the same idiom as
# check-deploy-url-drift.sh.
#
# Runs from `task repo:lint` (CI + local).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

readonly BUILD_CMD='flutter build web'
readonly GENERATOR='build_app_shell_cache.dart'
readonly GENERATOR_PATH='client/tool/build_app_shell_cache.dart'
# This file names both literals on non-comment lines, so it would always match
# itself — which would make the "guards nothing" failsafe below unfireable.
readonly SELF='scripts/check-app-shell-precache-wired.sh'

status=0
found_any=0

# The generator has to exist for any of the wiring below to mean anything, and
# taskfiles/dart.yml invokes it behind an `[ -f … ] ||` guard so a build would
# SILENTLY skip generation if it were ever deleted.
if ! git ls-files --error-unmatch "$GENERATOR_PATH" >/dev/null 2>&1; then
  echo "✗ [app-shell-precache] $GENERATOR_PATH is not tracked — nothing generates the"
  echo "  service worker's precache manifest, so the deployed app cannot start offline (#619)."
  exit 1
fi

# Only executable surfaces — workflows, composite actions, taskfiles, shell
# scripts and the client image. Documentation and agent definitions legitimately
# mention the build command in prose. `client/Dockerfile` is scanned on purpose:
# ADR-0026 records that the generator must NOT move in there, and this is what
# notices if it does anyway.
#
# Presence, not a count: these files mention the build command in `desc:`
# strings and progress `echo`s as well as in the invocation itself, and no
# regex tells those apart reliably enough to base a CI gate on. What this
# actually guards is the realistic failure — a NEW build site added without the
# generator at all — and for that, presence is exactly the right question.
while IFS= read -r file; do
  [ "$file" = "$SELF" ] && continue

  # Comment lines are excluded so a file may explain the build command in prose
  # without being asked to run the generator.
  #
  # The needle is matched FIRST and the comment filter second, deliberately: the
  # other order pipes the whole file into `grep -q`, which exits on its first
  # match and SIGPIPEs the upstream grep — and under `set -o pipefail` that is
  # exit 141, i.e. `|| continue` would SKIP a build site without a word. It only
  # works today because every scanned file is under the 64 KB pipe buffer, and
  # helm-e2e.yml grows with every issue.
  grep -F -- "$BUILD_CMD" "$file" | grep -qvE '^[[:space:]]*#' || continue
  found_any=1

  if ! grep -F -- "$GENERATOR" "$file" | grep -qvE '^[[:space:]]*#'; then
    echo "✗ [app-shell-precache] $file runs '$BUILD_CMD' but never invokes $GENERATOR."
    echo "  Without it the deployed service worker ships an empty precache manifest and"
    echo "  the app cannot start offline (#619). Add, right after the build:"
    echo "    dart run tool/build_app_shell_cache.dart build/web"
    status=1
  fi
done < <(git ls-files \
  '.github/workflows/*.yml' '.github/workflows/*.yaml' '.github/actions/*' \
  'Taskfile.yml' 'taskfiles/*.yml' 'scripts/*.sh' 'infra/*.sh' \
  'client/Dockerfile')

# A rename or a repo reshuffle that leaves this check matching nothing would make
# it silently useless — the same failure mode it exists to prevent.
if [ "$found_any" -eq 0 ]; then
  echo "✗ [app-shell-precache] no build site runs '$BUILD_CMD' — this check now guards nothing"
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "✓ [app-shell-precache] every 'flutter build web' site generates the precache manifest"
fi
exit "$status"
