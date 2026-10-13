import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:ffi/ffi.dart';

const double defaultDpi = 96;

/// One monitor as reported by the operating system.
///
/// [bounds] and [workArea] are **physical** pixels in the virtual desktop
/// space, exactly as Win32 reports them, so monitors left/above the primary
/// one legitimately have negative coordinates. [scaleFactor] is the monitor
/// DPI divided by 96 (`PerMonitorV2`, as declared by the Windows runner
/// manifest). Layout geometry for detached panels is stored in this physical
/// space; dock widths inside the main window stay logical.
class DisplayInfo {
  const DisplayInfo({
    required this.deviceName,
    required this.bounds,
    required this.workArea,
    required this.scaleFactor,
    this.dpi = defaultDpi,
    this.isPrimary = false,
  });

  final String deviceName;
  final Rect bounds;
  final Rect workArea;
  final double scaleFactor;
  final double dpi;
  final bool isPrimary;

  /// Stable monitor identity (survives resolution/position changes).
  String get signature => deviceName.isEmpty ? 'display:unknown' : deviceName;

  /// Identity of the monitor *configuration* (device + geometry + scale).
  String get configurationSignature =>
      '$signature|${bounds.width.round()}x${bounds.height.round()}'
      '+${bounds.left.round()},${bounds.top.round()}'
      '@${scaleFactor.toStringAsFixed(2)}';

  Rect get logicalWorkArea => Rect.fromLTWH(
    workArea.left / scaleFactor,
    workArea.top / scaleFactor,
    workArea.width / scaleFactor,
    workArea.height / scaleFactor,
  );

  bool containsPoint(Offset point) => workArea.contains(point);

  double visibleFraction(Rect rect) {
    final area = rect.width * rect.height;
    if (area <= 0 || !area.isFinite) return 0;
    final intersection = rect.intersect(workArea);
    if (intersection.width <= 0 || intersection.height <= 0) return 0;
    return (intersection.width * intersection.height) / area;
  }

  Map<String, Object?> toJson() => {
    'deviceName': deviceName,
    'signature': signature,
    'configurationSignature': configurationSignature,
    'bounds': _rectToJson(bounds),
    'workArea': _rectToJson(workArea),
    'scaleFactor': scaleFactor,
    'dpi': dpi,
    'isPrimary': isPrimary,
  };

  factory DisplayInfo.fromJson(Map<String, Object?> json) => DisplayInfo(
    deviceName: json['deviceName'] as String? ?? '',
    bounds: _rectFromJson(json['bounds']),
    workArea: _rectFromJson(json['workArea']),
    scaleFactor: _positiveDouble(json['scaleFactor'], 1),
    dpi: _positiveDouble(json['dpi'], defaultDpi),
    isPrimary: json['isPrimary'] as bool? ?? false,
  );

  @override
  String toString() =>
      'DisplayInfo($signature, workArea=$workArea, scale=$scaleFactor, '
      'primary=$isPrimary)';
}

List<double> _rectToJson(Rect rect) => [
  rect.left,
  rect.top,
  rect.width,
  rect.height,
];

Rect _rectFromJson(Object? value) {
  if (value is! List || value.length < 4) return Rect.zero;
  final numbers = <double>[];
  for (final item in value.take(4)) {
    if (item is! num || !item.isFinite) return Rect.zero;
    numbers.add(item.toDouble());
  }
  return Rect.fromLTWH(numbers[0], numbers[1], numbers[2], numbers[3]);
}

double _positiveDouble(Object? value, double fallback) {
  if (value is! num || !value.isFinite || value <= 0) return fallback;
  return value.toDouble();
}

/// Read-only monitor information used by the layout foundation.
///
/// The abstraction exists so layout decisions can be tested deterministically
/// (monitor removed, monitor left/above, DPI change) without a real desktop and
/// without any multi-window plugin. It never touches CAD kernels, the document
/// or the command registry.
abstract class DisplayService {
  /// Monitors ordered primary first, then by position. May be empty when the
  /// platform cannot be queried - callers must treat that as "unknown" and
  /// leave stored geometry untouched instead of guessing a work area.
  List<DisplayInfo> get displays;

  bool get isAvailable;

  Future<void> refresh() async {}

  DisplayInfo? get primary {
    for (final display in displays) {
      if (display.isPrimary) return display;
    }
    return displays.isEmpty ? null : displays.first;
  }

  DisplayInfo? bySignature(String? signature) {
    if (signature == null || signature.isEmpty) return null;
    for (final display in displays) {
      if (display.configurationSignature == signature) return display;
    }
    return null;
  }

  DisplayInfo? byDevice(String? deviceName) {
    if (deviceName == null || deviceName.isEmpty) return null;
    for (final display in displays) {
      if (display.deviceName == deviceName) return display;
    }
    return null;
  }

