/// Display helpers for rendering a member *identity*: the members feature's
/// own, plus the two pieces every feature that attributes a record to a user
/// shares — [shortMemberId] and [sanitizedMemberName].
///
/// Only the genuinely-identical pieces are shared. The surrounding
/// resolution functions (activity_display.dart's `activityAttributionText`,
/// todo_display.dart's assignee label, history_display.dart's
/// `historyActorText`) stay per-feature because each picks its own ARB keys
/// for the "You" / "Member {id}" / "Unknown" fallbacks — but they all agree
/// on what a short id looks like, and that agreement is what this file
/// makes explicit rather than re-deriving in each caller.
///
/// [memberIdentityLabel] below is the members feature's OWN such resolution
/// function — it lives here because this file IS that feature's display
/// layer, not because it is shared.
library;

import '../../l10n/gen/app_localizations.dart';

/// The last 8 characters of a UUID — enough to visually distinguish
/// different users within one org without printing the full 36-character id
/// on every row.
///
/// The fallback when no display name is available: a member with an
/// incomplete profile, one since removed from the org, or simply the
/// offline / pre-first-fetch case where the online-only roster
/// (`memberNamesProvider`) hasn't loaded.
///
/// The fragment itself is stable and cannot be forged — it is derived from
/// the internal id, never from user-supplied text. The *rendered* label
/// around it (`Member 2a3b4c5d`) can still be imitated by someone who sets
/// their display name to that shape; see [sanitizedMemberName]'s non-goals
/// for why that is left alone rather than filtered.
String shortMemberId(String id) =>
    id.length <= 8 ? id : id.substring(id.length - 8);

/// Whitespace, in every form a display name can carry it — ASCII spacing
/// controls (tab/newline/CR/FF/VT), NEL, NBSP, the Unicode space family, the
/// line/paragraph separators, and the codepoints that are not *categorized*
/// as spaces yet **render as blank**: the Hangul fillers and the empty
/// braille pattern. All fold to one plain space in [sanitizedMemberName].
///
/// The blank-rendering set is folded here rather than dropped in
/// [_isInvisible] on purpose: folding runs them through the same collapse, so
/// a name that is nothing but fillers still ends up `null` (no blank row) and
/// `'Ana<filler>Silva'` still ends up distinguishable from `'AnaSilva'`
/// rather than colliding with it.
bool _isSpaceLike(int rune) =>
    rune == 0x115F || // hangul choseong filler
    rune == 0x1160 || // hangul jungseong filler
    rune == 0x2800 || // braille pattern blank
    rune == 0x3164 || // hangul filler
    rune == 0xFFA0 || // halfwidth hangul filler
    rune == 0x09 || // tab
    rune == 0x0A || // line feed
    rune == 0x0B || // vertical tab
    rune == 0x0C || // form feed
    rune == 0x0D || // carriage return
    rune == 0x20 || // space
    rune == 0x85 || // next line
    rune == 0xA0 || // no-break space
    rune == 0x1680 || // ogham space mark
    (rune >= 0x2000 && rune <= 0x200A) || // en quad .. hair space
    rune == 0x2028 || // line separator
    rune == 0x2029 || // paragraph separator
    rune == 0x202F || // narrow no-break space
    rune == 0x205F || // medium mathematical space
    rune == 0x3000; // ideographic space

/// Codepoints that render as NOTHING yet change how the glyphs around them
/// are laid out or compared: the C0/C1 control ranges, the zero-width and
/// joiner characters, the bidi embedding/override/isolate controls, the
/// variation and annotation marks, and the **tag block**. Dropped outright by
/// [sanitizedMemberName].
///
/// The intent is Unicode's `Default_Ignorable_Code_Point` property, spelled
/// out as ranges because Dart's core library exposes no character-property
/// lookup and this app carries no ICU data. Spelled-out ranges rot, so the
/// rule for editing this list is the property, not the attack: a codepoint
/// belongs here because it is default-ignorable, not because some specific
/// exploit needed it.
///
/// U+E0000–U+E007F earns its own mention: the tag block is a fully invisible
/// channel that can carry an arbitrary ASCII payload inside a visible name —
/// hidden from every screenshot and every human reviewer, and riding along
/// into anything downstream that consumes a roster as text.
bool _isInvisible(int rune) =>
    rune <= 0x1F || // C0 controls
    (rune >= 0x7F && rune <= 0x9F) || // DEL + C1 controls
    rune == 0x00AD || // soft hyphen
    rune == 0x034F || // combining grapheme joiner
    rune == 0x061C || // arabic letter mark
    (rune >= 0x17B4 && rune <= 0x17B5) || // khmer inherent vowels
    (rune >= 0x180B && rune <= 0x180F) || // mongolian FVS + vowel separator
    (rune >= 0x200B && rune <= 0x200F) || // ZWSP/ZWNJ/ZWJ/LRM/RLM
    (rune >= 0x202A && rune <= 0x202E) || // bidi embedding + OVERRIDE
    (rune >= 0x2060 && rune <= 0x2065) || // word joiner + invisible operators
    (rune >= 0x2066 && rune <= 0x2069) || // bidi isolates
    (rune >= 0x206A && rune <= 0x206F) || // deprecated format controls
    (rune >= 0xFE00 && rune <= 0xFE0F) || // variation selectors 1..16
    (rune >= 0xFFF9 && rune <= 0xFFFB) || // interlinear annotation
    rune == 0xFEFF || // zero-width no-break space / BOM
    (rune >= 0x1D173 && rune <= 0x1D17A) || // musical format controls
    (rune >= 0x1BCA0 && rune <= 0x1BCA3) || // shorthand format controls
    (rune >= 0xE0000 && rune <= 0xE007F) || // tag block (see above)
    (rune >= 0xE0100 && rune <= 0xE01EF); // variation selectors 17..256

