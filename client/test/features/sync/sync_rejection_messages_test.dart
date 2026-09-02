import 'package:beekeepingit_client/features/sync/sync_rejection_messages.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the rejection-code → localized-copy mapping (#443, follow-up
/// to #426/#434): the server's RFC 9457 `(field, code)` pairs must come back
/// to the user as **safe, localized** guidance — never the raw English
/// validation text, and never the snake_case DB column name it embeds.
void main() {
  late AppLocalizations en;
  late AppLocalizations pt;

  setUp(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    pt = await AppLocalizations.delegate.load(const Locale('pt'));
  });

  group('localizedRejectionMessages', () {
    test('maps a known (field, code) pair to specific localized guidance', () {
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(field: 'data.hive_count', code: 'out_of_range'),
        ]),
        ['Number of hives: this must be 0 or more.'],
      );
    });

    test('translates the same rejection to Portuguese', () {
      final messages = localizedRejectionMessages(pt, const [
        RejectedFieldIssue(field: 'data.hive_count', code: 'out_of_range'),
      ]);
      expect(messages, hasLength(1));
      expect(messages.single, isNot(contains('hive_count')));
      expect(messages.single, contains('0 ou mais'));
    });

    test(
      'maps the exact #426 leak incident — a journey whose default_attributes '
      'was not a JSON object — to safe localized copy',
      () {
        expect(
          localizedRejectionMessages(en, const [
            RejectedFieldIssue(
              field: 'data.default_attributes',
              code: 'invalid',
            ),
          ]),
          ["Defaults for activities: this value isn't valid."],
        );
      },
    );

    test('falls back to the generic message for an unmapped code', () {
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(
            field: 'data.default_attributes',
            code: 'invalid_type',
          ),
        ]),
        [en.syncNeedsFixGenericProblem],
      );
    });

    test('falls back to the generic message for an unmapped field', () {
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(field: 'data.secret_column', code: 'invalid'),
        ]),
        [en.syncNeedsFixGenericProblem],
      );
    });

    test(
      'falls back to the generic message for a structural (non-user-fixable) '
      'field such as the wire envelope',
      () {
        for (final field in const [
          'op',
          'entity_type',
          'id',
          'updated_at',
          'data',
          'ops',
        ]) {
          expect(
            localizedRejectionMessages(en, [
              RejectedFieldIssue(field: field, code: 'invalid'),
            ]),
            [en.syncNeedsFixGenericProblem],
            reason: 'field "$field" must not be labelled to the user',
          );
        }
      },
    );

    test("falls back to the generic message for a journey's default_attributes "
        'byte cap, whose "text is too long" copy would be untrue', () {
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(
            field: 'data.default_attributes',
            code: 'too_long',
          ),
        ]),
        [en.syncNeedsFixGenericProblem],
      );
      // An activity attribute's own too_long IS a real string-length cap.
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(
            field: 'data.attributes.lot_batch',
            code: 'too_long',
          ),
        ]),
        ['Details: an entry here is too long.'],
      );
    });

    test('collapses an activity attribute key to the generic details label '
        '(the per-type attribute keys are internal names)', () {
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(
            field: 'data.attributes.queen_seen',
            code: 'required',
          ),
        ]),
        ['Details: an entry here still needs filling in.'],
      );
    });

    test(
      'two missing attributes of the same activity collapse to ONE line that '
      'is still true of both (a feeding needs feed_type AND feed_amount)',
      () {
        final messages = localizedRejectionMessages(en, const [
          RejectedFieldIssue(
            field: 'data.attributes.feed_type',
            code: 'required',
          ),
          RejectedFieldIssue(
            field: 'data.attributes.feed_amount',
            code: 'required',
          ),
        ]);
        // The bag has one label, so both errors de-duplicate onto one line.
        // That line must therefore not claim "Details" itself is missing —
        // the user did fill the section in; entries inside it are missing.
        expect(messages, ['Details: an entry here still needs filling in.']);
        expect(messages.single, isNot(contains('this is required')));
      },
    );

    test('an unmapped issue falls back to the caller\'s message when one is '
        'given (the #584 pre-push path, whose edits were never sent)', () {
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(field: 'data.mystery', code: 'invalid'),
        ], fallback: 'not sent yet'),
        ['not sent yet'],
      );
      // A mapped issue still wins over the fallback — the per-field mapping
      // applies to locally-detected failures unchanged.
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(field: 'data.title', code: 'required'),
        ], fallback: 'not sent yet'),
        ['Title: this is required.'],
      );
    });

    test('keeps every mapped issue, de-duplicated and capped', () {
      final messages = localizedRejectionMessages(en, const [
        RejectedFieldIssue(field: 'data.name', code: 'required'),
        RejectedFieldIssue(field: 'data.notes', code: 'too_long'),
        // Duplicate of the first — must not be listed twice.
        RejectedFieldIssue(field: 'data.name', code: 'required'),
        RejectedFieldIssue(field: 'data.place_label', code: 'too_long'),
        RejectedFieldIssue(field: 'data.location', code: 'required'),
      ]);
      expect(messages, hasLength(maxRejectionMessages));
      expect(messages.first, 'Name: this is required.');
      expect(messages.toSet(), hasLength(messages.length));
    });

    test('drops unmappable issues but keeps the mappable ones', () {
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(field: 'data.mystery', code: 'invalid'),
          RejectedFieldIssue(field: 'data.title', code: 'too_long'),
        ]),
        ['Title: this text is too long.'],
      );
    });

    test(
      'falls back to the generic message when the op carries no field detail '
      '(the collateral op of an atomic push)',
      () {
        expect(localizedRejectionMessages(en, const []), [
          en.syncNeedsFixGenericProblem,
        ]);
      },
    );

    // #298: a rejected stock declaration used to fall through to the generic
    // line even though the declaration validator
    // (`services/apiaries/api/declarations.go`) reports exact (field, code)
    // pairs for it.
    test("maps a stock declaration's own fields to specific guidance", () {
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(field: 'data.declared_on', code: 'required'),
        ]),
        ['Declaration date: this is required.'],
      );
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(field: 'data.declared_on', code: 'invalid'),
        ]),
        ["Declaration date: this value isn't valid."],
      );
      // The declaration's total is capped at >= 0, like an apiary's own hive
      // count — so it gets the same sharper fragment, not "out of range".
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(
            field: 'data.total_hive_count',
            code: 'out_of_range',
          ),
        ]),
        ['Total hives: this must be 0 or more.'],
      );
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(
            field: 'data.registration_number',
            code: 'too_long',
          ),
        ]),
        ['Registration number: this text is too long.'],
      );
    });

    test('the registration_number label serves the APIARY op too — the table '
        'is keyed by field name, and it is the same column', () {
      // `services/apiaries/api/sync.go` validates the same column on an
      // apiary put; one entry must cover both ops.
      final messages = localizedRejectionMessages(pt, const [
        RejectedFieldIssue(field: 'data.registration_number', code: 'too_long'),
      ]);
      expect(messages, ['Número de registo: este texto é demasiado longo.']);
      expect(messages.single, isNot(contains('registration_number')));
    });

    test('an activity type and a journey main activity type get the label of '
        'the form each Fix action opens', () {
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(field: 'data.type', code: 'invalid'),
        ]),
        ["Activity type: this value isn't valid."],
      );
      expect(
        localizedRejectionMessages(en, const [
          RejectedFieldIssue(field: 'data.main_activity_type', code: 'invalid'),
        ]),
        ["Main activity type: this value isn't valid."],
      );
    });
  });

  group('no raw server vocabulary ever reaches the copy', () {
    // Every (field, code) pair the sync validators can emit
    // (services/{apiaries,activities,journeys,todos}/api/sync.go, plus
    // apiaries' declarations.go for stock declarations), asserted
    // as a set: whatever comes back must be localized and must never contain
    // the snake_case field name (#426's leak) — mapped or not.
    const everyServerField = [
      // envelope
      'op', 'entity_type', 'id', 'updated_at', 'data', 'ops',
      // apiary
      'data.name', 'data.location', 'data.hive_count', 'data.notes',
      'data.place_label', 'data.location_lat', 'data.location_lon',
      // apiary_counter
      'data.apiary_id', 'data.counter_type', 'data.value',
      // activity
      'data.occurred_at', 'data.attributes', 'data.type', 'data.journey_id',
      'data.attributes.hive_health',
      // journey
      'data.main_activity_type', 'data.status', 'data.default_attributes',
      // todo
      'data.title', 'data.description', 'data.due_date', 'data.priority',
      'data.completed_at', 'data.assignee_id',
      // stock declaration (services/apiaries/api/declarations.go) —
      // registration_number is also validated on an apiary put
      'data.declared_on', 'data.total_hive_count', 'data.registration_number',
    ];
    const everyServerCode = [
      'required',
      'invalid',
      'out_of_range',
      'too_long',
      'not_found',
      'too_many',
    ];

    for (final locale in const ['en', 'pt']) {
      test('locale "$locale" never renders a raw field name', () async {
        final l10n = await AppLocalizations.delegate.load(Locale(locale));
        for (final field in everyServerField) {
          for (final code in everyServerCode) {
            final messages = localizedRejectionMessages(l10n, [
              RejectedFieldIssue(field: field, code: code),
            ]);
            expect(messages, isNotEmpty);
            // Guard the guard: a pair that degrades to the generic message
            // satisfies the no-leak assertions trivially, so pairs that are
            // supposed to map must be seen to actually map. Every `data.`
            // field maps for the five codes the validators emit, except two
            // deliberate non-mappings: a journey's default_attributes byte
            // cap, and not_found on the attribute bag (which the bag's own
            // wording has no truthful phrasing for).
            final unmappedOnPurpose =
                (field == 'data.default_attributes' && code == 'too_long') ||
                (field.startsWith('data.attributes') && code == 'not_found');
            final mapped =
                field.startsWith('data.') &&
                !unmappedOnPurpose &&
                const [
                  'required',
                  'invalid',
                  'out_of_range',
                  'too_long',
                  'not_found',
                ].contains(code);
            expect(
              messages.single == l10n.syncNeedsFixGenericProblem,
              mapped ? isFalse : isTrue,
              reason: mapped
                  ? '($field, $code) should map to specific guidance'
                  : '($field, $code) should degrade to the generic message',
            );
            for (final message in messages) {
              // A localized label may legitimately be the English word a
              // column was named after ("Name"); what must never appear is
              // the raw snake_case identifier or the dotted wire path.
              expect(
                message,
                isNot(contains('_')),
                reason: '($field, $code) leaked a snake_case name',
              );
              expect(
                message.toLowerCase(),
                isNot(contains(field.toLowerCase())),
                reason: '($field, $code) leaked the raw field path',
              );
            }
          }
        }
      });
    }
  });
}
