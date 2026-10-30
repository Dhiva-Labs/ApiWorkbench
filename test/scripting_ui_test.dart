import 'package:api_workbench/models/models.dart';
import 'package:api_workbench/services/scripting/script_engine.dart';
import 'package:api_workbench/state/app_state.dart';
import 'package:api_workbench/theme.dart';
import 'package:api_workbench/ui/request/scripts_tab.dart';
import 'package:api_workbench/ui/response/visualize_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/state_harness.dart';
import 'support/test_fonts.dart';

void main() {
  setUpAll(loadRoboto);

  Future<void> size(WidgetTester tester, Size s) async {
    tester.view.physicalSize = s;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('ScriptsTab', () {
    late StateHarness h;

    Future<RequestModel> pump(
      WidgetTester tester, {
      RequestModel? request,
      void Function()? onChanged,
    }) async {
      final req = request ?? RequestModel();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: h.state,
          child: MaterialApp(
            theme: buildTheme(),
            home: Scaffold(
              body: ScriptsTab(request: req, onChanged: onChanged ?? () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return req;
    }

    TextField field(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField));

    testWidgets('edits each phase and inserts snippets at a phone width', (
      tester,
    ) async {
      await size(tester, const Size(320, 640));
      h = StateHarness();
      await h.setUp(tester);
      var changes = 0;
      final req = await pump(
        tester,
        request: RequestModel(testScript: 'old'),
        onChanged: () => changes++,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Pre-request'), findsOneWidget);
      expect(find.text('Post-response •'), findsOneWidget);
      expect(find.textContaining('no script engine'), findsNothing);

      await tester.enterText(find.byType(TextField), 'let a = 1;');
      expect(req.preRequestScript, 'let a = 1;');
      expect(changes, 1);

      await tester.tap(find.text('Post-response •'));
      await tester.pumpAndSettle();
      expect(field(tester).controller!.text, 'old');

      await tester.tap(find.byKey(const ValueKey('script-snippets')));
      await tester.pumpAndSettle();
      expect(find.text('Skip this request'), findsNothing, reason: 'pre only');
      await tester.tap(find.text('Status code is 200'));
      await tester.pumpAndSettle();
      expect(req.testScript, startsWith('old\n'));
      expect(req.testScript, contains('pm.response.to.have.status(200);'));
      expect(req.preRequestScript, 'let a = 1;');
      expect(tester.takeException(), isNull);
      await h.tearDown(tester);
    });

    testWidgets('Tab indents, Shift+Tab outdents, Enter keeps indentation', (
      tester,
    ) async {
      await size(tester, const Size(800, 600));
      h = StateHarness();
      await h.setUp(tester);
      final req = await pump(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final c = field(tester).controller!;

      c.value = const TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 0),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(c.text, '  a');
      expect(req.preRequestScript, '  a');
      expect(c.selection, const TextSelection.collapsed(offset: 2));

      // Every line of a multi-line selection.
      c.value = const TextEditingValue(
        text: 'x\ny\nz',
        selection: TextSelection(baseOffset: 0, extentOffset: 3),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(c.text, '  x\n  y\nz');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();
      expect(c.text, 'x\ny\nz');

      // Typing Enter after an opening brace indents one level.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  if (x) {',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '  if (x) {\n',
          selection: TextSelection.collapsed(offset: 11),
        ),
      );
      await tester.pump();
      expect(c.text, '  if (x) {\n    ');
      expect(req.preRequestScript, '  if (x) {\n    ');
      await h.tearDown(tester);
    });

    testWidgets('long scripts scroll and wrap without overflow', (
      tester,
    ) async {
      await size(tester, const Size(320, 480));
      h = StateHarness();
      await h.setUp(tester);
      await pump(
        tester,
        request: RequestModel(
          preRequestScript: [
            for (var i = 0; i < 200; i++)
              'pm.environment.set("variable_number_$i", "a fairly long value that wraps on a phone");',
          ].join('\n'),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -2000),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await h.tearDown(tester);
    });

    testWidgets('says when scripts are turned off', (tester) async {
      await size(tester, const Size(400, 600));
      h = StateHarness();
      await h.setUp(tester);
      h.state.updateSettings(AppSettings(scriptsEnabled: false));
      await pump(tester);
      expect(find.textContaining('turned off in Settings'), findsOneWidget);
      h.state.updateSettings(AppSettings());
      await h.tearDown(tester);
    });
  });

  group('VisualizeView', () {
    const html =
        '<h2>Users</h2><table><tr><th>Name</th></tr>'
        '<tr><td>Ada</td></tr></table><script>pm.getData(() => {})</script>';

    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(
          body: VisualizeView(output: VisualizerOutput(html)),
        ),
      ),
    );

    testWidgets('renders the HTML statically and shows its source', (
      tester,
    ) async {
      await size(tester, const Size(320, 600));
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('Users', findRichText: true), findsWidgets);
      expect(find.textContaining('Ada', findRichText: true), findsWidgets);
      expect(
        find.textContaining('pm.getData', findRichText: true),
        findsNothing,
      );
      expect(find.text('Scripts in the template are not run'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('HTML'));
      await tester.pumpAndSettle();
      expect(find.text(html), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