/// Makes an upstream-authored display name safe to render as a person's
/// IDENTITY, returning `null` when nothing readable survives (#582,
/// NFR-SEC-1, security-review HIGH).
///
/// Every name shown by this app originates outside it — seeded from the IdP's
/// `name` claim (FR-ONB-1's amendment, #572) and thereafter writable by the
/// account's owner through `PATCH /v1/profile`. The IdP's own enrollment
/// resolver strips non-printable codepoints (auth.md §8.15), but that guards
/// only the SEED; the self-service writer is a second, unfiltered path. So the
/// client does not trust the string it is handed:
///
/// * **Invisible codepoints are dropped** ([_isInvisible]) — a right-to-left
///   OVERRIDE (U+202E) reorders the glyphs of the row it lands in, and a
///   zero-width space makes two different accounts render identically.
/// * **Every whitespace form folds to a single space** ([_isSpaceLike]) — a
///   newline in a name would otherwise paint a second line under it, forging
///   the row's own role/status subtitle; leading/trailing padding would make
///   two rows look like the same person.
///
/// What it deliberately does NOT attempt, and why each is left alone:
///
/// * **Homoglyphs** (a Cyrillic look-alike for a Latin letter) and plain-text
///   claims of authority (`"Ana Silva (Admin)"`, or a name spelled to mimic
///   this file's own `Member 2a3b4c5d` fallback). Neither is decidable here —
///   the app ships no ICU script data, and a mixed-script heuristic would
///   reject the legitimate names it must carry (NFR-I18N-1) — and neither
///   confers any authority: roles are app-side and server-enforced
///   (NFR-ROL-1), never read from a name. What limits the impersonation is
///   structural rather than lexical: the members row renders the name as its
///   title with the SERVER-resolved `role`/`status` directly beneath it, so a
///   name claiming "(Admin)" sits against the authoritative answer. Same
///   consequence for the fallback label — the id fragment it is *derived
///   from* cannot be forged, but the rendered string can be imitated.
/// * **Combining marks.** Stacked marks overflow their glyph box and can
///   paint over the row beneath — the same outcome as the forged second line
///   above, reached differently. Not fixed by dropping them: legitimate
///   scripts need marks, so the fix is a stacking cap, and that is a
///   rendering concern for every name in the app rather than something this
///   filter can decide. Tracked in #844.
/// * **Implicit bidi.** Dropping the explicit controls does not stop
///   reordering: strongly-RTL letters — a genuine Arabic or Hebrew name, the
///   input this app must render — reorder the NEUTRAL characters that follow
///   them, with no control codepoint involved. No filter can fix that, and it
///   only bites where a name is interpolated into a larger string instead of
///   being its own `Text` (the members list, the activity list and the todo
///   picker are all the latter). The fix is FSI/PDI isolation at those
///   composition sites, tracked in #845.
///
/// Returns `null` for a null input, for a blank one, and for a name that was
/// nothing but invisible codepoints — so every caller's existing "no name
/// available" branch handles all three the same way.
String? sanitizedMemberName(String? raw) {
  if (raw == null) return null;
  final buffer = StringBuffer();
  for (final rune in raw.runes) {
    if (_isSpaceLike(rune)) {
      buffer.writeCharCode(0x20);
    } else if (!_isInvisible(rune)) {
      buffer.writeCharCode(rune);
    }
  }
  final collapsed = buffer
      .toString()
      .split(' ')
      .where((part) => part.isNotEmpty)
      .join(' ');
  return collapsed.isEmpty ? null : collapsed;
}

/// The display text for one member in the ORG ROSTER sense — the members
/// list's own row title (#582, FR-TEN-2, FR-ONB-1), resolved with the same
/// name-then-short-id precedence activity_display.dart's
/// `activityAttributionText`, todo_display.dart's `todoAssigneeLabel` and
/// history_display.dart's `historyActorText` already use, against the same
/// roster source (`memberNamesProvider`, members_repository.dart):
///
/// 1. The member's real display name, when [memberNames] carries a non-blank
///    entry for [userId] (`user_id -> name`, seeded server-side from the
///    IdP-verified `name` claim — FR-ONB-1's amendment, #572).
/// 2. A short, stable, non-spoofable id fragment ([shortMemberId]) otherwise:
///    an account created before that seeding landed, a member who has not
///    completed the FR-ONB-1 profile gate yet, or simply the offline /
///    pre-first-fetch case where the online-only roster hasn't loaded. The
///    full 36-character id is never shown — it is unreadable at a glance,
///    near-identical between rows down most of its length, and says nothing a
///    reader can act on.
///
/// No "You" special case, unlike the three attribution helpers above: those
/// answer "who did this", where naming the reader is the useful answer. This
/// one answers "who is in this organization", where a roster row that renamed
/// the reader to "You" would hide the very name the admin came to read.
///
/// The roster entry is put through [sanitizedMemberName] first, so a name that
/// is blank, whitespace-only, or nothing but invisible codepoints falls to the
/// short-id branch rather than rendering as a blank (or a forged) row title.
String memberIdentityLabel(
  AppLocalizations l10n,
  String userId,
  Map<String, String> memberNames,
) {
  final name = sanitizedMemberName(memberNames[userId]);
  if (name != null) return name;
  return l10n.memberNameFallback(shortMemberId(userId));
}
