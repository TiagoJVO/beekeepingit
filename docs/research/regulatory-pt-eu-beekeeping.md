# Portuguese/EU Beekeeping & Honey-Traceability Regulatory Research

- **Issue:** #91 · **Milestone:** M0 · **Date:** 2026-07-12
- **Resolves (proposed):** [Q-CMP / Q-REG](../../requirements/open-questions.md) → see the
  **Proposal** section below (not yet applied to `requirements/`)
- **Informs:** NFR-CMP-1, Context C-2, FR-HIS-1, FR-AC-1, FR-AP-1/7/8, FR-IE-1
- **Type:** Time-boxed research spike (`type/research`) — **no code, no `requirements/`
  edits**. Findings only; the Q-* resolution is a proposal for user confirmation.

> Research note — mirrors the `docs/spikes/` convention (see
> [`docs/spikes/sp-1-powersync-vs-electricsql.md`](../spikes/sp-1-powersync-vs-electricsql.md))
> but lives under `docs/research/` since this is regulatory research, not a technical
> engine/tool comparison.

## 1. Question

Per issue #91's acceptance criteria:

1. Confirm whether **HIPAA** applies; document rationale to drop it if not.
2. Enumerate concrete **Portuguese/EU beekeeping obligations** (apiary registration,
   treatment/medicine records, etc.).
3. Enumerate **honey/food traceability** obligations relevant to harvest records and exports.
4. Produce findings mapping each obligation to candidate FR/NFR follow-ups (no
   implementation).
5. Flag any obligation that would change the **data model** so it can be triaged before the
   relevant feature epic.

## 2. Finding A — HIPAA does not apply; drop it

**HIPAA** (Health Insurance Portability and Accountability Act) is US federal law governing
**protected health information (PHI)** of human patients handled by US "covered entities"
(healthcare providers, health plans, clearinghouses) and their business associates. It has
**no extraterritorial application to a Portuguese/EU beekeeping app** — BeekeepingIT is
neither a US covered entity nor processes US PHI.

Separately, even setting jurisdiction aside: bee/hive/apiary health data (treatment records,
disease notes) is **not "health data" of a natural person** under GDPR Art. 9(1) either. GDPR
Art. 9 special-category "data concerning health" is defined (Art. 4(15)) as data about the
**physical or mental health of a natural person** — it does not extend to animal or apiary
health. BeekeepingIT's treatment/disease records concern bees, not humans, so they are
**ordinary personal data at most** (insofar as a record is _attributed to the user who made
it_, per FR-HIS-1/FR-TEN-2), not GDPR special-category data.

