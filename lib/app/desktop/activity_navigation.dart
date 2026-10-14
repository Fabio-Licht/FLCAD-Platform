/// Visual grouping for the existing OfficialEngineeringWorkspace modules.
///
/// The values are presentation labels only. They are not workspace ids and
/// must never be dispatched as commands.
class ActivityNavigationGroup {
  const ActivityNavigationGroup({required this.label, required this.modules});

  final String label;
  final List<String> modules;
}

abstract final class ActivityNavigation {
  static const groups = <ActivityNavigationGroup>[
    ActivityNavigationGroup(
      label: 'Preparar',
      modules: ['Reverse Engineering', 'AI Engineering'],
    ),
    ActivityNavigationGroup(
      label: 'Alinhar',
      modules: ['Reference', 'Transform'],
    ),
    ActivityNavigationGroup(label: 'Reconhecer', modules: ['Recognition']),
    ActivityNavigationGroup(label: 'Sketch', modules: ['Sketch']),
    ActivityNavigationGroup(label: 'Curvas', modules: ['Curves']),
    ActivityNavigationGroup(label: 'Superfícies', modules: ['Surfaces']),
    ActivityNavigationGroup(label: 'Sólidos', modules: ['Solids']),
    ActivityNavigationGroup(
      label: 'Analisar',
      modules: ['Sections', 'Entidades'],
    ),
  ];

  static const modules = [
    'Reverse Engineering',
    'AI Engineering',
    'Recognition',
    'Reference',
    'Entidades',
    'Sketch',
    'Curves',
    'Surfaces',
    'Solids',
    'Sections',
    'Transform',
  ];

  static String groupFor(String module) => groups
      .firstWhere(
        (group) => group.modules.contains(module),
        orElse: () =>
            const ActivityNavigationGroup(label: 'Atividade', modules: []),
      )
      .label;

  static String labelFor(String module) => switch (module) {
    'Reverse Engineering' => 'Engenharia reversa',
    'AI Engineering' => 'Engenharia com IA',
    'Recognition' => 'Reconhecimento',
    'Reference' => 'Referências',
    'Entidades' => 'Entidades',
    'Sketch' => 'Sketch',
    'Curves' => 'Curvas',
    'Surfaces' => 'Superfícies',
    'Solids' => 'Sólidos',
    'Sections' => 'Seções',
    'Transform' => 'Transformar',
    _ => module,
  };

  static bool isPlaceholder(String module) =>
      module == 'AI Engineering' || module == 'Curves';
}
