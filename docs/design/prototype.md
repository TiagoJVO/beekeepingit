# Melargil — UI/UX prototype (design guideline)

> **Status: guideline, not spec.** This is the product's interactive prototype — **“Melargil · Mel de
> Montargil, Portugal”** — exported from Claude Design on **2026-07-11**. It is the **directional source of
> truth for UI look-and-feel and workflow**, not a pixel-spec and not a scope authority. Intent lives in
> [`requirements/`](../../requirements/) (`FR-*`/`NFR-*`/`D-*`); this documents how that intent should *look and
> flow*. Where the two diverge, `requirements/` wins. It maps onto the existing **M0–M11** backlog (`D-14`) — it
> does not introduce a parallel one.

- **Live / interactive:** <https://claude.ai/design/p/8964a735-c278-4529-a489-3eb7154ea4a7?file=Melargil+App.dc.html>
- **In-repo copy:** [`melargil-prototype/`](melargil-prototype/) — open `melargil-app.dc.html` (with `support.js`
  alongside) in a browser to view the 17 screens interactively.

## Files

| Path | What |
| --- | --- |
| `melargil-prototype/melargil-app.dc.html` | The Claude Design canvas — 17 screens as reactive `<sc-if>` states. |
| `melargil-prototype/support.js` | Claude Design runtime (required to render the canvas). |
| `melargil-prototype/uploads/` | Logo + screen images referenced by the canvas. |

## Design tokens

### Colour
| Token | Hex | Use |
| --- | --- | --- |
| Plum 950 | `#221D31` | app frame / darkest ground |
| Plum 700 | `#4A3F63` | headers, hero cards, primary surfaces |
| Plum 800 / 600 | `#3D3454` / `#574B73` | bottom-nav / hover |
| Honey | `#F0A81F` (hover `#F7B637`) | **the** primary action + highlights (one accent) |
| Gold | `#B0862B` | section eyebrows, hive/amber labels |
| Cream / Sand | `#F6F3EC` / `#F4EDDB` | app background / tinted tiles |
| Paper | `#FFFFFF` | cards, inputs |
| Ink / Muted / Stone | `#2B2438` / `#6E6680` / `#8B8270` | text, secondary, tertiary |
| Hairline / Line | `#E7E1D3` / `#D8D1C0` | card borders / input borders |
| Info | `#2A6FDB` | “you are here” map dot |
| Danger | `#B3423A` | logout, revoke, destructive |

### Type
- **Playfair Display** (600–700) — display / screen titles / brand.
- **Archivo** (400/500/600/700) — all UI, labels, inputs, buttons, body.
- **Material Symbols Outlined** — icons. **ui-monospace** — map coordinates / mono labels.

### Components & rules
- Controls are **52–60px tall** (inputs, primary buttons) — deliberately oversized for **gloved hands in the field**.
- Radii **12–20px**; cards = white on a 1px `#E7E1D3` hairline; chips = 40–44px pills.
- **Honey is the only primary action.** Secondary = outlined plum. Destructive = outlined danger.
- Persistent chrome: **offline banner** (with pending-change count), **sync-status pill** in the header, **toast**
  confirmations on save/sync, a contextual **honey FAB**.

## Screen inventory (17)

- **Auth / onboarding:** Login (OIDC) · Criar conta · Perfil (passo 1) · Organização (passo 2) · Criar organização · Juntar-se por convite
- **Apiários:** Lista (pesquisa, ordem por proximidade, toggle mapa) · Mapa (marcadores + “Você” + medir distância) · Detalhe · Form
- **Atividades:** Lista (chips de tipo + período) · Form (tipos **Cresta / Alimentação / Tratamento**, campos por tipo)
- **Jornadas:** Lista (progresso) · Detalhe (stats) · Form (planeamento)
- **Tarefas:** Lista (concluir/reabrir, prioridade, prazo) · Form
- **Assistente:** chat com selector de contexto, aviso offline, **ação proposta → Confirmar/Rejeitar**
- **Conta / Org:** Conta · Org editar · Membros & convites · Definições / Sync

## Navigation & workflow