- **Recommendation:** Remove **HIPAA** from NFR-CMP-1. Confirm **GDPR** applies (already
  affirmed in the current NFR-CMP-1 note) and clarify that treatment/health-of-bees records
  do **not** trigger GDPR Art. 9 special-category handling — ordinary GDPR lawfulness/
  minimization/erasure rules (already covered by NFR-AI-1, FR-HIS-1's erasure handling) apply.
- **Maps to:** NFR-CMP-1 (edit: drop HIPAA, add the Art. 9 clarification).

**Sources:**

- [GDPR Art. 9 — special categories, EUR-Lex consolidated text](https://eur-lex.europa.eu/eli/reg/2016/679/oj) (accessed 2026-07-12)
- Analysis confirming "health data" under Art. 9 is limited to natural persons, not animals (secondary sources cross-checked against Art. 4(15)/Art. 9(1) definitions, accessed 2026-07-12)

## 3. Finding B — Portuguese national beekeeping obligations (DGAV)

**Legal basis:** [Decreto-Lei n.º 203/2005, de 25 de novembro](https://dre.tretas.org/dre/191987/decreto-lei-203-2005-de-25-de-novembro)
(Diário da República n.º 227/2005, Série I-A) — the legal regime for beekeeping activity and
sanitary defense rules, repealing DL 37/2000 and DL 74/2000. Registration/declaration model
forms set by **Despacho n.º 4809/2016** (8 April). Administered by **DGAV** (Direção-Geral de
Alimentação e Veterinária), operationally via **SICOA** (Sistema Informático de Controlo
Oficial de Apiários) and the **IFAP** portal reserved area.

Source pages (accessed 2026-07-12):

- [DGAV — Identificação e registo da atividade apícola](https://www.dgav.pt/animais/conteudo/animais-de-producao/abelhas/identificacao-registo-e-movimentacao-animal/registo/)
- [DGAV — Abelhas (overview)](https://www.dgav.pt/animais/conteudo/animais-de-producao/abelhas/)
- [DGAV — Doenças das Abelhas](https://www.dgav.pt/animais/conteudo/animais-de-producao/abelhas/saude-animal/doencas-das-abelhas/)
- [DGAV — Apicultura Legislação (PDF index)](https://www.dgav.pt/wp-content/uploads/2021/03/Apicultura_Legislacao.pdf)

### B.1 — Registration (before starting activity)

Beekeepers must **register** before commencing beekeeping activity, via the "Atividade
Apícola" application (IFAP portal reserved area), regional veterinary services (DSAVR), or
authorized beekeeper organizations. A **beekeeper registration number** is issued and must be
**displayed visibly at each apiary**.

- **Maps to:** FR-ONB (profile/org onboarding) and FR-AP-1 (apiary CRUD) — candidate new
  field: beekeeper/apiary **registration number** (DGAV ID).
- **Data-model impact:** flagged (§6).

### B.2 — Mandatory apiary geolocation

Beekeepers must provide **approximate geographic coordinates** for every apiary.

- **Maps to:** FR-AP-1/FR-AP-3 (apiary already has a location for map view) — likely already
  satisfied by the existing lat/long field, but confirm precision/format expectations align
  with DGAV's SICOA submission format.
- **Data-model impact:** low — existing apiary location field likely suffices.

### B.3 — Annual declaration of stocks ("Declaração de Existências")

- **First declaration:** within **10 business days** of starting activity.
- **Annual declaration window:** **1–30 September** each year (re-affirmed for 2025 per
  [DGAV's 2025 notice](https://www.dgav.pt/destaques/noticias/declaracao-de-existencias-de-apiarios-2025/)).
- **Interim declaration:** any change in hive count **≥ 20% and ≥ 20 colonies** must be
  declared within **10 days** of occurring.

- **Maps to:** FR-AP-7 (hive count per apiary, per D-2) — the app already tracks a hive
  count; this obligation implies a **point-in-time declaration record**, not just a live
  count.
- **Data-model impact:** flagged (§6) — candidate new concept: an apiary **stock declaration**
  record (date, hive count, declared-to-DGAV flag) distinct from the live "current hive
  count" FR-AP-7 already has.

### B.4 — Movement / transhumance authorization

Movement of apiaries into **controlled zones** requires **prior authorization** from the
destination DSAVR (Model 488/DGV).

- **Maps to:** none currently — no journey/movement-authorization concept exists in FR-JO.
  This is a candidate **future** FR (transhumance permit tracking), **not required for
  M0-M2** since the app doesn't yet model regulatory movement permits.
- **Data-model impact:** deferred — flag only, no near-term change.

### B.5 — Hive installation density

DL 203/2005 Annex I sets a **table of hive installation density** (minimum distances/density
rules between apiaries). Not yet independently verified article-by-article (time-boxed
research; see §7 caveats), but exists and could interact with FR-AP-5 (distance measurement)
messaging in the future (e.g., a "density check" feature). **Not a near-term requirement.**

### B.6 — Mandatory-notification bee diseases (sanitary)

DL 203/2005 Annex II lists **diseases of compulsory notification (DDO)**. Per DGAV's current
list: **Acariose (Acarapisose)**, **infestation by _Tropilaelaps_ spp.**, **infestation by
_Aethina tumida_** (small hive beetle), **American foulbrood (loque americana)**, **European
foulbrood (loque europeia)**, **nosemosis**, and **varroosis**. American foulbrood is
endemic in Portugal; varroosis is the most prevalent disease in national colonies. DGAV
notifies the EU Commission/WOAH per these DDOs and runs an annual **Programa Sanitário
Apícola**.

- **Maps to:** FR-AC-1 "Treatment" activity type (already exists: date, treatment type,
  notes). This finding **affirms** the existing Treatment activity type is the right shape,
  and suggests the **treatment type** field should be able to record **disease being
  treated**, potentially matching this DDO list, since a compulsory-notification disease
  diagnosis is itself information the beekeeper may want/need to log (though **the app does
  not currently need to auto-report to DGAV** — out of scope; the app is a personal
  record-keeping tool, not a DGAV reporting integration).
- **Data-model impact:** flagged (§6) — candidate: optional structured "disease/condition"
  sub-field on the Treatment activity type, distinct from free-text notes.

Sources: [DGAV — Doenças das Abelhas](https://www.dgav.pt/animais/conteudo/animais-de-producao/abelhas/saude-animal/doencas-das-abelhas/), [DGAV — Doenças de Abelhas: Diagnóstico, Tratamento e Profilaxia (PDF)](https://www.dgav.pt/wp-content/uploads/2024/11/Doenca_Abelhas.pdf), [DGAV — Lista DDO (PDF)](https://dgav.webview.pt/wp-content/uploads/2023/04/ListaDDO.pdf) (all accessed 2026-07-12).

### B.7 — Veterinary medicinal product records (EU-wide, applies in PT)

**Regulation (EU) 2019/6** on veterinary medicinal products (applicable since 28 January 2022) requires that **records of medicinal product administration be kept up to date** and
retained for the **longer of**: 1 year after the batch's expiry date, or **5 years** from the
recording date. This applies to any veterinary treatment administered to bees (e.g. varroacide
treatments), whether by the beekeeper or a vet.

- **Maps to:** FR-AC-1 Treatment activity type — **affirms** the need to capture at minimum
  **date + treatment/product type + notes** (already specified), and suggests a **retention
  floor** consideration: treatment activity records should not be purgeable/deletable in a way
  that defeats a 5-year regulatory retention expectation. This interacts with FR-HIS-1
  (history) and any future data-retention/deletion feature.
- **Data-model impact:** flagged (§6) — retention-policy consideration, not a new field.

**Source:** [Regulation (EU) 2019/6, EUR-Lex](https://eur-lex.europa.eu/eli/reg/2019/6/oj) (accessed 2026-07-12).

## 4. Finding C — Honey / food traceability obligations (EU-wide, applies in PT)

### C.1 — General food-law traceability (Regulation (EC) 178/2002, Art. 18)

**Regulation (EC) No 178/2002** ("General Food Law") Art. 18 requires traceability of food
**at all stages of production, processing and distribution**. Every **food business
operator** — which, per Art. 3's definition of "primary production" (production, rearing,
growing, harvesting), **includes beekeepers/honey producers** — must:

1. Be able to **identify any supplier** of food/substances incorporated into food (Art. 18(2)).
2. Have systems to **identify the businesses to which products were supplied** (Art. 18(3)) —
   i.e., "one-step-back, one-step-forward" traceability.
3. Ensure food placed on the market is **adequately labelled/identified** to facilitate
   traceability (Art. 18(4)).

**Commission Implementing Regulation (EU) No 931/2011** sets the specific traceability
records for **food of animal origin** (honey included, per Regulation (EC) 852/2004 Art.
2(1) scope): the **minimum information** to record per batch/lot includes an **identifying
reference** for the lot/batch/consignment, description and quantity, dispatch date, and
supplier/customer names+addresses.

- **Maps to:** FR-AC-1 "Honey harvest" activity type (date, amount harvested, number of
  hives, notes) and FR-IE-1 (export). **Affirms** harvest activities are the right anchor for
  traceability data, but the **current fields don't capture a batch/lot identifier**, which is
  the crux of Art. 18/931-2011 traceability if honey is later sold/exported (one-step-back
  requires a lot reference tying finished product back to the harvest event(s)/apiary(ies) it
  came from).
- **Data-model impact:** flagged (§6) — candidate: an optional **lot/batch ID** field
  (generated or user-entered) on Honey harvest activities, or a lightweight "batch" grouping
  concept if/when a sales/export feature is built. **Not required for record-keeping-only
  use** (a beekeeper who doesn't sell wholesale/export has lighter practical exposure), but the
  app should not foreclose adding it.

**Sources:** [Regulation (EC) 178/2002, Art. 18, EUR-Lex](https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX%3A32002R0178) · [Commission Implementing Regulation (EU) No 931/2011, EUR-Lex](https://eur-lex.europa.eu/eli/reg_impl/2011/931/oj/eng) (accessed 2026-07-12).

### C.2 — Honey composition & labelling (Directive 2001/110/EC, as amended)

**Council Directive 2001/110/EC** ("Honey Directive") sets **composition criteria** (Annex
II) and **labelling rules** (Annex I product names, e.g. comb honey/chunk honey/baker's
honey) for honey placed on the market. Applicable in Portugal since 2004 (transposed).

- **Maps to:** none directly for record-keeping (composition standards are a
  production/food-safety concern, not something the app tracks), but **relevant context** for
  any future "sell/export honey" feature.

### C.3 — Origin labelling amendment (Directive (EU) 2024/1438) — now in force

**Directive (EU) 2024/1438** (adopted 14 May 2024, amending 2001/110/EC among others)
requires the **country/countries of origin where honey was harvested** to appear on the
label; for blends, countries must be listed in **descending order by weight share**, with the
**percentage each represents** (±5% tolerance, calculated from the operator's traceability
documentation). Transposition deadline was **14 December 2025**; the rules **apply from 14
June 2026** — i.e., **already in force** as of this research (2026-07-12). Note: Portugal
(with Slovenia) was a co-initiator of this amendment at the EU Agri-Fish Council in 2020.

- **Maps to:** FR-AC-1 Honey harvest, FR-AP-1 apiary location — **affirms** capturing
  **apiary location as the harvest origin** (already implicit — an apiary has a location and
  harvests are recorded against an apiary) is directly useful: if honey is later blended
  across apiaries/harvests for sale, the origin percentage math (Art. 2 of the amended
  Directive) needs the **weight-per-origin-source** data, which traces back to per-apiary
  (or per-country, trivial in PT-only scope) harvest amounts — something FR-AC-1 already
  records.
- **Data-model impact:** low for now (single-country PT scope per Context C-1 makes the
  percentage-of-country-of-origin math moot — 100% Portugal), but **worth flagging** if/when
  the app's honey-harvest/export data is used to generate label copy — the harvest amount +
  apiary-location linkage already satisfies the raw data need.

**Sources:** [Directive (EU) 2024/1438, EUR-Lex](https://eur-lex.europa.eu/eli/dir/2024/1438/oj) · [EUR-Lex summary — EU labelling rules for honey](https://eur-lex.europa.eu/EN/legal-content/summary/eu-labelling-rules-for-honey.html) (accessed 2026-07-12).

### C.4 — Lot marking (Directive 2011/91/EU)

**Directive 2011/91/EU** requires pre-packaged foodstuffs (including honey once packaged for
sale) to carry a **lot marking** (preceded by "L" unless a full best-before/use-by date is
shown) identifying the batch produced/packaged under practically the same conditions,
determined by the producer/packager.

- **Maps to:** same batch/lot concept as C.1 — reinforces the "lot ID" data-model flag rather
  than adding a new one.

**Source:** [Directive 2011/91/EU, EUR-Lex](https://eur-lex.europa.eu/eli/dir/2011/91/oj/eng) (accessed 2026-07-12).

### C.5 — Animal Health Law (Regulation (EU) 2016/429) — limited direct relevance

The EU **Animal Health Law** (applicable since 21 April 2021) is the umbrella EU regime for
transmissible animal diseases, disease listing, and establishment/traceability rules across
species. Bees are a listed species for certain notifiable diseases (aligning with the DDO
list in §B.6), but the **specific registration/movement mechanics for apiaries in Portugal**
are implemented at national level through DL 203/2005 / DGAV (§B), which pre-dates and
operates alongside AHL. No additional PT-specific obligation was found beyond what §B and
§C already capture; AHL is cited here as the EU-level legal basis underpinning the national
disease-notification regime, not as an independent new obligation.

**Source:** [Regulation (EU) 2016/429, EUR-Lex](https://eur-lex.europa.eu/eli/reg/2016/429/oj/eng) (accessed 2026-07-12).

## 5. Summary table — findings mapped to FR/NFR

| #   | Finding                                                                             | Affirms / changes                                                              | Data-model impact                                         |
| --- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------- |
| A   | HIPAA inapplicable; bee-health data ≠ GDPR Art. 9 special category                  | NFR-CMP-1 (edit: drop HIPAA)                                                   | None                                                      |
| B.1 | Beekeeper/apiary DGAV registration number                                           | FR-ONB, FR-AP-1 (new optional field)                                           | **Yes** — flagged                                         |
| B.2 | Apiary geo-coordinates mandatory                                                    | FR-AP-1/3 (affirms existing field)                                             | None (already covered)                                    |
| B.3 | Annual stock declaration (Sept 1–30) + 20%/20-colony interim declaration            | FR-AP-7 (new: declaration record, distinct from live count)                    | **Yes** — flagged                                         |
| B.4 | Transhumance movement authorization                                                 | No current FR; future-only                                                     | Deferred, no near-term change                             |
| B.5 | Hive density rules                                                                  | No current FR; informational                                                   | None near-term                                            |
| B.6 | Mandatory-notification bee diseases (DDO list)                                      | FR-AC-1 Treatment type (optional structured disease field)                     | **Yes** — flagged                                         |
| B.7 | Vet medicinal product record retention (5 yr / batch-expiry+1yr)                    | FR-AC-1 Treatment (affirms fields); retention-policy note vs. FR-HIS-1         | **Yes** — flagged (policy, not schema)                    |
| C.1 | Reg 178/2002 Art. 18 + Reg 931/2011 traceability (batch/lot, one-step-back/forward) | FR-AC-1 Honey harvest, FR-IE-1 (optional lot/batch ID)                         | **Yes** — flagged                                         |
| C.2 | Honey composition/labelling (2001/110/EC)                                           | Context only                                                                   | None                                                      |
| C.3 | Origin labelling %, in force from 2026-06-14 (Dir 2024/1438)                        | FR-AC-1/FR-AP-1 (affirms apiary-location-linked harvest data suffices for now) | Low — flag only if label-generation feature is ever built |
| C.4 | Lot marking (Dir 2011/91/EU)                                                        | Same as C.1                                                                    | Same as C.1                                               |
| C.5 | Animal Health Law (Reg 2016/429)                                                    | Legal-basis context for B.6                                                    | None additional                                           |

## 6. Data-model impact flags (for triage before the relevant feature epic)

These are **flags, not commitments** — to be triaged by the team before the apiary/activity
feature epics that would implement them:

1. **Apiary/beekeeper registration number** — optional field on apiary or organization
   profile (candidate: `FR-AP-1` extension or `FR-ONB-2` org profile field).
2. **Stock declaration record** — a point-in-time "declared to DGAV" snapshot (date + hive
   count), separate from the live hive-count on the apiary (FR-AP-7 / D-2). Could be a
   lightweight new activity type or a dedicated small entity.
3. **Structured disease/condition field on Treatment activities** — optional, alongside the
   existing free-text notes (FR-AC-1).
4. **Retention-policy note for Treatment records** — align any future data-retention/purge
   feature with the 5-year (or batch-expiry+1-year) floor from Reg 2019/6; interacts with
   FR-HIS-1's erasure handling (GDPR right-to-erasure vs. regulatory retention — the two need
   reconciling policy language, not just code).
5. **Optional lot/batch identifier on Honey harvest activities** — for future traceability/
   export/sale features (Reg 178/2002 Art. 18, Reg 931/2011, Dir 2011/91/EU). Not needed for
   personal record-keeping-only use.

None of these block current M0–M2 scope (walking skeleton, apiary CRUD/map, activities CRUD
as already planned) — they are **additive, optional fields/concepts** surfaced for future
epics (apiaries, activities/journeys, import-export). See §7 recommendation on **not**
retrofitting M0-M2 issues.

## 7. Caveats & scope limits (time-boxed research)

- This is a **time-boxed research spike**, not a legal opinion. Portuguese legislation
  (DL 203/2005 and its annexes) was read via secondary/summary sources and DGAV's own site,
  not the full consolidated Diário da República text article-by-article; §B.4/B.5 in
  particular would benefit from a full-text read if/when those features are actually planned.
- **DGAV/SICOA integration** (e.g., auto-submitting declarations) is explicitly **out of
  scope** for this research and is not recommended as a near-term feature — the app's role is
  personal/organizational record-keeping, not a government reporting channel, unless a future
  epic decides otherwise (would need its own Q-_/D-_).
- Directive (EU) 2024/1438's application date (2026-06-14) has **already passed** as of this
  research's date (2026-07-12) — treat origin-labelling percentage rules as **current law**,
  not upcoming.
- No **sale/export** feature currently exists in the backlog (FR-IE-1 is generic
  export/backup, not commercial sale) — traceability findings (C.1–C.4) are framed as
  **future-relevant**, not blocking.

## 8. Proposal — draft Q-CMP/Q-REG resolution (NOT APPLIED)

> The following is a **ready-to-apply draft** for `requirements/decisions.md` and
> `requirements/non-functional-requirements.md`, provided for **user confirmation** per the
> `requirements-folder` skill and `mandatory-workflow.md` rule. **This research PR does not
> edit `requirements/`.** Apply only after explicit user sign-off, in a follow-up change that
> also removes the Q-CMP/Q-REG entry from `open-questions.md`.

### Proposed new decision — `D-18 — PT/EU beekeeping & honey-traceability obligations scoped; HIPAA dropped`

```markdown
## D-18 — PT/EU beekeeping & honey-traceability obligations scoped; HIPAA dropped

- **Decision:** **HIPAA does not apply** — it is US human-healthcare law with no
  extraterritorial reach here, and separately, bee/apiary health records are not GDPR Art. 9
  "special category" data (Art. 9 health data is limited to natural persons). Remove HIPAA
  from NFR-CMP-1. **GDPR applies** (already affirmed) with ordinary (non-special-category)
  handling for treatment/health-of-bees records.

  The concrete **Portuguese/EU beekeeping and honey-traceability obligations** are enumerated
  in [`docs/research/regulatory-pt-eu-beekeeping.md`](../docs/research/regulatory-pt-eu-beekeeping.md)
  (#91). None block current M0-M2 scope; the following are accepted as **future-relevant data
  points**, to be triaged into concrete FR/NFR changes when the owning feature epic
  (apiaries/activities/import-export) is planned:
  - Beekeeper/apiary DGAV registration number (optional field).
  - Annual stock-declaration record (Sept 1-30 window + 20%/20-colony interim trigger),
    distinct from the live hive count (FR-AP-7/D-2).
  - Optional structured disease/condition field on Treatment activities (FR-AC-1), informed
    by DGAV's mandatory-notification disease list (DDO).
  - A retention-policy note reconciling GDPR erasure (FR-HIS-1) with the ~5-year veterinary
    treatment record-keeping expectation (Reg (EU) 2019/6).
  - Optional lot/batch identifier on Honey harvest activities (FR-AC-1), for future
    traceability/export features (Reg (EC) 178/2002 Art. 18, Reg (EU) 931/2011, Dir
    2011/91/EU, Dir 2001/110/EC as amended by Dir (EU) 2024/1438).

- **Supersedes:** Q-CMP, Q-REG.
- **Affected requirements:**
  - **NFR-CMP-1** — drop HIPAA; note GDPR + non-special-category clarification for bee-health
    data; cite PT/EU beekeeping & food-traceability regimes as the operative compliance
    surface.
  - **Context C-2** — the "not yet enumerated" open question is resolved; regulations are
    enumerated in the research note above.
- **Not decided here (deferred to feature epics):** whether/when to actually implement any of
  the five future-relevant data points above. This decision **scopes the obligations**, it
  does not commit to schema changes.
```

### Proposed edit — `NFR-CMP-1`

Replace:

```markdown
- **NFR-CMP-1** — Adherence to relevant regulations/standards. The source lists
  **GDPR and HIPAA** among others.
  - _Note (Q-CMP):_ **GDPR applies** (Portugal/EU). **HIPAA is US healthcare** and
    is almost certainly **not applicable** to a beekeeping app — confirm and
    remove if so. Portuguese/EU **beekeeping & food-traceability** regulation is
    the more likely real obligation (see context C-2 / Q-REG).
```

with:

```markdown
- **NFR-CMP-1** — Adherence to relevant regulations/standards: **GDPR** (Portugal/EU) and
  the **Portuguese/EU beekeeping & honey-traceability regime** — DL 203/2005 (PT beekeeping
  activity & sanitary rules, DGAV), Reg (EC) 178/2002 Art. 18 + Reg (EU) 931/2011 (food
  traceability), Dir 2001/110/EC as amended by Dir (EU) 2024/1438 (honey composition/origin
  labelling), Dir 2011/91/EU (lot marking), Reg (EU) 2019/6 (veterinary medicinal product
  record-keeping). **HIPAA does not apply** (US human-healthcare law; bee-health data is also
  not GDPR Art. 9 special-category data) — dropped.
  - _Resolved (D-18):_ obligations enumerated in
    [`docs/research/regulatory-pt-eu-beekeeping.md`](../docs/research/regulatory-pt-eu-beekeeping.md)
    (#91); concrete FR/NFR schema changes triaged per feature epic, not applied here.
```

### Proposed edit — `Context C-2`

Replace the `> Open question:` line with:

```markdown
> **Resolved (D-18):** the specific Portuguese/EU regulations are enumerated in
> [`docs/research/regulatory-pt-eu-beekeeping.md`](../docs/research/regulatory-pt-eu-beekeeping.md)
> (#91) — apiary registration (DGAV), stock declarations, mandatory-notification bee diseases,
> and honey/food traceability. None block current scope; see the note for future-relevant
> data-model flags.
```

### `open-questions.md` — entry to remove

The **Q-CMP / Q-REG** entry (Tier 3) would be **deleted in full** once D-18 is applied, per
the "resolved question is removed" convention.
