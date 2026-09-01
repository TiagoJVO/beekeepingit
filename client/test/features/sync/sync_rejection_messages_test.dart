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
        localizedRejectionMessages(
          en,
          fieldIssues: const [
            RejectedFieldIssue(field: 'data.hive_count', code: 'out_of_range'),
          ],
          errorCode: 'validation.failed',
        ),
        ['Hive count: must be 0 or more.'],
      );
    });

    test('translates the same rejection to Portuguese', () {
      final messages = localizedRejectionMessages(
        pt,
        fieldIssues: const [
          RejectedFieldIssue(field: 'data.hive_count', code: 'out_of_range'),
        ],
        errorCode: 'validation.failed',
      );
      expect(messages, hasLength(1));
      expect(messages.single, isNot(contains('hive_count')));
      expect(messages.single, contains('0 ou mais'));
    });

    test('falls back to the generic message for an unmapped code', () {
      expect(
        localizedRejectionMessages(
          en,
          fieldIssues: const [
            RejectedFieldIssue(
              field: 'data.default_attributes',
              code: 'invalid_type',
            ),
          ],
          errorCode: 'validation.failed',
        ),
        [en.syncNeedsFixGenericProblem],
      );
    });

    test('falls back to the generic message for an unmapped field', () {
      expect(
        localizedRejectionMessages(
          en,
          fieldIssues: const [
            RejectedFieldIssue(field: 'data.secret_column', code: 'invalid'),
          ],
          errorCode: 'validation.failed',
        ),
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
            localizedRejectionMessages(
              en,
              fieldIssues: [RejectedFieldIssue(field: field, code: 'invalid')],
              errorCode: 'validation.failed',
            ),
            [en.syncNeedsFixGenericProblem],
            reason: 'field "$field" must not be labelled to the user',
          );
        }
      },
    );

    test('collapses an activity attribute key to the generic details label '
        '(the per-type attribute keys are internal names)', () {
      expect(
        localizedRejectionMessages(
          en,
          fieldIssues: const [
            RejectedFieldIssue(
              field: 'data.attributes.queen_seen',
              code: 'required',
            ),
          ],
          errorCode: 'validation.failed',
        ),
        ['Details: this is required.'],
      );
    });

    test('keeps every mapped issue, de-duplicated and capped', () {
      final messages = localizedRejectionMessages(
        en,
        fieldIssues: const [
          RejectedFieldIssue(field: 'data.name', code: 'required'),
          RejectedFieldIssue(field: 'data.notes', code: 'too_long'),
          // Duplicate of the first — must not be listed twice.
          RejectedFieldIssue(field: 'data.name', code: 'required'),
          RejectedFieldIssue(field: 'data.place_label', code: 'too_long'),
          RejectedFieldIssue(field: 'data.location', code: 'required'),
        ],
        errorCode: 'validation.failed',
      );
      expect(messages, hasLength(maxRejectionMessages));
      expect(messages.first, 'Name: this is required.');
      expect(messages.toSet(), hasLength(messages.length));
    });

    test('drops unmappable issues but keeps the mappable ones', () {
      expect(
        localizedRejectionMessages(
          en,
          fieldIssues: const [
            RejectedFieldIssue(field: 'data.mystery', code: 'invalid'),
            RejectedFieldIssue(field: 'data.title', code: 'too_long'),
          ],
          errorCode: 'validation.failed',
        ),
        ['Title: this text is too long.'],
      );
    });

    test(
      'falls back to the problem-level code when there is no field detail',
      () {
        expect(
          localizedRejectionMessages(
            en,
            fieldIssues: const [],
            errorCode: 'auth.forbidden',
          ),
          [en.syncNeedsFixNotAllowedProblem],
        );
        expect(
          localizedRejectionMessages(
            en,
            fieldIssues: const [],
            errorCode: 'resource.conflict',
          ),
          [en.syncNeedsFixConflictProblem],
        );
      },
    );

    test('falls back to the generic message for an unmapped problem code '
        '(the collateral op of an atomic push carries no field detail)', () {
      expect(
        localizedRejectionMessages(
          en,
          fieldIssues: const [],
          errorCode: 'validation.failed',
        ),
        [en.syncNeedsFixGenericProblem],
      );
      expect(
        localizedRejectionMessages(en, fieldIssues: const [], errorCode: ''),
        [en.syncNeedsFixGenericProblem],
      );
    });
  });

  group('no raw server vocabulary ever reaches the copy', () {
    // Every (field, code) pair the four sync validators can emit
    // (services/{apiaries,activities,journeys,todos}/api/sync.go), asserted
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
            final messages = localizedRejectionMessages(
              l10n,
              fieldIssues: [RejectedFieldIssue(field: field, code: code)],
              errorCode: 'validation.failed',
            );
            expect(messages, isNotEmpty);
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
