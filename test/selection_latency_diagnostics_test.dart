import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/cad_viewport/selection_latency_diagnostics.dart';

void main() {
  test('selection operation emits monotonic structured stages', () {
    final operation = SelectionLatencyOperation(
      'selection-test-000001',
      enabled: true,
    );
    operation.mark('pointer_received');
    operation.mark('c2_region_selection', details: {'duration_ms': 12.5});

    final summary = operation.finish(details: {'terminal_stage': 'complete'});
    expect(summary['selection_operation_id'], 'selection-test-000001');
    expect(summary['duration_monotonic_ms'], isA<num>());
    final stages = summary['stages']! as Map<String, Object?>;
    expect(
      stages.keys,
      containsAll(<String>['pointer_received', 'c2_region_selection']),
    );
    expect(
      (stages['c2_region_selection']! as Map)['timestamp_monotonic_ms'],
      isA<num>(),
    );
    expect(summary['terminal_stage'], 'complete');
  });

  test('disabled operation is inert', () {
    final operation = SelectionLatencyOperation('disabled', enabled: false);
    operation.mark('ignored');
    final summary = operation.finish();
    expect((summary['stages']! as Map), isEmpty);
  });
}