  DisplayInfo? bestForRect(Rect rect, {double minVisibleFraction = 0.25}) {
    DisplayInfo? best;
    var bestFraction = 0.0;
    for (final display in displays) {
      final fraction = display.visibleFraction(rect);
      if (fraction > bestFraction) {
        bestFraction = fraction;
        best = display;
      }
    }
    if (best == null || bestFraction < minVisibleFraction) return null;
    return best;
  }
}

/// Fail-safe service used when the platform has no display information.
class UnavailableDisplayService extends DisplayService {
  UnavailableDisplayService();

  @override
  List<DisplayInfo> get displays => const [];

  @override
  bool get isAvailable => false;
}

/// Deterministic in-memory desktop used by tests and by headless tooling.
class FakeDisplayService extends DisplayService {
  FakeDisplayService(List<DisplayInfo> displays)
    : _displays = List<DisplayInfo>.unmodifiable(displays);

  FakeDisplayService.single({
    Size workAreaSize = const Size(1920, 1040),
    double scaleFactor = 1,
  }) : _displays = List<DisplayInfo>.unmodifiable([
         DisplayInfo(
           deviceName: r'\\.\DISPLAY1',
           bounds: Offset.zero & workAreaSize,
           workArea: Offset.zero & workAreaSize,
           scaleFactor: scaleFactor,
           dpi: defaultDpi * scaleFactor,
           isPrimary: true,
         ),
       ]);

  List<DisplayInfo> _displays;

  @override
  List<DisplayInfo> get displays => _displays;

  @override
  bool get isAvailable => true;

  void replaceDisplays(List<DisplayInfo> displays) {
    _displays = List<DisplayInfo>.unmodifiable(displays);
  }
}

/// Windows implementation backed by `user32.dll`/`shcore.dll` through FFI.
///
/// Read-only: it enumerates monitors, work areas, the primary flag and the
/// effective per-monitor DPI (`MDT_EFFECTIVE_DPI`). It never opens a window,
/// never talks to a kernel and never throws - a failure degrades to
/// [isAvailable] `false` with an empty list.
class WindowsDisplayService extends DisplayService {
  WindowsDisplayService() {
    _refreshSync();
  }

  List<DisplayInfo> _displays = const [];
  bool _available = false;
  Object? _lastError;

  Object? get lastError => _lastError;

  @override
  List<DisplayInfo> get displays => _displays;

  @override
  bool get isAvailable => _available;

  @override
  Future<void> refresh() async => _refreshSync();

  void _refreshSync() {
    if (!Platform.isWindows) {
      _displays = const [];
      _available = false;
      return;
    }
    try {
      final monitors = _enumerate();
      _displays = List<DisplayInfo>.unmodifiable(monitors);
      _available = monitors.isNotEmpty;
      _lastError = null;
    } catch (error) {
      _displays = const [];
      _available = false;
      _lastError = error;
    }
  }

  List<DisplayInfo> _enumerate() {
    final user32 = _library('user32.dll');
    final enumMonitors = user32
        .lookupFunction<_EnumDisplayMonitorsNative, _EnumDisplayMonitorsDart>(
          'EnumDisplayMonitors',
        );
    final getMonitorInfo = user32
        .lookupFunction<_GetMonitorInfoNative, _GetMonitorInfoDart>(
          'GetMonitorInfoW',
        );

    final raw = <_RawMonitor>[];
    final callback = NativeCallable<_MonitorEnumProcNative>.isolateLocal((
      int monitor,
      int deviceContext,
      Pointer<_Rect> rect,
      int data,
    ) {
      final info = calloc.allocate<_MonitorInfoEx>(sizeOf<_MonitorInfoEx>());
      try {
        info.ref.cbSize = sizeOf<_MonitorInfoEx>();
        if (getMonitorInfo(monitor, info) != 0) {
          raw.add(
            _RawMonitor(
              handle: monitor,
              monitor: info.ref.rcMonitor.toRect(),
              work: info.ref.rcWork.toRect(),
              isPrimary: (info.ref.dwFlags & _monitorInfoPrimary) != 0,
              deviceName: _deviceName(info.ref),
            ),
          );
        }
      } finally {
        calloc.free(info);
      }
      return 1;
    }, exceptionalReturn: 0);

    try {
      enumMonitors(0, nullptr, callback.nativeFunction, 0);
    } finally {
      callback.close();
    }
    if (raw.isEmpty) return const [];

    final systemScale = _systemScaleFactor(user32);
    final dpiForMonitor = _dpiForMonitor();
    final displays = <DisplayInfo>[];
    for (final monitor in raw) {
      final dpi = dpiForMonitor == null
          ? defaultDpi * systemScale
          : _effectiveDpi(dpiForMonitor, monitor.handle);
      final scale = dpi <= 0 ? systemScale : dpi / defaultDpi;
      displays.add(
        DisplayInfo(
          deviceName: monitor.deviceName,
          bounds: monitor.monitor,
          workArea: monitor.work,
          scaleFactor: scale,
          dpi: dpi <= 0 ? defaultDpi * scale : dpi,
          isPrimary: monitor.isPrimary,
        ),
      );
    }
    displays.sort((first, second) {
      if (first.isPrimary != second.isPrimary) return first.isPrimary ? -1 : 1;
      final byLeft = first.bounds.left.compareTo(second.bounds.left);
      if (byLeft != 0) return byLeft;
      return first.bounds.top.compareTo(second.bounds.top);
    });
    return displays;
  }

