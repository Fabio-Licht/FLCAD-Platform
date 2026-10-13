import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/sketch_assistant/sketch_reconstruction.dart';
import '../../engineering_bridge/operational_reverse_engineering_controller.dart';

String sketchReconstructionSuggestionUiKey(
  SketchReconstructionSuggestion suggestion,
) => _sketchSuggestionUiKey(suggestion);

String _sketchSuggestionUiKey(SketchReconstructionSuggestion suggestion) {
  String ids(Iterable<String> values) => (values.toSet().toList()..sort()).join(',');
  // Include every source role.  Two hypotheses may intentionally cover the
  // same entityIds while using different fit contributors; collapsing them
  // here makes hover, expansion and scroll target the wrong row.
  return '${suggestion.kind.name}:e=${ids(suggestion.entityIds)}:'
      'u=${ids(suggestion.usedEntityIds)}:c=${ids(suggestion.coveredEntityIds)}:'
      '${suggestion.startPoint?.x}:${suggestion.startPoint?.y}:'
      '${suggestion.endPoint?.x}:${suggestion.endPoint?.y}';
}

class SketchReconstructionSuggestionGroups extends StatefulWidget {
  const SketchReconstructionSuggestionGroups({
    super.key,
    required this.controller,
    required this.onFocusSuggestion,
    required this.scrollController,
  });

  final OperationalReverseEngineeringController controller;
  final ValueChanged<SketchReconstructionSuggestion> onFocusSuggestion;
  final ScrollController scrollController;

  @override
  State<SketchReconstructionSuggestionGroups> createState() =>
      _SketchReconstructionSuggestionGroupsState();
}

