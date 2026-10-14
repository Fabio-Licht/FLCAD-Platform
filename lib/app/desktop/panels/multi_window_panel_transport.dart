import 'dart:async';

import 'desktop_panel_window_backend.dart';
import 'panel_transport.dart';
import 'panel_window_backend.dart';

/// MM3 transport implemented over real window channels.
///
/// Two unidirectional channels keep the direction strict:
/// * `flcad.panel.intents` - the main window registers the handler; every panel
///   window invokes it (hello + intents).
/// * `flcad.panel.window.<windowId>` - the panel window registers the handler;
///   the main window invokes it (snapshots, lifecycle and window control).
///
/// The class is used on both sides of the same code; the backend is injectable,
/// so the whole routing runs in tests without a second engine.
class MultiWindowPanelTransport implements PanelTransport {
  MultiWindowPanelTransport({
    required this.backend,
    required this.isMainWindow,
    this.windowId,
    this.panelWindowIdResolver,
  }) : assert(
         isMainWindow ? panelWindowIdResolver != null : windowId != null,
         'the main side resolves window ids; the panel side knows its own',
       );

  final PanelWindowBackend backend;
  final bool isMainWindow;

  /// Panel side: id of the window running this isolate.
  final String? windowId;

  /// Main side: maps a panel id to the window that currently shows it.
  final String? Function(String panelId)? panelWindowIdResolver;

  void Function(String panelId, Map<String, Object?> message)? _mainListener;
  final Map<String, void Function(Map<String, Object?> message)>
  _panelListeners = {};

  /// Panel side: window control methods (`panel_configure`, `panel_close`).
  void Function(String method, Map<Object?, Object?> arguments)?
  onWindowControl;

  /// Main side: window control methods sent by a panel (`panel_dock`).
  void Function(String method, Map<Object?, Object?> arguments)?
  onMainWindowControl;

  bool _mainChannelRegistered = false;
  final Set<String> _panelChannelsRegistered = {};
  Completer<void>? _readyCompleter;

  /// Channel names are process-global, so the newest transport that registers a
  /// channel owns it. Without this, a late `close()` from a previous workspace
  /// session would unregister the channels the current session is using. The
  /// registry is keyed by backend because one backend models one process.
  static final Expando<Map<String, MultiWindowPanelTransport>> _channelOwners =
      Expando<Map<String, MultiWindowPanelTransport>>('panelChannelOwners');

  Map<String, MultiWindowPanelTransport> get _owners =>
      _channelOwners[backend] ??= {};

  /// Completes when the channels this side owns are registered.
  Future<void> get ready => _readyCompleter?.future ?? Future<void>.value();

  @override
  void registerMainListener(
    void Function(String panelId, Map<String, Object?> message) listener,
  ) {
    _mainListener = listener;
    _ensureMainChannel();
  }

  void _ensureMainChannel() {
    if (_mainChannelRegistered || !isMainWindow) return;
    _mainChannelRegistered = true;
    _owners[panelIntentsChannel] = this;
    final completer = _readyCompleter ??= Completer<void>();
    unawaited(
      backend
          .setChannelHandler(panelIntentsChannel, (method, args) async {
            if (method != 'panelMessage') {
              onMainWindowControl?.call(method, _asArguments(args));
              return null;
            }
            final message = _asMessage(args);
            if (message == null) return null;
            final panelId = message['panelId'];
            if (panelId is! String) return null;
            _deliverToMain(panelId, message);
            return null;
          })
          .whenComplete(() {
            if (!completer.isCompleted) completer.complete();
          }),
    );
  }

  void _deliverToMain(String panelId, Map<String, Object?> message) {
    final listener = _mainListener;
    if (listener == null) return;
    listener(panelId, message);
  }

  @override
  void registerPanelListener(
    String panelId,
    void Function(Map<String, Object?> message) listener,
  ) {
    _panelListeners[panelId] = listener;
    _ensurePanelChannel();
  }

  void _ensurePanelChannel() {
    final id = windowId;
    if (isMainWindow || id == null) return;
    if (_panelChannelsRegistered.contains(id)) return;
    _panelChannelsRegistered.add(id);
    final completer = _readyCompleter ??= Completer<void>();
    final channelName = panelWindowChannel(id);
    _owners[channelName] = this;
    unawaited(
      backend
          .setChannelHandler(channelName, (method, args) async {
            if (method == 'panelMessage') {
              final message = _asMessage(args);
              if (message == null) return null;
              final panelId = message['panelId'];
              if (panelId is! String) return null;
              _panelListeners[panelId]?.call(message);
              return null;
            }
            onWindowControl?.call(method, _asArguments(args));
            return null;
          })
          .whenComplete(() {
            if (!completer.isCompleted) completer.complete();
          }),
    );
  }

  @override
  void sendToPanel(String panelId, Map<String, Object?> message) {
    final id = panelWindowIdResolver?.call(panelId);
    if (id == null) return;
    unawaited(
      backend.invokeChannel(panelWindowChannel(id), 'panelMessage', message),
    );
  }

  @override
  void sendToMain(String panelId, Map<String, Object?> message) {
    unawaited(
      backend.invokeChannel(panelIntentsChannel, 'panelMessage', message),
    );
  }

  @override
  void unregisterMainListener() {
    _mainListener = null;
    if (!isMainWindow) return;
    _mainChannelRegistered = false;
    unawaited(_releaseChannel(panelIntentsChannel));
  }

  @override
  void unregisterPanelListener(String panelId) {
    _panelListeners.remove(panelId);
  }

  @override
  void disposePanel(String panelId) {
    _panelListeners.remove(panelId);
    final id = windowId;
    if (isMainWindow || id == null) return;
    _panelChannelsRegistered.remove(id);
    unawaited(_releaseChannel(panelWindowChannel(id)));
  }

  @override
  Future<void> close() async {
    _mainListener = null;
    _panelListeners.clear();
    await _releaseChannel(panelIntentsChannel);
    final id = windowId;
    if (id != null) await _releaseChannel(panelWindowChannel(id));
  }

  /// Clears a channel only while this transport still owns it.
  Future<void> _releaseChannel(String channelName) async {
    final owners = _owners;
    if (!identical(owners[channelName], this)) return;
    owners.remove(channelName);
    await backend.clearChannelHandler(channelName);
  }

  Map<String, Object?>? _asMessage(Object? args) {
    if (args is! Map) return null;
    return {
      for (final entry in args.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  Map<Object?, Object?> _asArguments(Object? args) =>
      args is Map ? args : const {};
}
