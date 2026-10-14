import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/commands/command_presentation_catalog.dart';

void main() {
  test('catalog ids are unique and every entry has presentation metadata', () {
    final entries = CommandPresentationCatalog.entries;
    final ids = entries.map((entry) => entry.id).toSet();

    expect(ids.length, entries.length);
    for (final entry in entries) {
      expect(entry.id, isNotEmpty);
      expect(entry.name, isNotEmpty);
      expect(entry.name.split(' ').length, lessThanOrEqualTo(5));
      expect(entry.description, isNotEmpty);
      expect(entry.recommendedLocation, isNotEmpty);
    }
  });

  test(
    'catalog separates executable commands, actions, capabilities and workspaces',
    () {
      expect(
        CommandPresentationCatalog.byType(CommandCatalogEntryType.command),
        isNotEmpty,
      );
      expect(
        CommandPresentationCatalog.byType(
          CommandCatalogEntryType.contextualAction,
        ),
        isNotEmpty,
      );
      expect(
        CommandPresentationCatalog.byType(CommandCatalogEntryType.capability),
        isNotEmpty,
      );
      expect(
        CommandPresentationCatalog.byType(CommandCatalogEntryType.workspace),
        isNotEmpty,
      );
    },
  );

  test('known unavailable capability is not advertised as available', () {
    final sketch3d = CommandPresentationCatalog.byId('sketch.3d');
    final recognition = CommandPresentationCatalog.byId('recognition.analytic');

    expect(sketch3d.availability, CommandAvailability.unavailable);
    expect(recognition.availability, CommandAvailability.unresolved);
  });

  test('metadata round-trips without execution fields', () {
    final original = CommandPresentationCatalog.byId(
      'reverse.sketch.dimension.edit',
    );
    final restored = CommandPresentationEntry.fromJson(original.toJson());

    expect(restored.toJson(), original.toJson());
    expect(restored.type, CommandCatalogEntryType.contextualAction);
    expect(restored.source, CommandCatalogSource.operationalController);
  });

  test('aliases do not collide within the same entry', () {
    for (final entry in CommandPresentationCatalog.entries) {
      expect(
        entry.aliases.toSet().length,
        entry.aliases.length,
        reason: entry.id,
      );
    }
  });

  test('search ranks Portuguese names and CAD aliases without duplicates', () {
    final byName = CommandPresentationCatalog.search('editar cota');
    final byAlias = CommandPresentationCatalog.search('dimensão');

    expect(byName.first.id, 'reverse.sketch.dimension.edit');
    expect(byAlias.map((entry) => entry.id).toSet().length, byAlias.length);
  });
}
