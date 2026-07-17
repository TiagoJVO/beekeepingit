import 'dart:convert';

import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Resolves to no organization, for exercising [MembersController]'s
/// no-organization guard without a real ApiClient/network call — same
/// convention as account_screen_test.dart's `_FixedOrganizationController`.
class _NullOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => null;
}

ProviderContainer _containerWithMockClient(
  Future<http.Response> Function(http.Request) handler,
) {
  final mockClient = MockClient((request) async => handler(request));
  return ProviderContainer(
    overrides: [
      // Swaps in a MockClient (package:http/testing.dart) instead of a real
      // http.Client — ApiClient itself is unchanged, this is the same
      // dependency-injection seam AuthController's own tests use.
      apiClientProvider.overrideWith(
        (ref) => ApiClient(ref, httpClient: mockClient),
      ),
    ],
  );
}

void main() {
  group('MembersRepository pagination (MEDIUM finding: the server '
      'implements cursor pagination — limit/cursor/page.next_cursor — but '
      'the client previously ignored it, silently hiding data past 50 '
      'entries)', () {
    test(
      'listMembers() forwards cursor/limit and parses page.next_cursor',
      () async {
        Uri? requestedUri;
        final container = _containerWithMockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            jsonEncode({
              'data': [
                {'user_id': 'u1', 'role': 'admin', 'status': 'active'},
              ],
              'page': {'next_cursor': 'cursor-2', 'limit': 1},
            }),
            200,
          );
        });
        addTearDown(container.dispose);
        final repo = container.read(membersRepositoryProvider);

        final page = await repo.listMembers(
          'org-1',
          cursor: 'cursor-1',
          limit: 1,
        );

        expect(requestedUri, isNotNull);
        expect(requestedUri!.path, '/v1/organizations/org-1/members');
        expect(requestedUri!.queryParameters['cursor'], 'cursor-1');
        expect(requestedUri!.queryParameters['limit'], '1');
        expect(page.items, hasLength(1));
        expect(page.items.single.userId, 'u1');
        expect(page.nextCursor, 'cursor-2');
      },
    );

    test('listMembers() omits cursor/limit query params when not given, and '
        'a null next_cursor means no further page', () async {
      Uri? requestedUri;
      final container = _containerWithMockClient((request) async {
        requestedUri = request.url;
        return http.Response(
          jsonEncode({
            'data': [],
            'page': {'next_cursor': null, 'limit': 50},
          }),
          200,
        );
      });
      addTearDown(container.dispose);
      final repo = container.read(membersRepositoryProvider);

      final page = await repo.listMembers('org-1');

      expect(requestedUri!.queryParameters, isEmpty);
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
    });

    test(
      'listInvitations() forwards cursor/limit and parses page.next_cursor',
      () async {
        Uri? requestedUri;
        final container = _containerWithMockClient((request) async {
          requestedUri = request.url;
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'inv-1',
                  'email': 'a@example.com',
                  'role': 'user',
                  'status': 'pending',
                  'created_at': '2026-01-01T00:00:00Z',
                },
              ],
              'page': {'next_cursor': 'cursor-9', 'limit': 1},
            }),
            200,
          );
        });
        addTearDown(container.dispose);
        final repo = container.read(membersRepositoryProvider);

        final page = await repo.listInvitations(
          'org-1',
          cursor: 'cursor-8',
          limit: 1,
        );

        expect(requestedUri!.path, '/v1/organizations/org-1/invitations');
        expect(requestedUri!.queryParameters['cursor'], 'cursor-8');
        expect(requestedUri!.queryParameters['limit'], '1');
        expect(page.items, hasLength(1));
        expect(page.items.single.email, 'a@example.com');
        expect(page.nextCursor, 'cursor-9');
      },
    );
  });

  group('MembersController with no organization (MEDIUM finding: invite()/'
      'revokeInvitation() used to silently return success instead of '
      'surfacing the missing-org case)', () {
    test('invite() throws StateError instead of silently no-op-ing', () async {
      final container = ProviderContainer(
        overrides: [
          organizationProvider.overrideWith(_NullOrganizationController.new),
        ],
      );
      addTearDown(container.dispose);
      await container.read(organizationProvider.future);

      await expectLater(
        container.read(membersProvider.notifier).invite(email: 'a@b.com'),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'revokeInvitation() throws StateError instead of silently no-op-ing',
      () async {
        final container = ProviderContainer(
          overrides: [
            organizationProvider.overrideWith(_NullOrganizationController.new),
          ],
        );
        addTearDown(container.dispose);
        await container.read(organizationProvider.future);

        await expectLater(
          container.read(membersProvider.notifier).revokeInvitation('inv-1'),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('listMemberNames() (#44 — non-admin-safe roster for attribution)', () {
    test('pages through every result and builds a user_id -> name map, '
        'skipping empty names (incomplete/removed profiles)', () async {
      final paths = <String>[];
      final container = _containerWithMockClient((request) async {
        paths.add(request.url.toString());
        final cursor = request.url.queryParameters['cursor'];
        if (cursor == null) {
          return http.Response(
            jsonEncode({
              'data': [
                {'user_id': 'u1', 'name': 'Ana'},
                {'user_id': 'u2', 'name': ''}, // incomplete profile
              ],
              'page': {'next_cursor': 'c2', 'limit': 2},
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'data': [
              {'user_id': 'u3', 'name': 'Bruno'},
            ],
            'page': {'next_cursor': null, 'limit': 2},
          }),
          200,
        );
      });
      addTearDown(container.dispose);
      final repo = container.read(membersRepositoryProvider);

      final names = await repo.listMemberNames('org-1');

      expect(names, {'u1': 'Ana', 'u3': 'Bruno'});
      expect(names.containsKey('u2'), isFalse); // empty name omitted
      expect(paths.first, contains('/v1/organizations/org-1/members/names'));
      expect(paths, hasLength(2)); // followed the cursor to the 2nd page
    });
  });
}
