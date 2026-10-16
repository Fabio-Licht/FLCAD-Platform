import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flcad_mobile/app/desktop/desktop_application.dart';

void main() {
  testWidgets(
    'viewport and Sketch tool window coexist under finite constraints',
    (tester) async {
      final viewportKey = GlobalKey();
      final panelKey = GlobalKey();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 1200,
            height: 720,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(key: viewportKey, color: Colors.blueGrey),
                ),
                buildProfessionalToolWindowForTesting(
                  title: 'Sketch',
                  panelKey: panelKey,
                  child: const SizedBox(
                    height: 1600,
                    child: Text('Sketch controls'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final viewport = tester.getRect(find.byKey(viewportKey));
      final panel = tester.getRect(find.byKey(panelKey));
      expect(viewport.size, const Size(800, 600));
      expect(panel.width, lessThan(viewport.width));
      expect(panel.height, lessThan(viewport.height));
      expect(panel.left, greaterThanOrEqualTo(viewport.left));
      expect(panel.top, greaterThanOrEqualTo(viewport.top));
      expect(panel.right, lessThanOrEqualTo(viewport.right));
      expect(panel.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(find.text('Sketch controls'), findsOneWidget);
    },
  );
}
