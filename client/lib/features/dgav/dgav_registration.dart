/// DGAV beekeeper registration number — resolution rules (FR-AP-9, #296).
///
/// DGAV (Direção-Geral de Alimentação e Veterinária) issues **one registration
/// number per beekeeper** (`número de registo do apicultor`) and requires it
/// displayed visibly at each of that beekeeper's apiaries. Apiaries themselves
/// are identified to DGAV by their **coordinates**, not by a number of their
/// own.
///
/// So the number lives in two places, and neither alone is the answer:
///
///  * the **organization** carries the default
///    (`Organization.dgavRegistrationNumber`, read over REST and cached
///    locally so this resolution works offline), and
///  * an **apiary** may carry an override
///    (`Apiary.dgavRegistrationNumber`), for the case D-19's triage called
///    out — one organization covering several beekeepers, whose apiaries
///    carry different numbers.
///
/// Everything here is advisory: a beekeeper who never fills either field sees
/// no number and is never blocked.
library;

/// The DGAV registration number to display for an apiary, or null when
/// neither the apiary nor its organization has one.
///
/// [apiaryOverride] wins when it is present and non-blank; otherwise
/// [organizationDefault] is used. Blank-but-present values are treated as
/// absent on both sides: the server stores the apiary override as NULL and the
/// organization default as `''` for "unset", and a form that trims an entry
/// down to nothing must mean "no number", not "an empty number".
String? effectiveDgavRegistrationNumber({
  required String? apiaryOverride,
  required String? organizationDefault,
}) {
  final override = apiaryOverride?.trim() ?? '';
  if (override.isNotEmpty) return override;
  final fallback = organizationDefault?.trim() ?? '';
  return fallback.isEmpty ? null : fallback;
}

/// Whether the number an apiary displays comes from its organization rather
/// than from the apiary itself — the detail screen marks an inherited value so
/// a beekeeper can tell "this apiary has its own number" from "this apiary uses
/// the organization's".
///
/// False when there is no effective number at all: nothing is shown, so there
/// is nothing to mark as inherited.
bool isDgavRegistrationNumberInherited({
  required String? apiaryOverride,
  required String? organizationDefault,
}) {
  if ((apiaryOverride?.trim() ?? '').isNotEmpty) return false;
  return (organizationDefault?.trim() ?? '').isNotEmpty;
}
