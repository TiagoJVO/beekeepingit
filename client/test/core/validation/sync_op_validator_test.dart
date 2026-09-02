import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/core/validation/sync_op_validator.dart';
import 'package:beekeepingit_client/core/validation/sync_validation_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the pre-push **validation-parity** pass (FR-OF-2, D-12,
/// sync.md §9, #584): the client re-checks queued ops against the shared
/// description of the rules `services/{apiaries,activities,journeys,todos}/api/
/// sync.go` enforce, so a problem is caught offline instead of arriving as a
/// post-hoc rejection.
///
/// The two properties that matter, in order:
///
///  1. **Never reject what the server accepts.** A false positive costs the
///     beekeeper a valid edit, so every `put`-only rule is exercised against a
///     `patch` too — the #378 class of bug, seen from the client side.
///  2. **Never admit what the server rejects** on a rule the description
///     mirrors. A rule it doesn't mirror is simply the server's to decide.
const _uuid = '018f5f4e-2a3b-7c1d-9e2f-0a1b2c3d4e5f';
const _otherUuid = '018f5f4e-2a3b-7c1d-9e2f-0a1b2c3d4e60';
const _now = '2026-09-01T10:00:00.000Z';

Map<String, dynamic> _op(
  String entityType,
  String op, {
  Map<String, dynamic>? data,
  String id = _uuid,
  Object? updatedAt = _now,
}) => {
  'op': op,
  'entity_type': entityType,
  'id': id,
  'data': data,
  'updated_at': updatedAt,
};

/// The `(field, code)` pairs reported for a single-op batch — what the server
/// would put in its RFC 9457 `errors[]`, minus the `ops[0].` prefix.
Set<(String, String)> _failures(Map<String, dynamic> op) => {
  for (final e in validateSyncOps([op])) (e.field, e.code),
};