class _SketchReconstructionSuggestionGroupsState
    extends State<SketchReconstructionSuggestionGroups> {
  final _tileKeys = <String, GlobalKey>{};
  final _expanded = <SketchReconstructionSuggestionCategory, bool>{};
  Timer? _hoverScrollTimer;
  String? _lastScrolledKey;
  String? _lastObservedHoverKey;
  String? _lastSuggestionSignature;
  bool _pointerInsideList = false;

  @override
  void initState() {
    super.initState();
    _lastObservedHoverKey = _hoverKey(
      widget.controller.hoveredSketchReconstructionSuggestion,
    );
    _lastSuggestionSignature = _suggestionSignature(
      widget.controller.sketchReconstructionSuggestions,
    );
  }

  @override
  void dispose() {
    _hoverScrollTimer?.cancel();
    super.dispose();
  }

  String? _hoverKey(SketchReconstructionSuggestion? suggestion) =>
      suggestion == null ? null : _sketchSuggestionUiKey(suggestion);

  @override
  void didUpdateWidget(
    covariant SketchReconstructionSuggestionGroups oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    final newSuggestion =
        widget.controller.hoveredSketchReconstructionSuggestion;
    final newKey = _hoverKey(newSuggestion);
    if (_lastObservedHoverKey != newKey) {
      _hoverScrollTimer?.cancel();
      _stopAutomaticScrollAnimation();
      if (newKey == null) {
        _lastScrolledKey = null;
      } else if (!_pointerInsideList && newSuggestion != null) {
        _scheduleHoverScroll(newSuggestion);
      }
      _lastObservedHoverKey = newKey;
    }
    final signature = _suggestionSignature(
      widget.controller.sketchReconstructionSuggestions,
    );
    final currentKeys = signature.isEmpty
        ? const <String>{}
        : widget.controller.sketchReconstructionSuggestions
              .map(_sketchSuggestionUiKey)
              .toSet();
    _tileKeys.removeWhere((key, _) => !currentKeys.contains(key));
    if (_lastSuggestionSignature != signature) {
      _cancelHoverScroll();
      _stopAutomaticScrollAnimation();
      _lastScrolledKey = null;
      _lastSuggestionSignature = signature;
      if (newSuggestion != null && !_pointerInsideList) {
        _scheduleHoverScroll(newSuggestion);
      }
    }
  }

  String _suggestionSignature(
    Iterable<SketchReconstructionSuggestion> suggestions,
  ) => suggestions
      .map(
        (suggestion) =>
            '${_sketchSuggestionUiKey(suggestion)}:${suggestion.label}:'
            '${suggestion.confidence}:${suggestion.rmsError}:'
            '${suggestion.maxError}',
      )
      .join('|');

  void _cancelHoverScroll() {
    _hoverScrollTimer?.cancel();
    _hoverScrollTimer = null;
  }

  void _stopAutomaticScrollAnimation() {
    if (widget.scrollController.hasClients) {
      // Jumping to the current offset cancels an active ensureVisible
      // animation without changing the operator's visible position.
      widget.scrollController.jumpTo(widget.scrollController.offset);
    }
  }

  void _scheduleHoverScroll(SketchReconstructionSuggestion suggestion) {
    final key = _sketchSuggestionUiKey(suggestion);
    if (_lastScrolledKey == key) return;
    _cancelHoverScroll();
    _hoverScrollTimer = Timer(const Duration(milliseconds: 300), () {
      _hoverScrollTimer = null;
      if (!mounted || _pointerInsideList) return;
      final current = widget.controller.hoveredSketchReconstructionSuggestion;
      if (current == null || _sketchSuggestionUiKey(current) != key) return;
      _lastScrolledKey = key;
      _expandAndCenter(current);
    });
  }

  void _expandAndCenter(SketchReconstructionSuggestion suggestion) {
    final category = widget.controller.sketchReconstructionSuggestionCategory(
      suggestion,
    );
    if (_expanded[category] != true) {
      setState(() => _expanded[category] = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pointerInsideList) return;
      final context =
          _tileKeys[_sketchSuggestionUiKey(suggestion)]?.currentContext;
      if (context == null || !widget.scrollController.hasClients) return;
      Scrollable.ensureVisible(
        context,
        alignment: .5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final suggestions = widget.controller.sketchReconstructionSuggestions;
        return MouseRegion(
          onEnter: (_) {
            _pointerInsideList = true;
            _cancelHoverScroll();
            _stopAutomaticScrollAnimation();
          },
          onExit: (_) => _pointerInsideList = false,
          child: Column(
            children: [
              for (final category
                  in SketchReconstructionSuggestionCategory.values)
                _buildGroup(category, suggestions),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGroup(
    SketchReconstructionSuggestionCategory category,
    List<SketchReconstructionSuggestion> suggestions,
  ) {
    final categorySuggestions = suggestions
        .where(
          (suggestion) =>
              widget.controller.sketchReconstructionSuggestionCategory(
                suggestion,
              ) ==
              category,
        )
        .toList(growable: false);
    final label = switch (category) {
      SketchReconstructionSuggestionCategory.lines => 'Linhas',
      SketchReconstructionSuggestionCategory.splines => 'Splines',
      SketchReconstructionSuggestionCategory.arcs => 'Arcos/Círculos',
    };
    final icon = switch (category) {
      SketchReconstructionSuggestionCategory.lines => Icons.show_chart,
      SketchReconstructionSuggestionCategory.splines => Icons.gesture,
      SketchReconstructionSuggestionCategory.arcs =>
        Icons.architecture_outlined,
    };
    return ExpansionTile(
      key: ValueKey(
        'sketch-reconstruction-group-${category.name}-${_expanded[category] ?? categorySuggestions.isNotEmpty}',
      ),
      initiallyExpanded: _expanded[category] ?? categorySuggestions.isNotEmpty,
      maintainState: true,
      onExpansionChanged: (expanded) {
        _expanded[category] = expanded;
        if (mounted) setState(() {});
      },
      tilePadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, size: 16),
      title: Text('$label (${categorySuggestions.length})'),
      children: [
        if (categorySuggestions.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(30, 0, 8, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Nenhuma sugestão', style: TextStyle(fontSize: 9)),
            ),
          )
        else
          for (final suggestion in categorySuggestions)
            _SketchReconstructionSuggestionTile(
              key: _tileKeys.putIfAbsent(
                _sketchSuggestionUiKey(suggestion),
                GlobalKey.new,
              ),
              controller: widget.controller,
              suggestion: suggestion,
              onFocus: () => widget.onFocusSuggestion(suggestion),
              onListHoverChanged: (inside) {
                _pointerInsideList = inside;
                if (inside) {
                  _cancelHoverScroll();
                  _stopAutomaticScrollAnimation();
                }
              },
            ),
      ],
    );
  }
}

class _SketchReconstructionSuggestionTile extends StatelessWidget {
  const _SketchReconstructionSuggestionTile({
    super.key,
    required this.controller,
    required this.suggestion,
    required this.onFocus,
    this.onListHoverChanged,
  });

  final OperationalReverseEngineeringController controller;
  final SketchReconstructionSuggestion suggestion;
  final VoidCallback onFocus;
  final ValueChanged<bool>? onListHoverChanged;

  @override
  Widget build(BuildContext context) {
    final selected = controller.isSketchReconstructionSuggestionSelected(
      suggestion,
    );
    final selectionOrder = controller.sketchReconstructionSelectionOrder(
      suggestion,
    );
    final hovered = controller.isSketchReconstructionSuggestionHovered(
      suggestion,
    );
    return MouseRegion(
      onEnter: (_) {
        onListHoverChanged?.call(true);
        controller.highlightSketchReconstructionSuggestion(suggestion);
      },
      onExit: (_) {
        onListHoverChanged?.call(false);
        controller.clearHoveredSketchReconstructionSuggestion();
      },
      child: ListTile(
        dense: true,
        selected: selected,
        contentPadding: EdgeInsets.zero,
        onTap: onFocus,
        leading: selectionOrder == null
            ? null
            : CircleAvatar(
                radius: 9,
                child: Text(
                  '$selectionOrder',
                  style: const TextStyle(fontSize: 9),
                ),
              ),
        title: Row(
          children: [
            Text(
              controller.sketchReconstructionSuggestionDisplayLabel(suggestion),
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: hovered ? const Color(0xff4de1d2) : null,
              ),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                suggestion.label,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        subtitle: Text(
          _sketchReconstructionSuggestionSubtitle(suggestion),
          style: const TextStyle(fontSize: 9),
        ),
        trailing: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            // Absorb the ListTile tap so ✓ stays accept-only.
          },
          child: IconButton(
            key: ValueKey(
              'sketch-reconstruction-accept-${suggestion.kind.name}-${suggestion.entityIds.join('-')}',
            ),
            tooltip: 'Aceitar sugestão',
            icon: const Icon(Icons.check, size: 16),
            onPressed: controller.busy
                ? null
                : () async {
                    await controller.acceptSketchReconstructionSuggestion(
                      suggestion,
                    );
                  },
          ),
        ),
      ),
    );
  }
}

class SketchReconstructionJointPreviewPanel extends StatelessWidget {
  const SketchReconstructionJointPreviewPanel({
    super.key,
    required this.controller,
    required this.preview,
  });

  final OperationalReverseEngineeringController controller;
  final SketchReconstructionJointAcceptancePlan preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final analysis = preview.analysis;
    return Card(
      key: const ValueKey('sketch-reconstruction-joint-preview'),
      margin: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      color: theme.colorScheme.secondaryContainer.withValues(alpha: .45),
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Preview de aceitacao conjunta',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              preview.canApply
                  ? 'Preview validado; confirmar aplica a transacao atomica apresentada.'
                  : 'Preview bloqueado; confirme somente apos resolver os bloqueadores.',
              style: const TextStyle(fontSize: 9.5),
            ),
            Text(
              '${analysis.summary} Â· ${preview.suggestions.length} geometrias propostas',
              style: const TextStyle(fontSize: 9.5),
            ),
            if (analysis.gapsMillimeters.isNotEmpty)
              Text(
                'Gaps: ${analysis.gapsMillimeters.map((gap) => '${gap.toStringAsFixed(3)} mm').join(', ')}',
                style: const TextStyle(fontSize: 9.5),
              ),
            const SizedBox(height: 3),
            for (var index = 0; index < preview.suggestions.length; index++)
              Text(
                '${index + 1}. ${preview.suggestions[index].suggestion.label} Â· '
                '${preview.suggestions[index].reversed ? 'invertida' : 'orientacao original'}',
                style: const TextStyle(fontSize: 9.5),
              ),
            if (preview.warnings.isNotEmpty) ...[
              const SizedBox(height: 3),
              for (final warning in preview.warnings)
                Text(
                  'Aviso: $warning',
                  style: TextStyle(
                    fontSize: 9.5,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
            ],
            if (preview.blockers.isNotEmpty) ...[
              const SizedBox(height: 3),
              for (final blocker in preview.blockers)
                Text(
                  'Bloqueador: $blocker',
                  style: TextStyle(
                    fontSize: 9.5,
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
            const SizedBox(height: 5),
            Row(
              children: [
                TextButton(
                  onPressed: controller.busy
                      ? null
                      : controller.cancelSketchReconstructionJointPreview,
                  child: const Text('Cancelar'),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  key: const ValueKey(
                    'sketch-reconstruction-joint-preview-confirm',
                  ),
                  onPressed:
                      controller.canConfirmSketchReconstructionJointAcceptance
                      ? () async {
                          final token =
                              controller.sketchReconstructionJointPreviewToken;
                          if (token == null) return;
                          await controller
                              .confirmSketchReconstructionJointAcceptance(
                                token,
                              );
                        }
                      : null,
                  icon: const Icon(Icons.check, size: 14),
                  label: const Text('Confirmar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _sketchReconstructionSuggestionSubtitle(
  SketchReconstructionSuggestion suggestion,
) {
  final parts = <String>[
    '${suggestion.entityIds.length} entidade(s)',
    '${(suggestion.confidence * 100).toStringAsFixed(0)}%',
  ];
  if (suggestion.rmsError != null) {
    parts.add('RMS ${suggestion.rmsError!.toStringAsFixed(3)} mm');
  }
  if (suggestion.maxError != null) {
    parts.add('máx ${suggestion.maxError!.toStringAsFixed(3)} mm');
  }
  return parts.join(' · ');
}
