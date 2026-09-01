/// Stock-declaration timing rules (FR-AP-10, #298).
///
/// Portugal's `Declaração de Existências` has two timing obligations, and this
/// file is the single place either is expressed:
///
///  * an **annual** declaration between **1 and 30 September** each year, and
///  * an **interim** declaration whenever the hive count changes by
///    **more than 20% AND at least 20 colonies**, filed within **10 days**.
///
/// The interim rule's exact shape matters and is easy to get wrong. DGAV's own
/// wording is _"alterações significativas **superiores a 20 %** no número de
/// colmeias, sendo estas alterações **iguais ou superiores a 20 colónias** do
/// efetivo"_ — a **strict** `>` on the percentage, a **non-strict** `>=` on the
/// colony count, joined by **AND**. An `OR` reading (which #298 originally
/// carried, and which the project's own research note half-carried with `>=20%`)
/// would fire on a smallholder going from 3 hives to 4, which the regulation
/// plainly does not intend.
///
/// **Everything here is advisory.** These functions drive text in the app's DGAV
/// section and nothing else: nothing is blocked, no declaration is required by
/// the app, and no submission is made to DGAV/SICOA (out of scope per D-19's
/// research note §7). They are pure — dates in, answers out — so the caller
/// supplies "today" rather than this file reading a clock, which also keeps
/// every boundary directly testable.
library;

/// The month the annual declaration window falls in (September).
const _annualWindowMonth = DateTime.september;

/// The last day of the annual declaration window (30 September).
const _annualWindowLastDay = 30;

/// The interim trigger's percentage threshold — a change must exceed this
/// fraction of the last declared count ("superiores a 20 %", so strictly
/// greater).
const _interimPercentThreshold = 0.20;

/// The interim trigger's absolute threshold — a change must reach this many
/// colonies ("iguais ou superiores a 20 colónias", so greater-or-equal).
const _interimColonyThreshold = 20;

/// Days a beekeeper has to file an interim declaration after the change.
const _interimDeadlineDays = 10;

/// Whether [today] falls inside the annual 1–30 September declaration window.
bool isAnnualWindowOpen(DateTime today) => today.month == _annualWindowMonth;

/// The 30 September a beekeeper looking at [today] is actually working toward:
/// this year's when [today] is on or before it, next year's once it has passed.
DateTime annualWindowCloseDate(DateTime today) {
  final thisYear = DateTime(
    today.year,
    _annualWindowMonth,
    _annualWindowLastDay,
  );
  if (!today.isAfter(thisYear)) return thisYear;
  return DateTime(today.year + 1, _annualWindowMonth, _annualWindowLastDay);
}

/// Whether any of [declarationDates] already satisfies **this** year's annual
/// window — a declaration filed in September of the same year as [today].
///
/// Last September does not count: the obligation is annual, so a declaration
/// from a previous year leaves this year's still outstanding.
bool hasDeclaredInAnnualWindow({
  required Iterable<DateTime> declarationDates,
  required DateTime today,
}) {
  return declarationDates.any(
    (d) => d.year == today.year && d.month == _annualWindowMonth,
  );
}

/// Whether the hive count has moved enough since the last declaration to
/// require an interim one: **more than 20% AND at least 20 colonies**.
///
/// Symmetric in direction — the regulation speaks of "alterações", so a drop of
/// 30 colonies triggers exactly as an increase of 30 does.
///
/// A [lastDeclaredCount] of zero has no meaningful percentage, so the
/// percentage half is treated as satisfied and the colony half alone decides:
/// going from nothing to 20+ colonies is unambiguously material, while going to
/// 19 is not. This avoids both a division by zero and the alternative of never
/// triggering for a beekeeper whose first declaration recorded no hives.
bool isInterimTriggerMet({
  required int lastDeclaredCount,
  required int currentCount,
}) {
  final change = (currentCount - lastDeclaredCount).abs();
  if (change < _interimColonyThreshold) return false;
  if (lastDeclaredCount == 0) return true;
  return change / lastDeclaredCount > _interimPercentThreshold;
}

/// The date by which an interim declaration is due, given the day the change
/// happened — 10 days after it.
///
/// Calendar arithmetic via the [DateTime] constructor's own overflow
/// normalization, NOT `add(Duration(days: 10))`: a Duration is an exact number
/// of 24-hour units, so a span crossing Portugal's late-March DST change comes
/// back an hour off and lands on the wrong wall-clock time (and, for a late-day
/// change, potentially the wrong DAY). A deadline is a calendar date, so it is
/// computed as one.
DateTime interimDeclarationDeadline(DateTime changedOn) => DateTime(
  changedOn.year,
  changedOn.month,
  changedOn.day + _interimDeadlineDays,
);
