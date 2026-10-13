import 'dart:async';
import 'dart:io';
import 'package:flcad_mobile/app/desktop/desktop_application.dart';
import 'package:flcad_mobile/app/desktop/desktop_asset_manager.dart';
import 'package:flcad_mobile/app/desktop/desktop_cad_controller.dart';
import 'package:flcad_mobile/app/desktop/desktop_settings.dart';
import 'package:flcad_mobile/app/commands/desktop_command_coordinator.dart';
import 'package:flcad_mobile/app/cad_viewport/native/integrated_native_viewport_widget.dart';
import 'package:flcad_mobile/app/bootstrap/engineering_bootstrap.dart';
import 'package:flcad_mobile/app/desktop/desktop_theme.dart';
import 'package:flcad_mobile/app/reconstruction/desktop_colmap_lab_runtime.dart';
import 'package:flcad_mobile/core/cad_kernel/manager/kernel_manager.dart';
import 'package:flcad_mobile/features/projects/domain/project_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _AssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList([1, 2, 3]));
}

DesktopSettingsController controller({bool completed = true}) {
  final repository = MemoryDesktopSettingsRepository(
    DesktopSettings(firstRunCompleted: completed),
  );
  return DesktopSettingsController(repository, repository.value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Professional Desktop Application', () {
    testWidgets('workspace keeps the viewport bounded when suggestion hover is idle', (
      tester,
    ) async {
      EngineeringBootstrap.instance.initialize();
      final cad = DesktopCadController(
        kernels: KernelManager(),
        projects: ProjectManager.instance,
      );
      final commands = DesktopCommandCoordinator(
        cad: cad,
        projects: ProjectManager.instance,
      );
      addTearDown(cad.dispose);
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfficialEngineeringWorkspace(
              cad: cad,
              commands: commands,
            ),
          ),
        ),
      );
      await tester.pump();

      final viewport = tester.renderObject<RenderBox>(
        find.byType(IntegratedCadViewportWidget),
      );
      expect(viewport.hasSize, isTrue);
      expect(viewport.size.width, greaterThan(0));
      expect(viewport.size.height, greaterThan(0));
    });

    testWidgets('shell and Settings remain available while lab initializes', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late final Directory support;
      await tester.runAsync(() async {
        support = await Directory.systemTemp.createTemp('flcad-app-lab-');
      });
      addTearDown(() => support.delete(recursive: true));
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (_) async => support.path,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null),
      );
      var executablePickerCalls = 0;
      var photoPickerCalls = 0;
      var disposeCalls = 0;
      late final DesktopColmapLabRuntime runtime;
      await tester.runAsync(() async {
        runtime = await DesktopColmapLabRuntime.create(
          applicationSupportDirectoryProvider: () async => support,
          selectExecutable: () async {
            executablePickerCalls++;
            return null;
          },
          selectPhotoDirectory: () async {
            photoPickerCalls++;
            return null;
          },
          onDispose: () => disposeCalls++,
        );
      });
      final gate = Completer<DesktopColmapLabRuntime>();
      final repository = MemoryDesktopSettingsRepository(
        DesktopSettings(firstRunCompleted: true),
      );

      await tester.pumpWidget(
        FLCADDesktopApplication(
          settingsRepository: repository,
          splashStep: Duration.zero,
          platformInitializer: () async {},
          colmapLabRuntimeFactory: () => gate.future,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).destinations,
        hasLength(3),
      );
      await tester.tap(find.text('Settings'));
      await tester.pump();
      expect(find.byKey(const Key('colmap-lab-initializing')), findsOneWidget);
      expect(find.byKey(const Key('open-colmap-lab')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('open-colmap-lab')))
            .onPressed,
        isNull,
      );
      expect(executablePickerCalls, 0);
      expect(photoPickerCalls, 0);

      gate.complete(runtime);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('colmap-lab-initializing')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('open-colmap-lab')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('open-colmap-lab')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(disposeCalls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(disposeCalls, 1);
    });

    testWidgets('lab factory failure keeps application Settings functional', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gate = Completer<DesktopColmapLabRuntime>();
      final repository = MemoryDesktopSettingsRepository(
        DesktopSettings(firstRunCompleted: true),
      );
      await tester.pumpWidget(
        FLCADDesktopApplication(
          settingsRepository: repository,
          splashStep: Duration.zero,
          platformInitializer: () async {},
          colmapLabRuntimeFactory: () => gate.future,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pump();

      gate.completeError(StateError('private startup detail'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('colmap-lab-unavailable')), findsOneWidget);
      expect(find.textContaining('private startup detail'), findsNothing);
      expect(find.text('Engineering tips'), findsOneWidget);
    });

    test('official asset manager validates every managed asset', () async {
      expect(DesktopAssets.all, hasLength(3));
      expect(DesktopAssets.all.every((e) => e.startsWith('assets/')), isTrue);
      await DesktopAssetManager(_AssetBundle()).validate();
    });

    test('settings.json persists all desktop preferences', () async {
      final directory = await Directory.systemTemp.createTemp(
        'b001b_settings_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final repository = JsonDesktopSettingsRepository(directory);
      final expected = DesktopSettings(
        language: 'en-US',
        theme: DesktopThemePreference.light,
        defaultDirectory: 'D:/CAD',
        recentProjects: const ['housing.flcad'],
        engineeringTips: false,
        firstRunCompleted: true,
      );
      await repository.save(expected);
      final restored = await repository.load();
      expect(restored.toJson(), expected.toJson());
      expect(
        File(
          '${directory.path}${Platform.pathSeparator}settings.json',
        ).existsSync(),
        isTrue,
      );
    });

    testWidgets('splash exposes official sequence then opens dashboard', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final value = controller();
      addTearDown(value.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DesktopThemeManager.dark(),
          home: DesktopStartupSequence(
            controller: value,
            stepDuration: Duration.zero,
          ),
        ),
      );
      expect(find.text('FLCAD Reverse AI'), findsOneWidget);
      expect(find.byKey(const Key('splash-status')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Home Dashboard'), findsOneWidget);
    });

    testWidgets('first run wizard persists completion once', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final value = controller(completed: false);
      addTearDown(value.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DesktopThemeManager.dark(),
          home: FirstRunWizard(controller: value),
        ),
      );
      expect(find.text('Language'), findsOneWidget);
      await tester.tap(find.byKey(const Key('wizard-continue-0')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('wizard-continue-1')));
      await tester.tap(find.byKey(const Key('wizard-continue-1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('wizard-continue-2')));
      await tester.tap(find.byKey(const Key('wizard-continue-2')));
      await tester.pumpAndSettle();
      expect(value.settings.firstRunCompleted, isTrue);
    });

    testWidgets('dashboard, official workspace and About are operational', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final value = controller();
      addTearDown(value.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DesktopThemeManager.dark(),
          home: DesktopShell(controller: value),
        ),
      );
      expect(find.text('Novo Projeto'), findsOneWidget);
      expect(find.text('Importar STL'), findsOneWidget);
      await tester.tap(find.text('Workspace').last);
      await tester.pumpAndSettle();
      expect(find.text('Explorer'), findsOneWidget);
      expect(find.text('Shaded'), findsOneWidget);
      expect(find.text('Property Inspector'), findsOneWidget);
      expect(find.text('Engineering Assistant'), findsOneWidget);
      expect(find.text('Engineering Intelligence'), findsNothing);
      expect(find.text('New Sketch'), findsNothing);
      await tester.tap(find.text('AI Engineering'));
      await tester.pumpAndSettle();
      expect(find.text('Engineering Intelligence'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Sketch'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Sketch'))
            .selected,
        isTrue,
      );
      await tester.tap(find.byTooltip('About'));
      await tester.pumpAndSettle();
      expect(find.text('0.9.1 Alpha'), findsOneWidget);
      expect(find.text('FLCAD MODEL'), findsOneWidget);
      expect(find.text('OpenCascade'), findsOneWidget);
    });

    testWidgets('global history shortcuts use the injected CAD callbacks', (
      tester,
    ) async {
      var undoCalls = 0;
      var redoCalls = 0;
      var saveCalls = 0;
      final text = TextEditingController(text: 'editable');
      addTearDown(text.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopHistoryShortcuts(
            onUndo: () async => undoCalls++,
            onRedo: () async => redoCalls++,
            onSave: () async => saveCalls++,
            child: Scaffold(body: TextField(controller: text)),
          ),
        ),
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(undoCalls, 1);
      expect(redoCalls, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlRight);
      expect(saveCalls, 1);

      await tester.tap(find.byType(TextField));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(undoCalls, 1);
      expect(text.text, 'editable');
    });

    testWidgets('settings switches the application theme preference', (
      tester,
    ) async {
      final value = controller();
      addTearDown(value.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DesktopThemeManager.dark(),
          home: Scaffold(body: DesktopSettingsScreen(controller: value)),
        ),
      );
      await tester.tap(find.text('Light'));
      await tester.pump();
      expect(value.settings.theme, DesktopThemePreference.light);
      expect(DesktopThemeManager.dark().brightness, Brightness.dark);
      expect(DesktopThemeManager.light().brightness, Brightness.light);
    });

    testWidgets('settings exposes and opens the experimental COLMAP lab', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final value = controller();
      addTearDown(value.dispose);
      var labBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: DesktopThemeManager.dark(),
          home: Scaffold(
            body: DesktopSettingsScreen(
              controller: value,
              colmapLabBuilder: (context) {
                labBuilds++;
                return const Center(child: Text('Laboratório hermético'));
              },
            ),
          ),
        ),
      );

      expect(find.text('Recursos experimentais'), findsOneWidget);
      expect(find.text('Laboratório experimental do COLMAP'), findsOneWidget);
      expect(labBuilds, 0);
      await tester.ensureVisible(find.byKey(const Key('open-colmap-lab')));
      await tester.tap(find.byKey(const Key('open-colmap-lab')));
      await tester.pumpAndSettle();

      expect(find.text('Laboratório hermético'), findsOneWidget);
      expect(labBuilds, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(labBuilds, 1);
    });

    testWidgets('runtime initialization failure does not break Settings', (
      tester,
    ) async {
      final value = controller();
      addTearDown(value.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopSettingsScreen(
              controller: value,
              colmapLabStartupError: StateError('private storage detail'),
            ),
          ),
        ),
      );
      await tester.ensureVisible(
        find.byKey(const Key('colmap-lab-unavailable')),
      );

      expect(find.byKey(const Key('colmap-lab-unavailable')), findsOneWidget);
      expect(find.textContaining('private storage detail'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('open-colmap-lab')))
            .onPressed,
        isNull,
      );
      expect(find.text('Engineering tips'), findsOneWidget);
    });

    testWidgets('experimental Settings card has no overflow at minimum width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final value = controller();
      addTearDown(value.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopSettingsScreen(
              controller: value,
              colmapLabBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('colmap-experimental-settings-card')),
        250,
        scrollable: find.byType(Scrollable).first,
      );

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('colmap-experimental-settings-card')),
        findsOneWidget,
      );
    });
  });
}
