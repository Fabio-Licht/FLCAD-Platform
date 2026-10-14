import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/commands/command_palette.dart';
import 'package:flcad_mobile/app/commands/command_presentation_catalog.dart';

void main() {
  test('palette policy only allows existing zero-parameter route types', () {
    expect(
      CommandPalettePolicy.canExecute(
        CommandPresentationCatalog.byId('workspace.sketch'),
      ),
      isTrue,
    );
    expect(
      CommandPalettePolicy.canExecute(
        CommandPresentationCatalog.byId('project.new'),
      ),
      isFalse,
    );
    expect(
      CommandPalettePolicy.canExecute(
        CommandPresentationCatalog.byId('reverse.sketch.dimension.edit'),
      ),
      isFalse,
    );
    expect(
      CommandPalettePolicy.canExecute(
        CommandPresentationCatalog.byId('sketch.3d'),
      ),
      isFalse,
    );
  });
}
