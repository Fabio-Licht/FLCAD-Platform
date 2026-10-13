import 'dart:ui' show Size;

import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_planner.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_presets.dart';
import 'package:flcad_mobile/core/adaptive_studio/models/adaptive_studio_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mm2_layout_harness.dart';

void main() {
  const planner = PanelLayoutPlanner();
  const policy = PanelLayoutPolicy();

  /// Default in-window layout with Explorer/Inspector expanded.
  PanelLayout expandedLayout() {
    var layout = PanelLayoutPresets.singleMonitor();
    layout = layout
        .withEntry(layout.entryFor(PanelId.explorer).copyWith(collapsed: false))
        .withEntry(
          layout.entryFor(PanelId.inspector).copyWith(collapsed: false),
        );
    return layout.normalize();
  }

  group('responsive by usable window size', () {
    test(
      'a roomy window keeps the stored layout and protects the viewport',
      () {
        final resolution = planner.resolve(
          layout: expandedLayout(),
          usableSize: const Size(1600, 900),
        );

        expect(resolution.compact, isFalse);
        expect(resolution.focusMode, isFalse);
        expect(resolution.dockWidths[PanelId.explorer], 240);
        expect(resolution.dockWidths[PanelId.inspector], 280);
        expect(resolution.collapsed[PanelId.explorer], isFalse);
        expect(resolution.collapsed[PanelId.inspector], isFalse);
        expect(resolution.highlightedContextualPanel, isNull);
        expect(
          resolution.viewportWidth,
          greaterThanOrEqualTo(policy.viewportMinWidth),
        );
        expect(resolution.viewportHeight, greaterThan(700));
        expect(resolution.notes, isEmpty);
      },
    );

    test('the same desktop becomes compact on a small window', () {
      final roomy = planner.resolve(
        layout: expandedLayout(),
        usableSize: const Size(1600, 900),
      );
      final small = planner.resolve(
        layout: expandedLayout(),
        usableSize: const Size(1000, 520),
      );

      expect(roomy.compact, isFalse);
      expect(small.compact, isTrue);
      expect(small.notes, contains(PanelLayoutNote.compactModeActive));
      expect(
        small.viewportWidth,
        greaterThanOrEqualTo(policy.viewportMinWidthCompact),
      );
    });

    test('a short window is compact even when it is wide', () {
      final resolution = planner.resolve(
        layout: expandedLayout(),
        usableSize: const Size(1900, 560),
      );
      expect(resolution.compact, isTrue);
    });
  });

  group('viewport protection and width limits', () {
    test('panel widths are clamped instead of crushing the viewport', () {
      var layout = expandedLayout();
      layout = layout
          .withEntry(layout.entryFor(PanelId.explorer).copyWith(dockWidth: 480))
          .withEntry(
            layout.entryFor(PanelId.inspector).copyWith(dockWidth: 460),
          )
          .normalize();

      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1300, 900),
      );

      expect(resolution.notes, contains(PanelLayoutNote.widthClamped));
      expect(
        resolution.viewportWidth,
        greaterThanOrEqualTo(policy.viewportMinWidth - 0.001),
      );
      for (final width in resolution.dockWidths.values) {
        expect(width, greaterThanOrEqualTo(panelMinWidth));
        expect(width, lessThanOrEqualTo(panelMaxWidth));
      }
    });

    test('a contextual panel is hidden when shrinking is not enough', () {
      var layout = expandedLayout();
      layout = layout
          .withEntry(
            layout
                .entryFor(PanelId.assistant)
                .copyWith(
                  collapsed: false,
                  visible: true,
                  dockWidth: panelMaxWidth,
                ),
          )
          .normalize();

      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1180, 900),
      );

      expect(resolution.notes, contains(PanelLayoutNote.contextualHidden));
      expect(resolution.collapsed[PanelId.assistant], isTrue);
      expect(
        resolution.viewportWidth,
        greaterThanOrEqualTo(policy.viewportMinWidth - 0.001),
      );
    });

    test('viewport width never goes negative on an extreme window', () {
      final resolution = planner.resolve(
        layout: expandedLayout(),
        usableSize: const Size(520, 420),
      );

      expect(resolution.viewportWidth, greaterThanOrEqualTo(0));
      expect(
        resolution.viewportWidth,
        greaterThanOrEqualTo(policy.viewportMinWidthCompact - 0.001),
      );
    });
  });

  group('independent collapse', () {
    test('collapsing Explorer does not touch the Inspector', () {
      var layout = expandedLayout();
      layout = layout.withEntry(
        layout.entryFor(PanelId.explorer).copyWith(collapsed: true),
      );

      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1600, 900),
      );

      expect(resolution.collapsed[PanelId.explorer], isTrue);
      expect(resolution.collapsed[PanelId.inspector], isFalse);
      expect(resolution.dockWidths.containsKey(PanelId.explorer), isFalse);
      expect(resolution.dockWidths[PanelId.inspector], 280);
      expect(resolution.leftRailWidth, policy.collapsedRailWidth);
      // Only the collapsed Assistant rail remains on the right side.
      expect(resolution.rightRailWidth, policy.collapsedRailWidth);
    });

    test('collapsing both frees the viewport without changing widths', () {
      var layout = expandedLayout();
      layout = layout
          .withEntry(
            layout.entryFor(PanelId.explorer).copyWith(collapsed: true),
          )
          .withEntry(
            layout.entryFor(PanelId.inspector).copyWith(collapsed: true),
          );

      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1600, 900),
      );

      expect(resolution.collapsed[PanelId.explorer], isTrue);
      expect(resolution.collapsed[PanelId.inspector], isTrue);
      expect(
        resolution.viewportWidth,
        greaterThanOrEqualTo(policy.viewportMinWidth),
      );
      expect(resolution.notes, isNot(contains(PanelLayoutNote.widthClamped)));
    });
  });

  group('single contextual panel in compact mode', () {
    test('memory of the last contextual panel wins', () {
      final layout = expandedLayout().copyWith(
        preferences: const PanelLayoutPreferences(
          lastContextualPanel: PanelId.continuity,
        ),
      );
      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1000, 520),
      );

      expect(resolution.highlightedContextualPanel, PanelId.continuity);
      expect(resolution.collapsed[PanelId.continuity], isFalse);
      expect(resolution.collapsed[PanelId.reconstruct], isTrue);
      expect(resolution.collapsed[PanelId.assistant], isTrue);
    });

    test('an explicit request overrides the remembered panel', () {
      final layout = expandedLayout().copyWith(
        preferences: const PanelLayoutPreferences(
          lastContextualPanel: PanelId.continuity,
        ),
      );
      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1000, 520),
        requestedContextualPanel: PanelId.reconstruct,
      );

      expect(resolution.highlightedContextualPanel, PanelId.reconstruct);
      expect(resolution.collapsed[PanelId.continuity], isTrue);
      expect(resolution.collapsed[PanelId.reconstruct], isFalse);
    });

    test('below the primary threshold the primary panels become rails', () {
      final resolution = planner.resolve(
        layout: expandedLayout(),
        usableSize: const Size(900, 700),
      );

      expect(resolution.compact, isTrue);
      expect(resolution.notes, contains(PanelLayoutNote.primaryCollapsed));
      expect(resolution.collapsed[PanelId.explorer], isTrue);
      expect(resolution.collapsed[PanelId.inspector], isTrue);
      expect(resolution.highlightedContextualPanel, isNotNull);
      expect(resolution.leftRailWidth, policy.collapsedRailWidth);
      expect(resolution.rightRailWidth, policy.collapsedRailWidth);
    });
  });

  group('focus mode', () {
    test('collapses every side panel and maximizes the geometry viewport', () {
      final layout = expandedLayout().copyWith(
        preferences: const PanelLayoutPreferences(
          focusMode: true,
          lastContextualPanel: PanelId.reconstruct,
        ),
      );

      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1600, 900),
      );

      expect(resolution.focusMode, isTrue);
      expect(resolution.notes, contains(PanelLayoutNote.focusModeActive));
      for (final id in PanelId.values) {
        expect(resolution.collapsed[id], isTrue, reason: id.name);
      }
      expect(resolution.dockWidths, isEmpty);
      final rails = resolution.leftRailWidth + resolution.rightRailWidth;
      expect(resolution.viewportWidth, greaterThan(1600 - rails - 4));
      // Planning is pure: the stored layout keeps its own state.
      expect(layout.preferences.focusMode, isTrue);
      expect(layout.entryFor(PanelId.explorer).collapsed, isFalse);
    });

    test('the override turns focus mode on without persisting it', () {
      final layout = expandedLayout();
      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1600, 900),
        focusModeOverride: true,
      );

      expect(resolution.focusMode, isTrue);
      expect(layout.preferences.focusMode, isFalse);
    });
  });

  group('detached and floating panels', () {
    test('detached panels leave the in-window viewport untouched', () {
      final detached = PanelLayoutPresets.dualMonitor(
        displays: dualDisplayDesktop(),
      );
      final docked = PanelLayoutPresets.singleMonitor();

      final withDetached = planner.resolve(
        layout: detached,
        usableSize: const Size(1600, 900),
      );
      final without = planner.resolve(
        layout: docked,
        usableSize: const Size(1600, 900),
      );

      expect(withDetached.dockWidths.containsKey(PanelId.reconstruct), isFalse);
      expect(
        withDetached.viewportWidth,
        greaterThanOrEqualTo(without.viewportWidth),
      );
    });

    test('a floating panel is an overlay, not a side column', () {
      final layout = expandedLayout().withEntry(
        expandedLayout()
            .entryFor(PanelId.inspector)
            .copyWith(dockState: DockState.floating, dockWidth: 320),
      );
      final resolution = planner.resolve(
        layout: layout,
        usableSize: const Size(1600, 900),
      );

      expect(resolution.dockWidths.containsKey(PanelId.inspector), isFalse);
      expect(resolution.rightRailWidth, policy.collapsedRailWidth);
    });
  });
}
