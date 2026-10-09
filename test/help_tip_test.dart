import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:api_workbench/ui/help_tip.dart';

void main() {
  tearDown(() => hoverHelpEnabled.value = true);

  Widget host() => const MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          HelpTip('Explains the field.', title: 'Field', example: '42'),
          HelpHover(
            'Opens things.',
            title: 'Rail item',
            essential: true,
            child: Text('rail'),
          ),
          HelpHover('Just a badge.', title: 'Badge', child: Text('badge')),
        ],
      ),
    ),
  );

  testWidgets('hover help shows cards and can be turned off', (tester) async {
    await tester.pumpWidget(host());
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    expect(find.byType(Tooltip), findsNWidgets(3));
    final card = tester.widget<Tooltip>(find.byType(Tooltip).first);
    expect(card.richMessage!.toPlainText(), contains('Field'));
    expect(card.richMessage!.toPlainText(), contains('42'));

    hoverHelpEnabled.value = false;
    await tester.pump();
    expect(find.byIcon(Icons.help_outline), findsNothing);
    // Only the essential rail item keeps a title-only tooltip.
    final left = tester.widgetList<Tooltip>(find.byType(Tooltip)).toList();
    expect(left.map((t) => t.message), ['Rail item']);
    expect(find.text('badge'), findsOneWidget);

    hoverHelpEnabled.value = true;
    await tester.pump();
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
  });
}
