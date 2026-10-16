import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:flcad_mobile/app/desktop/tool_window_layout.dart';

void main() {
  test('initial placement stays inside the central viewport', () {
    final position = ToolWindowLayout.initialPosition(
      viewport: const Size(1200, 700),
      window: const Size(320, 470),
    );
    expect(position, const Offset(864, 16));
  });

  test('manual position is clamped only to the available viewport', () {
    final position = ToolWindowLayout.clampPosition(
      position: const Offset(900, 600),
      viewport: const Size(800, 500),
      window: const Size(320, 470),
    );
    expect(position, const Offset(472, 22));
  });

  test('resize respects narrow viewport bounds and internal scrolling', () {
    final size = ToolWindowLayout.resize(
      current: const Size(320, 470),
      delta: const Offset(400, 400),
      viewport: const Size(700, 560),
    );
    expect(size, const Size(520, 544));
  });

  test('content growth does not exceed the available viewport', () {
    final size = ToolWindowLayout.constrainSize(
      requested: const Size(320, 720),
      viewport: const Size(640, 480),
    );
    expect(size, const Size(320, 464));
  });
}
