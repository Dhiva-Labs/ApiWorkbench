import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/script_consent_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/state_harness.dart';

void main() {
  final h = StateHarness();

  Future<void> open(
    WidgetTester tester,
    AppState state,
    Future<void> Function(BuildContext) show,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: opener(buildTheme(), show),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the script question returns what the user picks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await h.setUp(tester);
    final c = CollectionModel(name: 'Shop API', untrusted: true);
    final answers = <ScriptConsent>[];
    for (final button in [
      'Allow scripts',
      'Run without scripts',
      'Cancel',
      null, // tapping outside
    ]) {
      await open(tester, h.state, (ctx) async {
        answers.add(await showScriptConsentDialog(ctx, c, 4));
      });
      expect(find.text('Run scripts from "Shop API"?'), findsOneWidget);
      expect(find.textContaining('has 4 scripts'), findsOneWidget);
      if (button == null) {
        await tester.tapAt(const Offset(5, 5));
      } else {
        await tester.tap(find.text(button));
      }
      await tester.pumpAndSettle();
    }
    expect(answers, [
      ScriptConsent.allow,
      ScriptConsent.skipScripts,
      ScriptConsent.cancel,
      ScriptConsent.cancel,
    ]);
    expect(tester.takeException(), isNull);
    await h.tearDown(tester);
  });
}
