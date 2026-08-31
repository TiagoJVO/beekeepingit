import io

# ---- router tests ----
p = 'client/test/app_router_test.dart'
s = io.open(p, encoding='utf-8').read()

anchor = '''  testWidgets(
    'an authenticated, fully-onboarded user lands on the Tasks home (#427, ' '''

new_tests = '''  // --- the second onboarding exit (#365 live testing, FR-ONB-2/D-3) -------
  //
  // The gate was WIDENED, not opened: /organization/new stays the default
  // landing (pinned by the test above, deliberately left unchanged), and
  // everything outside the two permitted onboarding destinations is still
  // bounced.

  testWidgets(
    'a profile-complete user with no organization may sit on '
    '/organization/waiting',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(profileComplete: true, hasOrganization: false),
      );
      await tester.pumpAndSettle();

      // Reachable from the create form, which is where the router lands them.
      await tester.tap(
        find.byKey(const Key('organization-join-instead-button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('organization-waiting-check-button')),
        findsOneWidget,
      );
      // Not bounced back to the create form.
      expect(find.byKey(const Key('organization-name-field')), findsNothing);
    },
  );

  testWidgets(
    '/organization/members is STILL bounced pre-onboarding — the permitted '
    'set is two explicit routes, not a /organization/* prefix',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(profileComplete: true, hasOrganization: false),
      );
      await tester.pumpAndSettle();

      final router = _routerOf(tester);
      router.go('/organization/members');
      await tester.pumpAndSettle();

      // A prefix match would have let this through, and no other test would
      // have noticed — a members screen before any membership exists.
      expect(find.byKey(const Key('organization-name-field')), findsOneWidget);
    },
  );

'''

assert anchor in s, 'router anchor missing'
s = s.replace(anchor, new_tests + anchor, 1)

# A tiny helper to reach the router from a pumped app.
helper = '''/// Reaches the live GoRouter of a pumped [BeekeepingitApp], so a test can
/// navigate to a route the UI does not offer a button for.
GoRouter _routerOf(WidgetTester tester) {
  final context = tester.element(find.byType(Navigator).first);
  return GoRouter.of(context);
}

Widget _buildApp({required bool profileComplete, bool hasOrganization = true}) {'''
s = s.replace(
    'Widget _buildApp({required bool profileComplete, bool hasOrganization = true}) {',
    helper, 1)

if "import 'package:go_router/go_router.dart';" not in s:
    s = s.replace("import 'package:flutter_test/flutter_test.dart';",
                  "import 'package:flutter_test/flutter_test.dart';\n"
                  "import 'package:go_router/go_router.dart';", 1)

io.open(p, 'w', encoding='utf-8').write(s)
print('router tests added')

# ---- organization screen tests ----
p = 'client/test/organization_screen_test.dart'
s = io.open(p, encoding='utf-8').read()
assert 'void main() {' in s
s = s.replace('void main() {', '''void main() {
  testWidgets(
    'the create form warns that creating an organization is a one-way choice',
    (tester) async {
      await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('organization-create-blocks-invite-warning')),
        findsOneWidget,
      );
    },
  );

''', 1)
io.open(p, 'w', encoding='utf-8').write(s)
print('organization screen test added')
