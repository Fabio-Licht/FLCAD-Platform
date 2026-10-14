import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/commands/command_presentation_catalog.dart';
import 'package:flcad_mobile/app/desktop/activity_navigation.dart';

void main() {
  test('groups all eleven existing modules exactly once', () {
    final grouped = ActivityNavigation.groups
        .expand((group) => group.modules)
        .toList(growable: false);

    expect(grouped.toSet().length, 11);
    expect(grouped.toSet(), orderedEquals(ActivityNavigation.modules.toSet()));
  });

  test('group and labels are presentation-only and stable', () {
    expect(ActivityNavigation.groupFor('Sketch'), 'Sketch');
    expect(ActivityNavigation.groupFor('Transform'), 'Alinhar');
    expect(
      ActivityNavigation.labelFor('Reverse Engineering'),
      'Engenharia reversa',
    );
    expect(ActivityNavigation.labelFor('Sections'), 'Seções');
    expect(ActivityNavigation.isPlaceholder('AI Engineering'), isTrue);
    expect(ActivityNavigation.isPlaceholder('Curves'), isTrue);
    expect(ActivityNavigation.isPlaceholder('Sketch'), isFalse);
  });

  test(
    'existing workspace search remains the separate command entry point',
    () {
      final results = CommandPresentationCatalog.search('superfície');

      expect(results.any((entry) => entry.id == 'workspace.surfaces'), isTrue);
    },
  );
}
