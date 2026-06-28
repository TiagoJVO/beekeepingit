# EPIC-15 — Platform Rollout: PWA → Android → iOS

- **Milestone:** M0 / M4 / M5 (per story)
- **Phase:** PWA → Android → iOS/native
- **Labels:** type/epic, area/infra
- **Requirements:** FR-PL-1, NFR-AI-2, NFR-AI-3
- **Depends on:** EPIC-13, EPIC-06, EPIC-08
- **Spikes:** SP-2 (on-device LLM feasibility; included as a story below)
- **Summary:** Roll the single Flutter codebase out across surfaces in the order set by D-10 — installable PWA first (M0/ongoing), Android via direct APK (M4), then iOS native with the Apple Developer Program, macOS CI, and TestFlight/App Store (M5). The native phase also unlocks on-device AI with a local/cloud toggle and native offline login + background sync (M5).

## Stories

### Feature PWA hosting + installability (manifest, service worker)
- **Labels:** type/feature, area/infra, priority/high
- **Requirements:** FR-PL-1
- **Milestone:** M0
- **Depends on:** EPIC-13
- **Acceptance criteria:**
  - [ ] The Flutter Web build is **hosted** and reachable through the gateway/ingress over TLS.
  - [ ] A valid **web app manifest** (name, icons, theme, display) enables "add to home screen" on Android/desktop.
  - [ ] A **service worker** caches the app shell so the app loads when offline (app-shell, not data — data offline is owned by EPIC-06).
  - [ ] The PWA passes an installability audit (e.g. Lighthouse PWA checks) on a supported browser.
  - [ ] Larger devices (laptops/desktops) run the app **without requiring offline** support, per FR-PL-1.
- **Notes:** PWA-first per D-10; M0/ongoing. iOS PWA storage durability is a known weak spot (D-10) but validated under SP-1/EPIC-06; iOS is addressed natively later in this epic anyway.

### Feature Android build + direct APK distribution (+ optional Play)
- **Labels:** type/feature, area/infra, priority/medium
- **Requirements:** FR-PL-1
- **Milestone:** M4
- **Depends on:** EPIC-15/PWA hosting + installability (manifest, service worker)
- **Acceptance criteria:**
  - [ ] The Flutter codebase produces a signed **Android APK** (no rewrite — same codebase as the PWA).
  - [ ] The APK installs and runs on Android **phones and tablets** (FR-PL-1).
  - [ ] **Direct APK distribution** is documented (download/sideload flow) as the primary channel; Play Store ($25 once) is noted as optional.
  - [ ] App signing keys/secrets are managed securely (ties to EPIC-14 secrets handling) and the build is reproducible from CI.
  - [ ] Android-specific polish (permissions prompts, icons, splash) is verified on device.
- **Notes:** Android before iOS per D-10/ordering rationale (direct APK is free, ideal for a single org). Build is wired into the existing GitHub Actions pipeline (EPIC-13); no macOS runner needed here.

### Feature iOS native build + Apple Developer + macOS CI + TestFlight/App Store
- **Labels:** type/feature, area/infra, priority/medium
- **Requirements:** FR-PL-1
- **Milestone:** M5
- **Depends on:** EPIC-15/Android build + direct APK distribution (+ optional Play)
- **Acceptance criteria:**
  - [ ] The Flutter codebase produces a signed **iOS build** that installs and runs on iPhone and iPad (FR-PL-1).
  - [ ] The **Apple Developer Program** account ($99/yr) is set up with the required certificates/provisioning profiles.
  - [ ] **macOS runners are added to CI** (GitHub Actions) to build/sign the iOS app — explicitly the M5 addition that EPIC-13 deferred.
  - [ ] The app is distributed via **TestFlight** for beta and prepared for **App Store** submission.
  - [ ] iOS-specific behavior (permissions, storage, background limits) is verified on device.
- **Notes:** iOS is last per D-10 because it bundles the costly/native-only work (Apple account, macOS CI). The macOS-runner addition is the deferred half of EPIC-13's CI/CD story.

### Spike SP-2 — On-device LLM feasibility + NL→query accuracy on a mid-range phone
- **Labels:** type/spike, area/ai, priority/medium
- **Requirements:** NFR-AI-2, NFR-AI-3
- **Milestone:** M5
- **Depends on:** EPIC-08
- **Acceptance criteria:**
  - [ ] Candidate on-device models are evaluated (e.g. Gemma 2 2B / Llama 3.2 3B / Phi-3.5-mini via MediaPipe/llama.cpp/flutter_gemma).
  - [ ] **NL→structured-query accuracy** is measured on the FR-AI example questions running the same pattern as the cloud path (EPIC-08).
  - [ ] Feasibility on a **mid-range phone** is assessed for model size, memory, latency, and battery.
  - [ ] A recommendation resolves the on-device **model + runtime** choice (Q-LLM) and a go/no-go for the on-device feature.
  - [ ] Findings are documented and feed the on-device AI story below.
- **Notes:** SP-2 is re-scoped to the native phase (D-8/D-10) and is **not** PWA-blocking. Resolves Q-LLM direction and the on-device model in D-8.

### Feature On-device AI + local/cloud toggle
- **Labels:** type/feature, area/ai, priority/medium
- **Requirements:** NFR-AI-2, NFR-AI-3
- **Milestone:** M5
- **Depends on:** EPIC-15/SP-2 — On-device LLM feasibility + NL→query accuracy on a mid-range phone, EPIC-08
- **Acceptance criteria:**
  - [ ] A **local LLM** runs the same NL→query pattern fully **on-device and offline**, with no external calls in local mode (NFR-AI-2).
  - [ ] A **toggle** lets the user choose **local or cloud** AI; the cloud path (EPIC-08) remains available (NFR-AI-3).
  - [ ] Context scoping (org/apiary/journey) and the read-only, parameterized guardrails hold identically in local mode (FR-AI-1).
  - [ ] Local mode requires **no consent for external processing** (data never leaves the device), and this difference from cloud mode is reflected in the UX.
  - [ ] The FR-AI example questions return correct results in local mode within the quality bar set by SP-2.
- **Notes:** On-device AI is a native-phase goal per D-8/D-10 (can't run in a PWA). Model/runtime choice comes from SP-2. Cloud-first ordering per D-8 (cloud ships in EPIC-08 at M3; local + toggle here at M5).

### Feature Native offline login + background sync
- **Labels:** type/feature, area/auth-identity, area/offline-sync, priority/medium
- **Requirements:** FR-PL-1, NFR-SEC-1
- **Milestone:** M5
- **Depends on:** EPIC-06, EPIC-01
- **Acceptance criteria:**
  - [ ] **Offline login** works on native via cached Keycloak access/refresh tokens + JWKS, validated locally within a grace window (D-7), requiring periodic online re-auth.
  - [ ] **Background sync** flushes queued offline changes when connectivity returns, using native background execution (beyond what the PWA web SDK allows).
  - [ ] Offline-cached credentials are stored securely on device (secure storage/keystore), aligning with EPIC-14 security.
  - [ ] Sync status and conflict handling (server-authoritative last-write-wins, Q-SYNC) behave consistently with the PWA-phase sync engine (EPIC-06).
  - [ ] The native offline-login + background-sync flow is covered by an automated test.
- **Notes:** Native-phase concern per D-10/tech-stack.md (offline login and deep background sync are native-only). Token/offline-auth detail tracked under Q-AUTH (EPIC-01); sync engine owned by EPIC-06.
