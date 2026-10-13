import 'dart:math' as math;

import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/desktop/sketch/sketch_continuity_repair_panel.dart';
import 'package:flcad_mobile/app/desktop/sketch/sketch_reconstruction_panel.dart';
import 'package:flcad_mobile/app/engineering_bridge/operational_reverse_engineering_controller.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/core/professional_recognition/api/professional_recognition_api.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_continuity_repair_planner.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_g1_continuity_repair_planner.dart';
import 'package:flcad_mobile/core/sketch_assistant/sketch_reconstruction.dart';
import 'package:flcad_mobile/core/sketch_engine/entities/sketch_entities.dart';
import 'package:flcad_mobile/core/sketch_engine/models/sketch_models.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the G124-UX Sprint 0 extraction: the Sketch reconstruction and
/// continuity panels now live in `lib/app/desktop/sketch` and are public, so
/// this file locks the contract the workspace depends on - constructors,
/// keys, texts, enabled conditions - and proves the extracted widgets never
/// take ownership of the parent scroll controller.
void main() {
  late DesktopCadController cad;
  late DesktopCommandCoordinator commands;
  late OperationalReverseEngineeringController controller;

  setUp(() {
    cad = DesktopCadController(
      kernels: KernelManager(),
      projects: ProjectManager(),
    );
    commands = DesktopCommandCoordinator(cad: cad, projects: ProjectManager());
    controller = OperationalReverseEngineeringController(
      recognition: ProfessionalRecognitionApi(),
      commands: commands,
      runtime: cad.runtime,
    );
  });

  tearDown(() {
    controller.dispose();
    cad.dispose();
  });

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  testWidgets('extracted continuity panel renders the C0 plan and controls', (
    tester,
  ) async {
    final first = SketchLine(
      const SketchVector(0, 0),
      const SketchVector(1, 0),
      id: 'line:first',
    );
    final second = SketchLine(
      const SketchVector(1.05, 0),
      const SketchVector(2, 0),
      id: 'line:second',
    );
    final join = const SketchContinuityDiagnostic()
        .analyze([first, second])
        .joins
        .single;
    final plan = const SketchContinuityRepairPlanner().plan(
      join,
      entities: {'line:first': first, 'line:second': second},
      constraints: const [],
    );
    expect(plan.status, SketchContinuityRepairStatus.requiresConfirmation);
    expect(plan.alternatives, isNotEmpty);

    await tester.pumpWidget(
      host(
        SketchContinuityRepairPanel(
          controller: controller,
          joins: [join],
          allJoins: [join],
          preview: plan,
          g1Preview: null,
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('sketch-continuity-repair-panel')),
      findsOneWidget,
    );
    expect(find.text('Correções C0/G1'), findsOneWidget);
    expect(
      find.text(
        'Selecione uma junção próxima para examinar alternativas. '
        'O preview é transitório e não altera o Sketch.',
      ),
      findsOneWidget,
    );
    final gapCount = join.issue == SketchContinuityIssue.gap ? 1 : 0;
    expect(
      find.text(
        '$gapCount gaps · ${1 - gapCount} bloqueios · 0 conexões sem problemas',
      ),
      findsOneWidget,
    );
    expect(find.text('Junções que exigem atenção'), findsOneWidget);
    expect(
      find.byKey(
        ValueKey(
          'sketch-continuity-join-${join.first.entityId}-${join.first.name}-'
          '${join.second.entityId}-${join.second.name}',
        ),
      ),
      findsOneWidget,
    );

    // C0 preview block: status, measured gap and every alternative row.
    expect(find.text('Plano requer confirmação'), findsOneWidget);
    expect(
      find.text(
        'Gap atual ${plan.currentGapMillimeters.toStringAsFixed(3)} mm · '
        'limite reparável '
        '${plan.repairGapToleranceMillimeters.toStringAsFixed(3)} mm',
      ),
      findsOneWidget,
    );
    for (var index = 0; index < plan.alternatives.length; index++) {
      expect(
        find.byKey(ValueKey('sketch-continuity-alternative-$index')),
        findsOneWidget,
      );
    }
    expect(
      find.textContaining(plan.alternatives.first.status.name),
      findsWidgets,
    );
    final confirm = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('sketch-continuity-repair-confirm')),
    );
    expect(
      confirm.onPressed,
      isNull,
      reason: 'sem sessão de preview no controller não há o que confirmar',
    );
    expect(find.text('Cancelar'), findsOneWidget);

    // The moved `_showAll` state still drives the healthy-join filter.
    await tester.tap(find.text('Ver todas'));
    await tester.pump();
    expect(find.text('Todas as junções próximas'), findsOneWidget);
    expect(find.text('Ocultar saudáveis'), findsOneWidget);
  });

  testWidgets(
    'extracted continuity panel renders the G1 preview and controls',
    (tester) async {
      final arc = SketchArc(
        const SketchVector(5, 3),
        2,
        -math.pi / 3,
        math.pi / 3,
        id: 'arc',
      );
      final start = SketchVector.fromJson(arc.parameters['center']);
      final radius = (arc.parameters['radius'] as num).toDouble();
      final angle = (arc.parameters['startAngle'] as num).toDouble();
      final contact = SketchVector(
        start.x + radius * math.cos(angle),
        start.y + radius * math.sin(angle),
      );
      final line = SketchLine(SketchVector(0, contact.y), contact, id: 'line');
      final join = const SketchContinuityDiagnostic()
          .analyze([line, arc])
          .joins
          .single;
      final g1Plan = const SketchG1ContinuityRepairPlanner().plan(
        join,
        entities: {'line': line, 'arc': arc},
        constraints: const [],
      );
      expect(g1Plan.alternatives.where((item) => item.isViable), isNotEmpty);

      await tester.pumpWidget(
        host(
          SketchContinuityRepairPanel(
            controller: controller,
            joins: const [],
            allJoins: const [],
            preview: null,
            g1Preview: g1Plan,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Preview G1 tangencial'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sketch-g1-continuity-join-label')),
        findsOneWidget,
      );
      expect(
        find.textContaining('alternativa(s) calculada(s)'),
        findsOneWidget,
      );
      expect(find.text('Alternativas válidas'), findsOneWidget);
      for (var index = 0; index < g1Plan.alternatives.length; index++) {
        expect(
          find.byKey(ValueKey('sketch-g1-continuity-alternative-$index')),
          g1Plan.alternatives[index].isViable ? findsOneWidget : findsNothing,
        );
      }
      expect(
        find.byKey(const ValueKey('sketch-g1-diagnostics')),
        g1Plan.diagnostics.isEmpty ? findsNothing : findsOneWidget,
      );
      final confirmG1 = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('sketch-g1-continuity-repair-confirm')),
      );
      expect(confirmG1.onPressed, isNull);
    },
  );

  testWidgets(
    'extracted reconstruction groups keep group state and never dispose the '
    'parent scroll controller',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);

      Widget tree() => MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              SketchReconstructionSuggestionGroups(
                controller: controller,
                onFocusSuggestion: (_) {},
                scrollController: scroll,
              ),
            ],
          ),
        ),
      );

      await tester.pumpWidget(tree());
      await tester.pump();

      expect(scroll.hasClients, isTrue);
      expect(find.text('Linhas (0)'), findsOneWidget);
      expect(find.text('Splines (0)'), findsOneWidget);
      expect(find.text('Arcos/Círculos (0)'), findsOneWidget);

      // The moved ExpansionTile state still collapses empty categories until
      // the operator expands them.
      expect(find.text('Nenhuma sugestão'), findsNothing);
      await tester.tap(find.text('Linhas (0)'));
      await tester.pump();
      expect(find.text('Nenhuma sugestão'), findsOneWidget);

      // Unmounting the panel must not release the controller owned by the
      // parent workspace tool window.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(scroll.hasClients, isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: const [SizedBox(height: 40)],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(scroll.hasClients, isTrue);
      scroll.jumpTo(0);
    },
  );
}
