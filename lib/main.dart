import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/desktop/panels/panel_shell_entry.dart';

void main(List<String> arguments) {
  // A detached panel window is started by desktop_multi_window with
  // ["multi_window", windowId, payload]. It must never boot the CAD stack: the
  // branch happens before any binding or bootstrap work.
  if (PanelShellEntry.isPanelWindow(arguments)) {
    PanelShellEntry.run(arguments);
    return;
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FLCADApp());
}
