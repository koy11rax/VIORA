import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../domain/tunnel_config.dart';

enum TunnelPhase {
  unavailable,
  disconnected,
  permission,
  connecting,
  active,
  stopping,
  failed,
}

class TunnelStats {
  final String state, duration;
  final String? errorCode;
  final int upload, download;
  final bool alwaysOn, lockdown;
  const TunnelStats(
    this.state, {
    this.duration = '00:00:00',
    this.upload = 0,
    this.download = 0,
    this.errorCode,
    this.alwaysOn = false,
    this.lockdown = false,
  });
}

TunnelEngine platformTunnelEngine() =>
    Platform.isAndroid ? AndroidXrayEngine() : DesktopXrayEngine();

class DesktopXrayEngine implements TunnelEngine {
  static const channel = MethodChannel('dev.viora/platform');
  final _events = StreamController<TunnelStats>.broadcast();
  Timer? _poll;
  bool _polling = false, _initialized = false;
  Process? _process;
  @override
  bool get supported => Platform.isWindows || Platform.isLinux;
  @override
  Stream<TunnelStats> get events => _events.stream;
  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (Platform.isWindows) {
      _poll = Timer.periodic(const Duration(milliseconds: 200), (_) async {
        if (_polling) return;
        _polling = true;
        try {
          final lines = await channel.invokeMethod<String>('desktopTunnelPoll');
          for (final line in const LineSplitter().convert(lines ?? '')) {
            _receive(line);
          }
        } catch (_) {
          _events.add(const TunnelStats('FAILED', errorCode: 'ipc_failed'));
          _poll?.cancel();
        } finally {
          _polling = false;
        }
      });
    }
  }

  void _receive(String line) {
    try {
      if (line.length > 4096) throw const FormatException();
      final data = jsonDecode(line) as Map<String, dynamic>;
      final state = data['state'] as String;
      if (![
        'CONNECTING',
        'CONNECTED',
        'DISCONNECTED',
        'FAILED',
      ].contains(state)) {
        throw const FormatException();
      }
      _events.add(
        TunnelStats(
          state,
          duration: data['duration'] as String? ?? '00:00:00',
          upload: data['upload'] as int? ?? 0,
          download: data['download'] as int? ?? 0,
          errorCode: data['code'] as String?,
        ),
      );
    } catch (_) {
      _events.add(const TunnelStats('FAILED', errorCode: 'ipc_failed'));
    }
  }

  @override
  Future<bool> requestPermission() async => supported;
  @override
  Future<void> start(TunnelConfig config, String name) async {
    // Android package IDs must never silently become an all-app desktop VPN.
    if (config.allowedApps != null || config.excludedApps.isNotEmpty) {
      _events.add(
        const TunnelStats('FAILED', errorCode: 'app_rules_unsupported'),
      );
      return;
    }
    final json = jsonEncode(config.json);
    if (Platform.isWindows) {
      await channel.invokeMethod<void>('desktopTunnelStart', {'config': json});
      return;
    }
    if (_process != null) throw StateError('Tunnel still stopping');
    final process = await Process.start(
      '/usr/bin/pkexec',
      ['/usr/lib/viora/viora_tunnel'],
      includeParentEnvironment: false,
      environment: {
        for (final key in [
          'DISPLAY',
          'WAYLAND_DISPLAY',
          'XAUTHORITY',
          'DBUS_SESSION_BUS_ADDRESS',
          'XDG_RUNTIME_DIR',
        ])
          if (Platform.environment[key] != null)
            key: Platform.environment[key]!,
      },
    );
    _process = process;
    bool terminal = false;
    String? disconnected;
    final outputDone = Completer<void>();
    final output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.contains('DISCONNECTED')) {
              disconnected = line;
            } else {
              if (line.contains('FAILED')) terminal = true;
              _receive(line);
            }
          },
          onDone: () {
            if (!outputDone.isCompleted) outputDone.complete();
          },
          onError: (Object _) {
            terminal = true;
            _events.add(const TunnelStats('FAILED', errorCode: 'ipc_failed'));
            if (!outputDone.isCompleted) outputDone.complete();
          },
        );
    process.stderr
        .drain<void>(); // Never expose core/profile payloads in the UI.
    process.stdin.writeln(json);
    await process.stdin.flush();
    unawaited(() async {
      final exit = await process.exitCode;
      await outputDone.future;
      await output.cancel();
      if (identical(_process, process)) _process = null;
      if (disconnected != null) {
        _receive(disconnected!);
      } else if (!terminal) {
        _events.add(
          TunnelStats(
            'FAILED',
            errorCode: exit == 126 || exit == 127
                ? 'permission_denied'
                : 'helper_exited',
          ),
        );
      }
    }());
  }

  @override
  Future<void> stop() async {
    if (Platform.isWindows) {
      await channel.invokeMethod<void>('desktopTunnelStop');
    } else if (_process != null) {
      _process!.stdin.writeln('{"stop":true}');
      await _process!.stdin.flush();
    } else {
      _events.add(const TunnelStats('DISCONNECTED'));
    }
  }
}