void main() {
  group('apiary', () {
    final validPut = <String, dynamic>{
      'name': 'Montargil',
      'notes': null,
      'place_label': null,
      'location_lon': -8.16,
      'location_lat': 39.09,
      'updated_at': _now,
    };

    test('a complete put passes', () {
      expect(_failures(_op(apiaryEntityType, 'put', data: validPut)), isEmpty);
    });

    test('a put without a name is rejected before it is sent', () {
      final data = {...validPut}..remove('name');
      expect(
        _failures(_op(apiaryEntityType, 'put', data: data)),
        contains(('data.name', 'required')),
      );
    });

    test('a put with an empty name is rejected — the server treats "" as '
        'missing here', () {
      final data = {...validPut, 'name': ''};
      expect(
        _failures(_op(apiaryEntityType, 'put', data: data)),
        contains(('data.name', 'required')),
      );
    });

    test('a put with a whitespace-only name PASSES — apiaries does not trim '
        '(unlike todos), so rejecting it would lose a valid edit', () {
      final data = {...validPut, 'name': ' '};
      expect(_failures(_op(apiaryEntityType, 'put', data: data)), isEmpty);
    });

    test('a patch that changes only the notes passes — a patch is a PARTIAL '
        'update, so no put-only required rule may fire (#378)', () {
      expect(
        _failures(
          _op(
            apiaryEntityType,
            'patch',
            data: {'notes': 'Rebuilt the fence', 'updated_at': _now},
          ),
        ),
        isEmpty,
      );
    });

    test('a put without coordinates is rejected (FR-AP-7, #341)', () {
      final data = {...validPut}
        ..remove('location_lon')
        ..remove('location_lat');
      expect(
        _failures(_op(apiaryEntityType, 'put', data: data)),
        contains(('data.location', 'required')),
      );
    });

    test('a patch without coordinates passes — a patch never clears the '
        'location, so the server exempts it', () {
      expect(
        _failures(_op(apiaryEntityType, 'patch', data: {'name': 'Renamed'})),
        isEmpty,
      );
    });

    test('a lone longitude is rejected, naming the missing half', () {
      expect(
        _failures(
          _op(apiaryEntityType, 'patch', data: {'location_lon': -8.16}),
        ),
        contains(('data.location_lat', 'required')),
      );
    });

    test(
      'out-of-range coordinates are rejected once both halves are given',
      () {
        expect(
          _failures(
            _op(
              apiaryEntityType,
              'patch',
              data: {'location_lon': -200.0, 'location_lat': 39.09},
            ),
          ),
          contains(('data.location_lon', 'out_of_range')),
        );
      },
    );

    test('an integer coordinate is range-checked too — SQLite REAL can surface '
        'as an int in the queued payload', () {
      expect(
        _failures(
          _op(
            apiaryEntityType,
            'patch',
            data: {'location_lon': 200, 'location_lat': 39},
          ),
        ),
        contains(('data.location_lon', 'out_of_range')),
      );
    });

    test('name length is measured in UTF-8 BYTES, matching Go len() — an '
        'accented Portuguese name is not silently let through', () {
      // 150 two-byte characters = 300 UTF-8 bytes, but only 150 UTF-16 units.
      final data = {...validPut, 'name': 'á' * 150};
      expect(
        _failures(_op(apiaryEntityType, 'put', data: data)),
        contains(('data.name', 'too_long')),
      );
    });

    test('a 200-byte name passes — the cap is inclusive', () {
      final data = {...validPut, 'name': 'a' * 200};
      expect(_failures(_op(apiaryEntityType, 'put', data: data)), isEmpty);
    });

    test(
      'a delete carries no payload, so no data rule may fire against it',
      () {
        expect(_failures(_op(apiaryEntityType, 'delete', data: null)), isEmpty);
      },
    );

    test('a non-UUID id is rejected', () {
      expect(
        _failures(_op(apiaryEntityType, 'put', data: validPut, id: 'nope')),
        contains(('id', 'invalid')),
      );
    });

    test('a missing updated_at (the LWW comparator) is rejected', () {
      expect(
        _failures(_op(apiaryEntityType, 'delete', data: null, updatedAt: null)),
        contains(('updated_at', 'required')),
      );
    });
  });

  group('apiary_counter', () {
    test('a put with an identity and a value passes', () {
      expect(
        _failures(
          _op(
            apiaryCounterEntityType,
            'put',
            data: {
              'apiary_id': _otherUuid,
              'counter_type': 'hive',
              'value': 12,
              'updated_at': _now,
            },
          ),
        ),
        isEmpty,
      );
    });

    test('a value-less PATCH passes — PowerSync uploads only the columns that '
        'actually changed, and the server treats it as a no-op (#378)', () {
      expect(
        _failures(
          _op(
            apiaryCounterEntityType,
            'patch',
            data: {
              'apiary_id': _otherUuid,
              'counter_type': 'hive',
              'updated_at': _now,
            },
          ),
        ),
        isEmpty,
      );
    });

    test('a value-less PUT is rejected — a fresh row needs a value', () {
      expect(
        _failures(
          _op(
            apiaryCounterEntityType,
            'put',
            data: {'apiary_id': _otherUuid, 'counter_type': 'hive'},
          ),
        ),
        contains(('data.value', 'required')),
      );
    });

    test('a negative value is rejected', () {
      expect(
        _failures(
          _op(
            apiaryCounterEntityType,
            'patch',
            data: {
              'apiary_id': _otherUuid,
              'counter_type': 'hive',
              'value': -1,
            },
          ),
        ),
        contains(('data.value', 'out_of_range')),
      );
    });

    test(
      'an identity-less op is rejected on BOTH op kinds — the server '
      'identifies a counter by (apiary_id, counter_type), never by row id',
      () {
        expect(
          _failures(_op(apiaryCounterEntityType, 'patch', data: {'value': 3})),
          containsAll([
            ('data.apiary_id', 'required'),
            ('data.counter_type', 'required'),
          ]),
        );
      },
    );

    test('a counter has no delete', () {
      expect(
        _failures(_op(apiaryCounterEntityType, 'delete', data: null)),
        contains(('op', 'invalid')),
      );
    });

    test('an unknown counter_type PASSES — the vocabulary is server-owned and '
        'extensible (D-20), so a frozen client list would permanently reject a '
        'value a newer server accepts', () {
      expect(
        _failures(
          _op(
            apiaryCounterEntityType,
            'put',
            data: {
              'apiary_id': _otherUuid,
              'counter_type': 'nucleus_from_a_future_release',
              'value': 1,
            },
          ),
        ),
        isEmpty,
      );
    });
  });

  group('stock_declaration (#298, FR-AP-10)', () {
    test('a complete put passes', () {
      expect(
        _failures(
          _op(
            stockDeclarationEntityType,
            'put',
            data: {
              'dgav_registration_number': 'PT-1234',
              'declared_on': '2026-08-31',
              'total_hive_count': 42,
              'breakdown': <dynamic>[
                {'apiary_id': _otherUuid, 'hive_count': 42},
              ],
              'notes': null,
              'updated_at': _now,
            },
          ),
        ),
        isEmpty,
      );
    });

    test(
      'a put without the two facts that make it a declaration is rejected',
      () {
        expect(
          _failures(
            _op(stockDeclarationEntityType, 'put', data: {'notes': 'draft'}),
          ),
          containsAll([
            ('data.declared_on', 'required'),
            ('data.total_hive_count', 'required'),
          ]),
        );
      },
    );

    test('the same partial payload as a PATCH passes (#378)', () {
      expect(
        _failures(
          _op(
            stockDeclarationEntityType,
            'patch',
            data: {'notes': 'Corrected'},
          ),
        ),
        isEmpty,
      );
    });

    test('a mis-entered declaration can be deleted — unlike a counter, it has '
        'its own lifecycle', () {
      expect(
        _failures(_op(stockDeclarationEntityType, 'delete', data: null)),
        isEmpty,
      );
    });

    test('a malformed declared_on is rejected', () {
      expect(
        _failures(
          _op(
            stockDeclarationEntityType,
            'patch',
            data: {'declared_on': '31/08/2026'},
          ),
        ),
        contains(('data.declared_on', 'invalid')),
      );
    });

    test('a negative total is rejected', () {
      expect(
        _failures(
          _op(
            stockDeclarationEntityType,
            'patch',
            data: {'total_hive_count': -1},
          ),
        ),
        contains(('data.total_hive_count', 'out_of_range')),
      );
    });

    test('the breakdown ARRAY passes untouched — it is server-only, and a '
        'jsonObject rule here would reject every declaration ever written', () {
      expect(
        _failures(
          _op(
            stockDeclarationEntityType,
            'patch',
            data: {
              'breakdown': <dynamic>[
                {'apiary_id': _otherUuid, 'hive_count': 3},
              ],
            },
          ),
        ),
        isEmpty,
      );
    });
  });

  group('activity', () {
    test('a complete put passes', () {
      expect(
        _failures(
          _op(
            activityEntityType,
            'put',
            data: {
              'apiary_id': _otherUuid,
              'type': 'harvest',
              'occurred_at': '2026-07-14',
              'attributes': <String, dynamic>{'honey_supers': 4},
              'journey_id': null,
              'updated_at': _now,
            },
          ),
        ),
        isEmpty,
      );
    });

    test('a put missing apiary_id, type and occurred_at reports all three', () {
      expect(
        _failures(_op(activityEntityType, 'put', data: {'updated_at': _now})),
        containsAll([
          ('data.apiary_id', 'required'),
          ('data.type', 'required'),
          ('data.occurred_at', 'required'),
        ]),
      );
    });

    test('the same partial payload as a PATCH passes (#378)', () {
      expect(
        _failures(_op(activityEntityType, 'patch', data: {'updated_at': _now})),
        isEmpty,
      );
    });

    test('a non-calendar occurred_at is rejected — Go time.Parse validates the '
        'day-of-month, and DateTime.parse would roll it over', () {
      expect(
        _failures(
          _op(activityEntityType, 'patch', data: {'occurred_at': '2026-02-30'}),
        ),
        contains(('data.occurred_at', 'invalid')),
      );
    });

    test('a non-ISO occurred_at is rejected', () {
      expect(
        _failures(
          _op(activityEntityType, 'patch', data: {'occurred_at': '14/07/2026'}),
        ),
        contains(('data.occurred_at', 'invalid')),
      );
    });

    test('attributes still carried as a JSON STRING is rejected — the exact '
        'shape that reached production as a 422 (#39)', () {
      expect(
        _failures(
          _op(
            activityEntityType,
            'patch',
            data: {'attributes': '{"honey_supers":4}'},
          ),
        ),
        contains(('data.attributes', 'invalid')),
      );
    });

    test('an explicitly null attributes is rejected — the server decodes it '
        'into a RawMessage, where present-but-null is not an object', () {
      expect(
        _failures(_op(activityEntityType, 'patch', data: {'attributes': null})),
        contains(('data.attributes', 'invalid')),
      );
    });

    test('an absent attributes passes', () {
      expect(
        _failures(_op(activityEntityType, 'patch', data: {'type': 'harvest'})),
        isEmpty,
      );
    });

    test('an unknown activity type PASSES — the per-type attribute schema is '
        'the server\'s to enforce, not something the device mirrors', () {
      expect(
        _failures(
          _op(activityEntityType, 'patch', data: {'type': 'something_new'}),
        ),
        isEmpty,
      );
    });
  });

  group('journey', () {
    test('a status-only close PATCH passes — the concrete #378 case', () {
      expect(
        _failures(
          _op(
            journeyEntityType,
            'patch',
            data: {'status': 'closed', 'updated_at': _now},
          ),
        ),
        isEmpty,
      );
    });

    test('a put without a name or main activity type is rejected', () {
      expect(
        _failures(_op(journeyEntityType, 'put', data: {'updated_at': _now})),
        containsAll([
          ('data.name', 'required'),
          ('data.main_activity_type', 'required'),
        ]),
      );
    });

    test('default_attributes still carried as a JSON STRING is rejected — the '
        'shape that reached production as a 422 (#385)', () {
      expect(
        _failures(
          _op(
            journeyEntityType,
            'patch',
            data: {'default_attributes': '{"feed_type":"syrup"}'},
          ),
        ),
        contains(('data.default_attributes', 'invalid')),
      );
    });

    test('an oversized default_attributes bag is rejected on the byte cap', () {
      expect(
        _failures(
          _op(
            journeyEntityType,
            'patch',
            data: {
              'default_attributes': <String, dynamic>{'note': 'x' * 9000},
            },
          ),
        ),
        contains(('data.default_attributes', 'too_long')),
      );
    });

    test('a decoded default_attributes object passes', () {
      expect(
        _failures(
          _op(
            journeyEntityType,
            'patch',
            data: {
              'default_attributes': <String, dynamic>{'feed_type': 'syrup'},
            },
          ),
        ),
        isEmpty,
      );
    });
  });

  group('journey_plan_item', () {
    test('a put naming both ids passes', () {
      expect(
        _failures(
          _op(
            journeyPlanItemEntityType,
            'put',
            data: {'journey_id': _otherUuid, 'apiary_id': _uuid},
          ),
        ),
        isEmpty,
      );
    });

    test('a put missing the journey it belongs to is rejected', () {
      expect(
        _failures(
          _op(journeyPlanItemEntityType, 'put', data: {'apiary_id': _uuid}),
        ),
        contains(('data.journey_id', 'required')),
      );
    });

    test('removing an apiary from a plan (a delete) passes', () {
      expect(
        _failures(_op(journeyPlanItemEntityType, 'delete', data: null)),
        isEmpty,
      );
    });

    test('a plan item has no patch', () {
      expect(
        _failures(
          _op(
            journeyPlanItemEntityType,
            'patch',
            data: {'journey_id': _otherUuid, 'apiary_id': _uuid},
          ),
        ),
        contains(('op', 'invalid')),
      );
    });
  });

  group('todo', () {
    test('a complete put passes', () {
      expect(
        _failures(
          _op(
            todoEntityType,
            'put',
            data: {
              'title': 'Check the feeders',
              'description': null,
              'due_date': '2026-09-30',
              'priority': 'high',
              'status': 'open',
              'completed_at': null,
              'assignee_id': null,
              'apiary_id': _otherUuid,
              'updated_at': _now,
            },
          ),
        ),
        isEmpty,
      );
    });

    test('a whitespace-only title on a put is rejected — todos DOES trim, '
        'unlike apiaries', () {
      expect(
        _failures(
          _op(todoEntityType, 'put', data: {'title': '   ', 'priority': 'low'}),
        ),
        contains(('data.title', 'required')),
      );
    });

    test('a put without a priority is rejected', () {
      expect(
        _failures(_op(todoEntityType, 'put', data: {'title': 'Feed'})),
        contains(('data.priority', 'required')),
      );
    });

    test('the complete/reopen PATCH — status + completed_at only — passes', () {
      expect(
        _failures(
          _op(
            todoEntityType,
            'patch',
            data: {'status': 'done', 'completed_at': _now, 'updated_at': _now},
          ),
        ),
        isEmpty,
      );
    });

    test('a reopen that nulls completed_at passes', () {
      expect(
        _failures(
          _op(
            todoEntityType,
            'patch',
            data: {'status': 'open', 'completed_at': null},
          ),
        ),
        isEmpty,
      );
    });

    test('empty optional strings are treated as absent, exactly as the server '
        'does, so a cleared field is never mistaken for a malformed one', () {
      expect(
        _failures(
          _op(
            todoEntityType,
            'patch',
            data: {
              'due_date': '',
              'completed_at': '',
              'assignee_id': '',
              'apiary_id': '',
            },
          ),
        ),
        isEmpty,
      );
    });

    test('a completed_at without a timezone offset is rejected — Go parses '
        'RFC3339Nano strictly where DateTime.parse would not', () {
      expect(
        _failures(
          _op(
            todoEntityType,
            'patch',
            data: {'completed_at': '2026-09-01 10:00:00'},
          ),
        ),
        contains(('data.completed_at', 'invalid')),
      );
    });

    test('a malformed assignee_id is rejected', () {
      expect(
        _failures(
          _op(todoEntityType, 'patch', data: {'assignee_id': 'not-a-uuid'}),
        ),
        contains(('data.assignee_id', 'invalid')),
      );
    });

    test('an assignee_id the org does not contain PASSES — ownership needs '
        'server state the device does not have offline', () {
      expect(
        _failures(
          _op(todoEntityType, 'patch', data: {'assignee_id': _otherUuid}),
        ),
        isEmpty,
      );
    });
  });

  group('the batch as a whole', () {
    test('an unknown entity type is passed through unvalidated — deferring to '
        'the authoritative server is always the safe direction', () {
      expect(_failures(_op('something_new', 'put', data: const {})), isEmpty);
    });

    test('failures carry the index of the op they belong to, so the connector '
        'can attribute them exactly as it does a server rejection', () {
      final errors = validateSyncOps([
        _op(apiaryEntityType, 'patch', data: {'name': 'Fine'}),
        _op(todoEntityType, 'put', data: {'title': ''}),
      ]);
      expect(errors, isNotEmpty);
      expect(errors.every((e) => e.opIndex == 1), isTrue);
    });

    test('an uppercase URN-prefixed id passes — Go\'s uuid.Parse compares that '
        'prefix case-insensitively, so rejecting it would be the one direction '
        'this check must never take', () {
      expect(
        _failures(
          _op(apiaryEntityType, 'delete', data: null, id: 'URN:UUID:$_uuid'),
        ),
        isEmpty,
      );
    });

    test('validation FAILS OPEN: an unusable rule set reports no errors rather '
        'than throwing, because a throw would escape uploadData and PowerSync '
        'would retry it forever, stalling every pending write (D-12: the '
        'server is authoritative, this pass is only an optimization)', () {
      expect(
        validateSyncOps([
          _op(todoEntityType, 'put', data: {'title': ''}),
        ], rules: _BrokenRules()),
        isEmpty,
      );
    });

    test('a fully valid batch produces no errors at all', () {
      expect(
        validateSyncOps([
          _op(apiaryEntityType, 'delete', data: null),
          _op(
            todoEntityType,
            'patch',
            data: {'status': 'done', 'completed_at': _now},
          ),
        ]),
        isEmpty,
      );
    });
  });
}

/// A rule set whose entity lookup blows up — standing in for any way the shared
/// description could become unusable at runtime. Used to pin the fail-open
/// contract without needing a malformed embedded artifact.
class _BrokenRules implements SyncValidationRules {
  @override
  SyncEnvelopeRules get envelope => throw UnimplementedError();

  @override
  Map<String, SyncEntityRules> get entities =>
      throw StateError('rule set unusable');
}
