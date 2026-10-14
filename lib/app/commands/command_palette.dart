import 'package:flutter/material.dart';

import 'command_presentation_catalog.dart';

class CommandPalettePolicy {
  const CommandPalettePolicy._();

  static bool canExecute(CommandPresentationEntry entry) {
    if (entry.source != CommandCatalogSource.commandRegistry) return false;
    if (entry.type != CommandCatalogEntryType.command &&
        entry.type != CommandCatalogEntryType.workspace) {
      return false;
    }
    // Only existing zero-parameter routes are executable here. Creation,
    // opening, selection, and contextual operations remain discovery-only.
    return entry.id == 'project.save' ||
        entry.id == 'project.close' ||
        entry.id.startsWith('import.') ||
        entry.id.startsWith('export.') ||
        entry.id.startsWith('workspace.');
  }
}

/// Compact search UI over presentation metadata. It never executes commands
/// directly; execution is delegated to the existing desktop coordinator.
class DesktopCommandPaletteDelegate extends SearchDelegate<void> {
  DesktopCommandPaletteDelegate({
    required this.isRegistered,
    required this.canExecute,
    required this.execute,
  });

  final bool Function(String id) isRegistered;
  final bool Function(CommandPresentationEntry entry) canExecute;
  final Future<void> Function(String id) execute;

  @override
  List<Widget>? buildActions(BuildContext context) => [
    IconButton(
      tooltip: 'Limpar',
      onPressed: () => query = '',
      icon: const Icon(Icons.clear),
    ),
  ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
    tooltip: 'Fechar pesquisa',
    onPressed: () => close(context, null),
    icon: const Icon(Icons.arrow_back),
  );

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    final results = CommandPresentationCatalog.search(query);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final entry = results[index];
        final registered = isRegistered(entry.id);
        final executable = registered && canExecute(entry);
        final status = entry.type == CommandCatalogEntryType.capability
            ? entry.availability == CommandAvailability.unavailable
                  ? 'Não disponível'
                  : 'Capacidade técnica'
            : !registered
            ? 'Não disponível neste contexto'
            : !canExecute(entry)
            ? 'Somente descoberta'
            : entry.recommendedLocation;
        return ListTile(
          enabled: executable,
          title: Text(entry.name),
          subtitle: Text('${entry.description} · $status'),
          trailing: Icon(_iconFor(entry.type), size: 20),
          onTap: executable
              ? () async {
                  // Availability is checked again immediately before dispatch.
                  if (!isRegistered(entry.id) || !canExecute(entry)) return;
                  await execute(entry.id);
                  if (context.mounted) close(context, null);
                }
              : null,
        );
      },
    );
  }

  IconData _iconFor(CommandCatalogEntryType type) => switch (type) {
    CommandCatalogEntryType.command => Icons.play_arrow_outlined,
    CommandCatalogEntryType.workspace => Icons.dashboard_outlined,
    CommandCatalogEntryType.contextualAction => Icons.tune_outlined,
    CommandCatalogEntryType.capability => Icons.info_outline,
  };
}