- **Bottom nav (5 tabs):** Apiários · Atividades · Jornadas · Tarefas · Assistente.
- **Header:** contextual back · brand + screen title (Playfair) · **sync-status pill** (colour + label → opens
  Definições/Sync) · account.
- **FAB:** honey pill with a contextual label (“Novo apiário”, “Nova atividade”…) — quick-add for the active tab.
- **Onboarding gate:** Login → Criar conta → Perfil → Organização (criar / juntar por convite) → app.
- **Key flows:** apiary list ⇄ map, tap-to-measure distance; activity = apiary → type → type-specific fields;
  journey = name + main activity + choose apiaries → progress → stats; assistant = context → ask → propose → confirm.

## Feature → backlog map

| Prototype area | Milestone · epic | Issues |
| --- | --- | --- |
| Auth / onboarding / org / invite | M1 Identity & Onboarding | FR-ONB-1/2/3, #25–#27 (done) |
| Apiários lista / pesquisa / proximidade / toggle | M2 Apiaries | #31 #33 #35 #36 |
| Mapa: marcadores, user-loc, medir | M2 Apiaries | #34 #37 |
| Apiário detalhe / form (+ notas) | M2 Apiaries | #31 #32 · **notes = net-new** |
| Atividades lista + form (por tipo) | M3 Activities | #38–#43 |
| Jornadas lista / detalhe / form | M4 Journeys | #45–#49 |
| Tarefas lista / form | M5 Todos | #50–#53 |
| Assistente (contexto, offline, propose→confirm) | M8 AI Assistant | #63–#68 #114 |
| Conta / Org / Membros | M1 / M7 | #73–#75 |
| Exportar CSV | M6 Import/Export | #69 |
| Definições / Sync · offline banner · sync pill | stream EPIC-06 · M9 | #58 #81 |
| Notificações | M9 Settings & Notif. | #82 |
| Histórico note | stream EPIC-07 (FR-HIS) | #59–#62 |
| PT/EN | stream EPIC-11 | #77 |
| App shell (bottom-nav, FAB, header) | shell · M2 | #21 · **nav IA = net-new** |

## What the prototype answers (open `Q-*`)

The prototype gives each open scope question a strong, ready-to-confirm answer. **These are NOT yet retired** —
they are settled in the deferred scope pass (per the `requirements-folder` skill: answer → `D-*`/`FR-*`, then
remove the `Q-*`).

| Q | Prototype answer | Still open |
| --- | --- | --- |
| `Q-DIST` | Tap two pins → **straight-line** distance; km in list. (Matches the recommended default.) | driving distance online |
| `Q-SEARCH` | Search apiaries by name/location (client-side). | extend to activities/todos? |
| `Q-MAP` | Pin markers (hive count) + user location + measurement overlay. | tile provider & offline tiles |
| `Q-JOUR` | Plan = chosen apiaries + main activity; progress = feitos/planeados; stats = colmeias, mel kg, média alças/colmeia. | auto-match vs manual link |
| `Q-TODO` | Complete/reopen, apiary-or-org association, priority (3), due date, sort/filter. | assignment to a user |
| `Q-NOTIF` | Per-event toggle list in Settings. | which events · in-app vs push |

## Decisions it exercises

`D-2` (hive count as an activity attribute — cresta captures colmeias crestadas / alças / mel kg) ·
`D-7` (change password “no fornecedor” — at the IdP) · `D-8` (assistant online-only, “precisa de ligação”) ·
`D-11` / `NFR-AI-4` (assistant **proposes** a write action → user **Confirmar/Rejeitar**) ·
`FR-HIS` (Definições note: every create/edit/delete recorded with author + date for audit) · `FR-IE-1` (Exportar CSV).

## Net-new & refinements this import surfaced

- **Net-new stories:** apiary **notes** (M2, proposed `FR-AP-8`); **app-shell IA** (M2, proposed `FR-UX-1`).
- **Spec refinements** to existing issues (body notes, not new issues): exact per-type activity attributes on `#38`;
  the *média alças/colmeia* metric on `#49`; auto-sync-on-3G on `#58`/`#81`; notification toggles on `#82`;
  suggested prompts + context scope on `#65`.
