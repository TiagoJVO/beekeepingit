import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  testWidgets('probe', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      Semantics(label: 'FieldOne', child: TextField(key: const Key('f1'))),
      Semantics(label: 'FieldTwo', child: TextField(key: const Key('f2'))),
    ]))));
    final node1 = tester.getSemantics(find.byKey(const Key('f1')));
    final node2 = tester.getSemantics(find.byKey(const Key('f2')));
    print(node1.label.isEmpty ? 'NODE1 EMPTY' : node1.label);
    print(node2.label.isEmpty ? 'NODE2 EMPTY' : node2.label);
    handle.dispose();
  });
}
