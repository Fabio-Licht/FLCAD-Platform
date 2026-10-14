import 'package:flcad_mobile/app/desktop/layout/panel_identity.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout.dart';
import 'package:flcad_mobile/app/desktop/layout/panel_layout_store.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_backend.dart';
import 'package:flcad_mobile/app/desktop/panels/panel_window_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/mm2_layout_harness.dart';

void main() {
  const geometry = PanelGeometry(left: 1960, top: 60, width: 340, height: 620);

  test(
    'owner binding is independent and follows detach/dock/restore',
    () async {
      final backend = LoopbackPanelWindowBackend();
      final store = MemoryPanelLayoutStore();
      final host = PanelWindowHost(
        backend: backend,
        layoutStore: store,
        displays: dualDisplayDesktop(),
      );

      final explorer = await host.detach(
        PanelId.explorer,
        requestedGeometry: geometry,
      );
      final inspector = await host.detach(
        PanelId.inspector,
        requestedGeometry: geometry,
      );

      expect(explorer, isNotNull);
      expect(inspector, isNotNull);
      expect(backend.boundPanels, [PanelId.explorer, PanelId.inspector]);
      expect(explorer!.windowId, isNot(inspector!.windowId));

      await host.dock(PanelId.explorer);
      expect(host.attachmentFor(PanelId.explorer), isNull);
      expect(host.attachmentFor(PanelId.inspector), inspector);

      final reopened = await host.detach(
        PanelId.explorer,
        requestedGeometry: geometry,
      );
      expect(reopened, isNotNull);
      expect(reopened!.windowId, isNot(inspector.windowId));
      expect(backend.boundPanels, [
        PanelId.explorer,
        PanelId.inspector,
        PanelId.explorer,
      ]);
    },
  );
}
