# GitOps image automation (Flux)

Closes the CI/CD loop for EPIC-13 [#88](https://github.com/TiagoJVO/beekeepingit/issues/88)
(AC #5): a merge builds and publishes a commit-tagged image
([`.github/workflows/build-publish.yml`](../../../.github/workflows/build-publish.yml)), then
**Flux image-automation** commits the new tag into Git and reconciles it onto the cluster — the
deploy is a **Git commit, never a manual `kubectl`/`helm`**.

```text
merge to main ─▶ build-publish.yml ─▶ ghcr.io/.../<svc>:<ts>-<sha>
                                            │  (ImageRepository polls, ImagePolicy picks newest)
                                            ▼
                 ImageUpdateAutomation rewrites the tag in apps/dev/ + commits ─▶ Flux reconciles
```

## Why this directory is not reconciled yet

These manifests sit **outside** the Flux Kustomization paths (`clusters/dev/`, `apps/dev/`), so
Flux does **not** apply them today. The walking-skeleton (#23) is the first set of services to
ship Dockerfiles and publish to ghcr.io, so the per-service tracking is now **real**
(`slice-service-images.yaml`), not only the illustrative `gateway` template — but it stays
**dormant** because the `ImageUpdateAutomation` still needs Git **write** credentials (tracked
under EPIC-14 [#89](https://github.com/TiagoJVO/beekeepingit/issues/89)) and these objects must be
moved into a reconciled path to activate (see "Activation"). Committing the wiring now (dormant)
keeps it version-controlled and ready — the same "green before code" approach as the rest of the
pipeline (D-9). See [FOLLOWUPS.md](../../../FOLLOWUPS.md) for the activation ledger.

## Files

| File                                                           | What it is                                                                                                                                                                                         |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`image-update-automation.yaml`](image-update-automation.yaml) | The **engine** — how/where Flux commits tag bumps (targets `apps/dev/`, `Setters` strategy).                                                                                                       |
| [`example-service-image.yaml`](example-service-image.yaml)     | **Template** `ImageRepository` + `ImagePolicy` for one service (`gateway` as the worked example).                                                                                                  |
| [`slice-service-images.yaml`](slice-service-images.yaml)       | **Real (dormant)** tracking for the #23 slice's 5 images (`services-{identity,organizations,apiaries,sync}` + `client`), with setter markers wired in `../apps/dev/beekeepingit-helmrelease.yaml`. |

## Activation (per the first service that ships an image)

1. **Install the two extra controllers** on the cluster (they are not part of a plain
   `flux install` — see [`../README.md`](../README.md) prerequisites):

   ```sh
   flux install --components-extra=image-reflector-controller,image-automation-controller
   ```

2. **Provision Git write credentials** for `ImageUpdateAutomation` to push tag-bump commits — a
   `flux-system` secret (deploy key with write access, or a PAT). This is a secrets-management
   task tracked under EPIC-14 [#89](https://github.com/TiagoJVO/beekeepingit/issues/89); once it
   exists, reference it via `spec.git.push.secretRef` (or the `GitRepository`'s `secretRef`).

3. **Wire the service:** copy [`example-service-image.yaml`](example-service-image.yaml), rename to
   the service, point `spec.image` at its published `ghcr.io` repo, and move both these objects
   under `apps/dev/` (or add this directory to a Kustomization) so Flux reconciles them.

4. **Add the setter marker** next to the image tag in that service's deploy manifest:

   ```yaml
   tag: 20260705120000-abc1234 # {"$imagepolicy": "flux-system:<service>:tag"}
   ```

After that, every merge that publishes a newer image is deployed automatically by Flux — no manual
cluster access. Roll back by `git revert`-ing the automation's tag-bump commit (or `git revert` on
`main`), exactly as with any other GitOps change.
