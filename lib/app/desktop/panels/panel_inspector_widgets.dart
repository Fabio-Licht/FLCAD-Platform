import 'dart:async';

import 'package:flutter/material.dart';

import 'panel_presentation_models.dart';

/// Shared visual primitives for the Inspector.
///
/// These widgets deliberately depend only on presentation models. They do not
/// know about CadRuntime, commands, persistence, FFI or panel transport.
class InspectorEntityHeader extends StatelessWidget {
  const InspectorEntityHeader({super.key, required this.entity});

  final InspectorEntityModel entity;

  @override
  Widget build(BuildContext context) => Semantics(
        header: true,
        label: '${entity.name}, ${entity.selectionDomain}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entity.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Text(
              '${entity.type} · ${entity.selectionDomain == 'document' ? 'documental' : 'operacional'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
}

class InspectorPropertySection extends StatefulWidget {
  const InspectorPropertySection({
    super.key,
    required this.section,
    required this.children,
    this.initiallyExpanded = true,
  });

  final InspectorSectionModel section;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  State<InspectorPropertySection> createState() =>
      _InspectorPropertySectionState();
}

class _InspectorPropertySectionState extends State<InspectorPropertySection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        label: widget.section.label,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.section.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        semanticLabel: _expanded ? 'Recolher' : 'Expandir',
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 10, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: widget.children,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
}

class InspectorPropertyRow extends StatelessWidget {
  const InspectorPropertyRow({
    super.key,
    required this.property,
    this.value,
  });

  final InspectorPropertyModel property;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    final unavailable =
        property.availability == PanelPropertyAvailability.unavailable;
    final display = unavailable
        ? 'Indisponível'
        : TechnicalValueFormatter.format(
            value ?? property.value,
            unit: property.unit,
            precision: property.precision,
          );
    return Semantics(
      label: '${property.label}: $display',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              flex: 4,
              child: Text(
                property.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              flex: 6,
              child: Text(
                display,
                textAlign: TextAlign.right,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: unavailable
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : null,
                  fontStyle: unavailable ? FontStyle.italic : null,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class InspectorAccessIndicator extends StatelessWidget {
  const InspectorAccessIndicator({
    super.key,
    required this.access,
  });

  final PanelPropertyAccess access;

  @override
  Widget build(BuildContext context) {
    final editable = access == PanelPropertyAccess.editable;
    return Tooltip(
      message: editable ? 'Editável' : 'Somente leitura',
      child: Icon(
        editable ? Icons.edit_outlined : Icons.lock_outline,
        size: 14,
        semanticLabel: editable ? 'Editável' : 'Somente leitura',
      ),
    );
  }
}

class InspectorModeSelector extends StatelessWidget {
  const InspectorModeSelector({
    super.key,
    required this.advanced,
    required this.onChanged,
  });

  final bool advanced;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('Básico')),
          ButtonSegment(value: true, label: Text('Avançado')),
        ],
        selected: {advanced},
        onSelectionChanged: (value) => onChanged(value.first),
      );
}

class InspectorNumericEditor extends StatefulWidget {
  const InspectorNumericEditor({
    super.key,
    required this.label,
    required this.value,
    required this.onSubmitted,
    this.unit,
    this.precision = 3,
    this.enabled = true,
    this.minimum = 0,
    this.maximum = 1e12,
  });

  final String label;
  final double value;
  final String? unit;
  final int precision;
  final bool enabled;
  final double minimum;
  final double maximum;
  final FutureOr<void> Function(double value) onSubmitted;

  @override
  State<InspectorNumericEditor> createState() =>
      _InspectorNumericEditorState();
}

class _InspectorNumericEditorState extends State<InspectorNumericEditor> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.value.toStringAsFixed(widget.precision),
    );
  }

  @override
  void didUpdateWidget(InspectorNumericEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_controller.selection.isValid) {
      _controller.text = widget.value.toStringAsFixed(widget.precision);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String raw) async {
    final value = double.tryParse(raw.trim().replaceAll(',', '.'));
    if (value == null || !value.isFinite || value <= widget.minimum || value > widget.maximum) {
      setState(() => _error = 'Valor inválido');
      return;
    }
    setState(() => _error = null);
    await widget.onSubmitted(value);
  }

  @override
  Widget build(BuildContext context) => Semantics(
        textField: true,
        label: widget.label,
        child: TextField(
          controller: _controller,
          enabled: widget.enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onSubmitted: _submit,
          decoration: InputDecoration(
            labelText: widget.label,
            suffixText: widget.unit,
            errorText: _error,
            isDense: true,
          ),
        ),
      );
}