abstract interface class TunnelEngine {
  bool get supported;
  Stream<TunnelStats> get events;
  Future<void> initialize();
  Future<bool> requestPermission();
  Future<void> start(TunnelConfig config, String name);
  Future<void> stop();
}

class AndroidXrayEngine implements TunnelEngine {
  static const channel = MethodChannel('flutter_v2ray_client');
  static const statusChannel = EventChannel('flutter_v2ray_client/status');
  @override
  bool get supported => Platform.isAndroid;
  @override
  Stream<TunnelStats> get events =>
      statusChannel.receiveBroadcastStream().map(decodeStatus);

  static TunnelStats decodeStatus(dynamic event) {
    final data = List<dynamic>.from(event as List);
    if (data.length < 6 || data.length > 9) {
      throw const FormatException('VPN status');
    }
    return TunnelStats(
      data[5] as String,
      duration: data[0] as String,
      upload: int.parse(data[3].toString()),
      download: int.parse(data[4].toString()),
      errorCode: data.length > 6 && data[6] != '' ? data[6] as String : null,
      alwaysOn: data.length > 7 && data[7] == 'true',
      lockdown: data.length > 8 && data[8] == 'true',
    );
  }

  @override
  Future<void> initialize() => channel.invokeMethod('initializeV2Ray', {
    'notificationIconResourceType': 'drawable',
    'notificationIconResourceName': 'ic_vpn_notification',
  });
  @override
  Future<bool> requestPermission() async =>
      await channel.invokeMethod<bool>('requestPermission') ?? false;
  @override
  Future<void> start(TunnelConfig config, String name) =>
      channel.invokeMethod('startV2Ray', {
        'remark': name,
        'config': jsonEncode(config.json),
        'proxy_only': false,
        'allowed_apps': config.allowedApps,
        'blocked_apps': config.excludedApps,
        'bypass_subnets': null,
        'mtu': config.mtu,
        'reconnect': config.reconnect,
        'retries': config.retries,
        'require_lockdown': config.requireLockdown,
        'notificationDisconnectButtonName': 'Отключить',
      });
  @override
  Future<void> stop() => channel.invokeMethod('stopV2Ray');
}

class TunnelController extends ChangeNotifier {
  final TunnelEngine engine;
  TunnelController(this.engine);
  TunnelPhase phase = TunnelPhase.disconnected;
  TunnelStats stats = const TunnelStats('DISCONNECTED');
  String? error, activeProfile;
  StreamSubscription<TunnelStats>? _subscription;
  Timer? _deadline;
  Completer<void>? _stopAcknowledgement;
  Future<void>? _initializing;
  bool _disposed = false,
      _operation = false,
      _ready = false,
      _switching = false;
  bool get running =>
      phase == TunnelPhase.active || phase == TunnelPhase.connecting;
  bool get busy => _switching || _baseBusy;
  bool get _baseBusy =>
      _operation ||
      phase == TunnelPhase.permission ||
      phase == TunnelPhase.stopping;
  String get label => switch (phase) {
    TunnelPhase.active => 'VPN включён',
    TunnelPhase.permission => 'Разрешение Android',
    TunnelPhase.connecting => 'Запускаем VPN…',
    TunnelPhase.stopping => 'Отключаем…',
    TunnelPhase.failed => 'Не удалось включить VPN',
    TunnelPhase.unavailable => 'VPN недоступен на этой платформе',
    _ => 'Не подключено',
  };
  void _change(TunnelPhase value) {
    if (_disposed) return;
    phase = value;
    notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    if (!engine.supported) {
      _change(TunnelPhase.unavailable);
      return;
    }
    try {
      await _subscription?.cancel();
      _subscription = engine.events.listen(
        _receive,
        onError: (Object _) {
          error = 'Не удалось получить состояние VPN. Перезапусти приложение.';
          _change(TunnelPhase.failed);
        },
      );
      await engine.initialize();
      _ready = true;
    } catch (_) {
      error = 'Не удалось подготовить VPN-движок';
      _change(TunnelPhase.failed);
      _initializing = null;
    }
  }

