import 'package:flutter_test/flutter_test.dart';

import 'test_output_path.dart';

void main() {
  test('redirects protected file and directory paths into test output root', () {
    expect(
      testOutputPath(
        r'C:\flcad_mobile\test_assets\screenshots\report.txt',
        outputRoot: r'C:\worktree\build\test-output',
      ),
      r'C:\worktree\build\test-output\test_assets\screenshots\report.txt',
    );
    expect(
      testOutputPath(
        r'C:\flcad_mobile\test_assets\screenshots\ER-P2D-C3-F2',
        outputRoot: r'C:\worktree\build\test-output',
      ),
      r'C:\worktree\build\test-output\test_assets\screenshots\ER-P2D-C3-F2',
    );
  });

  test('leaves unrelated paths untouched', () {
    const path = r'D:\fixtures\mesh.stl';
    expect(testOutputPath(path, outputRoot: r'C:\worktree\build\out'), path);
  });
}
