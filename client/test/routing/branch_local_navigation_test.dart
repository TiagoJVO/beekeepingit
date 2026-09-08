import 'package:beekeepingit_client/routing/branch_local_navigation.dart';
import 'package:flutter_test/flutter_test.dart';

/// #666 (FR-UX-1, FR-UX-2, D-35) — the branch-local rule itself, unit-tested.
///
/// `home_row_back_test.dart` drives the three Home rows through the real
/// router and the real shell, which is what proves the user-visible
/// behaviour. This file pins the rule's edges, which a widget test can only
/// reach by inventing screens for them: the paths that must NOT be read as a
/// Home page, the journey stack that is not a journey (`/journeys/new`), and
/// where a record that has been deleted under the user sends them.
void main() {
  group('isInHomeBranch', () {
    test('is true for Home itself and for pages nested under it', () {
      expect(isInHomeBranch('/home'), isTrue);
      expect(isInHomeBranch('/home/todos/t1'), isTrue);
      expect(isInHomeBranch('/home/not-found'), isTrue);
    });

    test('is false for another branch, and for a path that merely starts '
        'with the same letters', () {
      expect(isInHomeBranch('/todos/t1'), isFalse);
      expect(isInHomeBranch('/journeys'), isFalse);
      // The reason the check is not a bare `startsWith('/home')`: a future
      // top-level route would otherwise be read as a page of this branch.
      expect(isInHomeBranch('/homestead'), isFalse);
    });
  });

  group('a record previewed on Home opens in Home\'s own stack', () {
    test('todo', () {
      expect(todoDetailLocation(from: '/home', todoId: 't1'), '/home/todos/t1');
      expect(todoDetailLocation(from: '/todos', todoId: 't1'), '/todos/t1');
    });

    test('journey', () {
      expect(
        journeyDetailLocation(from: '/home', journeyId: 'j1'),
        '/home/journeys/j1',
      );
      expect(
        journeyDetailLocation(from: '/journeys', journeyId: 'j1'),
        '/journeys/j1',
      );
    });

    test('apiary', () {
      expect(
        apiaryDetailLocation(from: '/home', apiaryId: 'a1'),
        '/home/apiaries/a1',
      );
      expect(
        apiaryDetailLocation(from: '/apiaries', apiaryId: 'a1'),
        '/apiaries/a1',
      );
    });
  });

  group('activityDetailLocation', () {
    test('inside a journey\'s stack, stays in the journeys branch (#384)', () {
      expect(
        activityDetailLocation(
          from: '/journeys/j1',
          apiaryId: 'a1',
          activityId: 'ac1',
        ),
        '/journeys/j1/activities/ac1?apiaryId=a1',
      );
    });

    test('anywhere else, the apiaries-branch route that owns edit/delete', () {
      for (final from in ['/activities', '/apiaries/a1', '/journeys']) {
        expect(
          activityDetailLocation(from: from, apiaryId: 'a1', activityId: 'ac1'),
          '/apiaries/a1/activities/ac1',
          reason: '$from is not inside a journey\'s own stack',
        );
      }
    });

    test('a journey opened FROM HOME keeps its activity rows in Home\'s '
        'stack', () {
      // The case the first version of this rule missed: `/home/journeys/j1`
      // is that journey's stack too, so an activity row on it must not fall
      // through to the apiaries branch — which is exactly the hand-off #384
      // exists to prevent, reached by another door.
      expect(journeyBranchIdOf('/home/journeys/j1'), 'j1');
      expect(
        activityDetailLocation(
          from: '/home/journeys/j1',
          apiaryId: 'a1',
          activityId: 'ac1',
        ),
        '/home/journeys/j1/activities/ac1?apiaryId=a1',
      );
    });

    test('an apiary opened FROM HOME keeps its activity rows there too', () {
      expect(
        activityDetailLocation(
          from: '/home/apiaries/a1',
          apiaryId: 'a1',
          activityId: 'ac1',
        ),
        '/home/apiaries/a1/activities/ac1',
      );
    });

    test('the journey CREATE form is not a journey stack', () {
      // `/journeys/new` matches the shape of `/journeys/:id` but `new` is a
      // route segment, not an id — reading it as one would build
      // `/journeys/new/activities/...`, which matches nothing.
      expect(journeyBranchIdOf('/journeys/new'), isNull);
      expect(
        activityDetailLocation(
          from: '/journeys/new',
          apiaryId: 'a1',
          activityId: 'ac1',
        ),
        '/apiaries/a1/activities/ac1',
      );
    });
  });

  group('recordGoneLocation', () {
    test('returns to Home when the record was opened from Home', () {
      expect(
        recordGoneLocation(from: '/home/todos/t1', ownerList: '/todos'),
        '/home',
      );
    });

    test('returns to the entity\'s own list everywhere else', () {
      expect(
        recordGoneLocation(from: '/todos/t1', ownerList: '/todos'),
        '/todos',
      );
      expect(
        recordGoneLocation(from: '/apiaries/a1', ownerList: '/apiaries'),
        '/apiaries',
      );
    });
  });
}