  void _receive(TunnelStats value) {
    if (_disposed) return;
    stats = value;
    if (value.state == 'FAILED') {
      _deadline?.cancel();
      error = switch (value.errorCode) {
        'lockdown_required' =>
          'Для строгой защиты включи в настройках Android «Постоянный VPN» и «Блокировать соединения без VPN» для VIORA.',
        'restart_state_failed' =>
          'Не удалось сохранить защищённое подключение. Открой VIORA после разблокировки телефона и повтори.',
        'reconnect_exhausted' =>
          'Не удалось восстановить VPN. Проверь сеть или выбери другой сервер.',
        'permission_denied' =>
          'Для создания VPN нужно системное разрешение. Подтверди запрос при подключении.',
        'service_unavailable' =>
          'Служба VIORA не запущена. Установи новую версию через установщик и перезапусти приложение.',
        'core_integrity' || 'helper_missing' =>
          'Установи Viora через установщик: VPN-компонент отсутствует или повреждён.',
        'app_rules_unsupported' =>
          'Для этой версии ПК выбери режим «Все приложения». Фильтр приложений пока доступен на Android.',
        'core_start_timeout' || 'helper_timeout' =>
          'VPN не запустился вовремя. Проверь системный запрос и повтори подключение.',
        _ => 'VPN-компонент остановился. Проверь подключение и повтори запуск.',
      };
      _change(TunnelPhase.failed);
    } else if (value.state == 'CONNECTED') {
      if (phase == TunnelPhase.stopping) return;
      if (phase == TunnelPhase.failed) {
        unawaited(_cleanupFailedService());
        return;
      }
      _deadline?.cancel();
      error = null;
      _change(TunnelPhase.active);
    } else if (value.state == 'CONNECTING') {
      if (phase != TunnelPhase.stopping) _change(TunnelPhase.connecting);
    } else if (value.state == 'DISCONNECTED') {
      if (_stopAcknowledgement?.isCompleted == false) {
        _stopAcknowledgement!.complete();
      }
      if (phase == TunnelPhase.permission || phase == TunnelPhase.connecting) {
        return;
      }
      if (phase != TunnelPhase.failed) {
        _deadline?.cancel();
        activeProfile = null;
        _change(TunnelPhase.disconnected);
      }
    }
  }

  Future<void> _cleanupFailedService() async {
    _operation = true;
    try {
      await engine.stop();
    } catch (_) {
    } finally {
      _operation = false;
    }
  }

  Future<void> connect(
    TunnelConfig config,
    String name, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_switching) return;
    await _connect(config, name, timeout: timeout);
  }

  Future<void> switchServer(
    TunnelConfig config,
    String name, {
    Duration timeout = const Duration(seconds: 15),
    Duration stopTimeout = const Duration(seconds: 5),
  }) async {
    if (busy || !running || _disposed) return;
    _switching = true;
    // Subscribe before stop: native stop may acknowledge synchronously.
    final stopped = Completer<void>();
    void listen() {
      if (!stopped.isCompleted &&
          (phase == TunnelPhase.disconnected || phase == TunnelPhase.failed)) {
        stopped.complete();
      }
    }

    addListener(listen);
    try {
      await _disconnect();
      await stopped.future.timeout(stopTimeout);
      if (phase != TunnelPhase.disconnected || _disposed) return;
      await _connect(config, name, timeout: timeout);
    } on TimeoutException {
      error =
          'Не удалось подтвердить остановку прежнего сервера. Повтори подключение.';
      _change(TunnelPhase.failed);
    } finally {
      removeListener(listen);
      _switching = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _connect(
    TunnelConfig config,
    String name, {
    required Duration timeout,
  }) async {
    if (_baseBusy || running || _disposed) return;
    _operation = true;
    try {
      await initialize();
      if (phase == TunnelPhase.unavailable || !_ready || _disposed) return;
      if (phase == TunnelPhase.failed && stats.state != 'DISCONNECTED') {
        _stopAcknowledgement = Completer<void>();
        await engine.stop();
        await _stopAcknowledgement!.future.timeout(const Duration(seconds: 5));
        _stopAcknowledgement = null;
      }
      error = null;
      _change(TunnelPhase.permission);
      if (!await engine.requestPermission()) {
        _change(TunnelPhase.disconnected);
        error = 'Разрешение на VPN не выдано';
        return;
      }
      if (_disposed) return;
      activeProfile = name;
      stats = const TunnelStats('CONNECTING');
      _change(TunnelPhase.connecting);
      final startupTimeout =
          engine is DesktopXrayEngine && timeout.inSeconds < 60
          ? const Duration(seconds: 60)
          : timeout;
      _deadline = Timer(startupTimeout, () async {
        if (phase != TunnelPhase.connecting) return;
        error = 'VPN не запустился вовремя. Проверь профиль и повтори.';
        _change(TunnelPhase.failed);
        await _cleanupFailedService();
      });
      await engine.start(config, name);
      // A successful method call only starts the service. Native events confirm TUN startup.
    } catch (_) {
      _deadline?.cancel();
      error =
          'Не удалось запустить VPN. Проверь профиль и системное разрешение.';
      _change(TunnelPhase.failed);
      try {
        await engine.stop();
      } catch (_) {}
    } finally {
      _operation = false;
    }
  }

  Future<void> disconnect() async {
    if (_switching) return;
    await _disconnect();
  }

  Future<void> _disconnect() async {
    if (_baseBusy || _disposed || !engine.supported) return;
    _operation = true;
    _deadline?.cancel();
    _change(TunnelPhase.stopping);
    try {
      // Wait for the native disconnected event, including notification disconnects.
      _deadline = Timer(const Duration(seconds: 5), () {
        if (phase == TunnelPhase.stopping) {
          error = 'Отключение пока не подтверждено VPN-компонентом';
          _change(TunnelPhase.failed);
        }
      });
      await engine.stop();
    } catch (_) {
      error = 'Не удалось подтвердить отключение VPN';
      _change(TunnelPhase.failed);
    } finally {
      _operation = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _deadline?.cancel();
    _subscription?.cancel();
    // The foreground service outlives the screen; closing UI must not silently stop VPN.
    super.dispose();
  }
}
