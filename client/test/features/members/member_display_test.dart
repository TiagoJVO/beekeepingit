import 'package:beekeepingit_client/features/members/member_display.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_en.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_pt.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit coverage for the members feature's identity-display helpers (#582,
/// FR-TEN-2, NFR-I18N-1, NFR-SEC-1) — pure functions taking
/// `AppLocalizations` rather than a `BuildContext`, the same convention
/// activity_display.dart / todo_display.dart / history_display.dart follow,
/// so every rule is testable without pumping a widget.
final _en = AppLocalizationsEn();
final _pt = AppLocalizationsPt();

/// A realistic 36-character user id — the exact value the members list used
/// to print verbatim (#582).
const _uuid = '3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';

/// Invisible codepoints written as escapes on purpose: spelled literally
/// they are unreviewable in a diff, and an editor or a formatter could
/// silently drop them.
const _rlo = '\u202E'; // right-to-left OVERRIDE
const _zwsp = '\u200B'; // zero-width space
const _nbsp = '\u00A0'; // no-break space

void main() {
  group('shortMemberId', () {
    test('an id of 8 characters or fewer is returned whole', () {
      expect(shortMemberId('abcd1234'), 'abcd1234');
      expect(shortMemberId('short'), 'short');
      expect(shortMemberId(''), '');
    });

    test('a longer id is trimmed to its last 8 characters', () {
      expect(shortMemberId(_uuid), '2a3b4c5d');
    });
  });

  // A display name is authored OUTSIDE this app — seeded from the IdP's
  // `name` claim and thereafter writable by the account's owner through
  // `PATCH /v1/profile`, which today trims whitespace and bounds the length
  // and nothing else. The app renders it as a person's identity, so it is
  // filtered at the point of display (security-review HIGH on #582).
  group('sanitizedMemberName (#582, NFR-SEC-1)', () {
    test('an ordinary name is returned untouched', () {
      expect(sanitizedMemberName('Ana Silva'), 'Ana Silva');
      expect(sanitizedMemberName('José Público-Nuñez'), 'José Público-Nuñez');
    });

    test('null, empty and whitespace-only all resolve to null', () {
      expect(sanitizedMemberName(null), isNull);
      expect(sanitizedMemberName(''), isNull);
      expect(sanitizedMemberName('   '), isNull);
      expect(sanitizedMemberName('\t\n'), isNull);
      expect(sanitizedMemberName(_nbsp), isNull);
    });

    test('a name of nothing but invisible codepoints resolves to null', () {
      expect(sanitizedMemberName('$_rlo$_zwsp'), isNull);
    });

    test('a bidi override is dropped, the readable text kept', () {
      final safe = sanitizedMemberName('${_rlo}Ana Silva');
      expect(safe, 'Ana Silva');
      expect(safe!.contains(_rlo), isFalse);
    });

    test('zero-width characters cannot make two names render alike', () {
      expect(sanitizedMemberName('An${_zwsp}a Silva'), 'Ana Silva');
      expect(sanitizedMemberName('${_zwsp}Ana Silva'), 'Ana Silva');
    });

    // The filter's editing rule is the Unicode property, not the attack: a
    // codepoint belongs in `_isInvisible` because it is
    // Default_Ignorable_Code_Point. These are the assigned ones a
    // security review found the hand-written ranges had skipped — each is
    // the same render-alike vector as the zero-width space above.
    test('the default-ignorable set has no assigned gaps', () {
      const cases = <String, String>{
        'combining grapheme joiner (U+034F)': '\u034F',
        'inhibit symmetric swapping (U+206A)': '\u206A',
        'national digit shapes (U+206E)': '\u206E',
        'mongolian free variation selector (U+180B)': '\u180B',
        'khmer inherent vowel (U+17B4)': '\u17B4',
        'shorthand format control (U+1BCA0)': '\u{1BCA0}',
      };
      for (final entry in cases.entries) {
        expect(
          sanitizedMemberName('An${entry.value}a Silva'),
          'Ana Silva',
          reason: '${entry.key} must not survive into a rendered identity',
        );
      }
    });

    test('a newline cannot forge a second line under the name — every '
        'whitespace form folds to one space', () {
      expect(
        sanitizedMemberName('Ana Silva\nMember · Active'),
        'Ana Silva Member · Active',
      );
      expect(sanitizedMemberName('Ana${_nbsp}Silva'), 'Ana Silva');
      expect(sanitizedMemberName('  Ana   Silva  '), 'Ana Silva');
    });

    test(
      'homoglyphs and plain-text authority claims are deliberately NOT '
      'touched — neither is decidable here, and neither confers authority',
      () {
        // A Cyrillic capital A (U+0410) in place of the Latin one.
        expect(sanitizedMemberName('\u0410na Silva'), '\u0410na Silva');
        expect(sanitizedMemberName('Ana Silva (Admin)'), 'Ana Silva (Admin)');
      },
    );
  });

  group('memberIdentityLabel (#582, FR-TEN-2)', () {
    test('a roster entry resolves to the member\'s real display name', () {
      expect(
        memberIdentityLabel(_en, 'user-1', const {'user-1': 'Ana Silva'}),
        'Ana Silva',
      );
    });

    test('a member absent from the roster degrades to a short id fragment, '
        'never the full id', () {
      final text = memberIdentityLabel(_en, _uuid, const {});
      expect(text, 'Member 2a3b4c5d');
      expect(text.contains(_uuid), isFalse);
    });

    test('a roster entry that is blank degrades the same way', () {
      // `listMemberNames` already drops empty names on the way into the map,
      // but a whitespace-only name would sail through and render as a blank
      // title — the one shape that looks like a rendering bug rather than a
      // missing profile.
      expect(
        memberIdentityLabel(_en, _uuid, const {_uuid: ''}),
        'Member 2a3b4c5d',
      );
      expect(
        memberIdentityLabel(_en, _uuid, const {_uuid: '   '}),
        'Member 2a3b4c5d',
      );
    });

    test('a name with nothing readable left degrades the same way', () {
      expect(
        memberIdentityLabel(_en, _uuid, {_uuid: '$_rlo$_zwsp'}),
        'Member 2a3b4c5d',
      );
    });

    test('a name carrying invisible codepoints renders sanitized', () {
      expect(
        memberIdentityLabel(_en, _uuid, {_uuid: '${_rlo}Ana Silva'}),
        'Ana Silva',
      );
    });

    test('the fallback is localized (NFR-I18N-1)', () {
      expect(memberIdentityLabel(_pt, _uuid, const {}), 'Membro 2a3b4c5d');
    });

    test('a real name is never translated away', () {
      expect(
        memberIdentityLabel(_pt, _uuid, const {_uuid: 'Ana Silva'}),
        'Ana Silva',
      );
    });
  });
}