  static final Map<String, DynamicLibrary> _libraries = {};

  static DynamicLibrary _library(String name) =>
      _libraries.putIfAbsent(name, () => DynamicLibrary.open(name));

  static DynamicLibrary? _dpiForMonitor() {
    if (!Platform.isWindows) return null;
    try {
      return _library('shcore.dll');
    } catch (_) {
      return null;
    }
  }

  static double _systemScaleFactor(DynamicLibrary user32) {
    try {
      final getDpiForSystem = user32
          .lookupFunction<Uint32 Function(), int Function()>('GetDpiForSystem');
      final dpi = getDpiForSystem();
      if (dpi <= 0) return 1;
      return dpi / defaultDpi;
    } catch (_) {
      return 1;
    }
  }

  static double _effectiveDpi(DynamicLibrary shcore, int monitorHandle) {
    final getDpiForMonitor = shcore
        .lookupFunction<_GetDpiForMonitorNative, _GetDpiForMonitorDart>(
          'GetDpiForMonitor',
        );
    final x = calloc.allocate<Uint32>(sizeOf<Uint32>());
    final y = calloc.allocate<Uint32>(sizeOf<Uint32>());
    try {
      final result = getDpiForMonitor(monitorHandle, _mdtEffectiveDpi, x, y);
      if (result != 0) return 0;
      return x.value.toDouble();
    } catch (_) {
      return 0;
    } finally {
      calloc.free(x);
      calloc.free(y);
    }
  }

  static String _deviceName(_MonitorInfoEx info) {
    final units = <int>[];
    for (var index = 0; index < _deviceNameLength; index++) {
      final unit = info.szDevice[index];
      if (unit == 0) break;
      units.add(unit);
    }
    return String.fromCharCodes(units);
  }
}

/// Creates the platform display service without touching CAD services.
DisplayService createPlatformDisplayService() {
  if (Platform.isWindows) return WindowsDisplayService();
  return UnavailableDisplayService();
}

const int _monitorInfoPrimary = 0x1;
const int _mdtEffectiveDpi = 0;
const int _deviceNameLength = 32;

class _RawMonitor {
  const _RawMonitor({
    required this.handle,
    required this.monitor,
    required this.work,
    required this.isPrimary,
    required this.deviceName,
  });

  final int handle;
  final Rect monitor;
  final Rect work;
  final bool isPrimary;
  final String deviceName;
}

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;

  Rect toRect() => Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

final class _MonitorInfoEx extends Struct {
  @Uint32()
  external int cbSize;
  external _Rect rcMonitor;
  external _Rect rcWork;
  @Uint32()
  external int dwFlags;
  @Array(32)
  external Array<Uint16> szDevice;
}

typedef _MonitorEnumProcNative =
    Int32 Function(IntPtr, IntPtr, Pointer<_Rect>, IntPtr);
typedef _EnumDisplayMonitorsNative =
    Int32 Function(
      IntPtr,
      Pointer<_Rect>,
      Pointer<NativeFunction<_MonitorEnumProcNative>>,
      IntPtr,
    );
typedef _EnumDisplayMonitorsDart =
    int Function(
      int,
      Pointer<_Rect>,
      Pointer<NativeFunction<_MonitorEnumProcNative>>,
      int,
    );
typedef _GetMonitorInfoNative = Int32 Function(IntPtr, Pointer<_MonitorInfoEx>);
typedef _GetMonitorInfoDart = int Function(int, Pointer<_MonitorInfoEx>);
typedef _GetDpiForMonitorNative =
    Int32 Function(IntPtr, Int32, Pointer<Uint32>, Pointer<Uint32>);
typedef _GetDpiForMonitorDart =
    int Function(int, int, Pointer<Uint32>, Pointer<Uint32>);

/// Axis-aligned helpers shared by recovery/planner code.
Rect clampRectInto(Rect rect, Rect workArea, {double margin = 0}) {
  final minLeft = workArea.left + margin;
  final minTop = workArea.top + margin;
  final maxRight = math.max(minLeft, workArea.right - margin);
  final maxBottom = math.max(minTop, workArea.bottom - margin);
  final width = math.min(rect.width, maxRight - minLeft);
  final height = math.min(rect.height, maxBottom - minTop);
  final left = rect.left
      .clamp(minLeft, math.max(minLeft, maxRight - width))
      .toDouble();
  final top = rect.top
      .clamp(minTop, math.max(minTop, maxBottom - height))
      .toDouble();
  return Rect.fromLTWH(left, top, width, height);
}
