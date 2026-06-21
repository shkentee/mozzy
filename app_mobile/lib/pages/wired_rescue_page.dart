import 'dart:async';

import 'package:flutter/material.dart';

import '../services/wr_foreground_service.dart';
import '../services/wr_wired_usb.dart';

typedef PrepareExclusiveUsb = Future<void> Function();

class WiredRescuePage extends StatefulWidget {
  const WiredRescuePage({
    super.key,
    WrWiredUsb? wired,
    PrepareExclusiveUsb? prepareExclusiveUsb,
  })  : _wiredOverride = wired,
        _prepareExclusiveUsbOverride = prepareExclusiveUsb;

  final WrWiredUsb? _wiredOverride;
  final PrepareExclusiveUsb? _prepareExclusiveUsbOverride;

  @override
  State<WiredRescuePage> createState() => _WiredRescuePageState();
}

class _WiredRescuePageState extends State<WiredRescuePage> {
  WrWiredUsb get _wired => widget._wiredOverride ?? WrWiredUsb();

  bool _busy = false;
  bool _exclusiveUsbReady = false;
  String _status = 'USB-Cでスマホとデバイスをつないでから確認してください';
  String? _usbDiagnostics;
  List<WrWiredFile> _files = const [];
  Timer? _rescueStatusTimer;

  String _fmtMB(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';

  Future<void> _defaultPrepareExclusiveUsb() async {
    await WrForegroundService.stopBackgroundSync();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await WrForegroundService.stop();
  }

  Future<void> _prepareExclusiveUsb() async {
    if (_exclusiveUsbReady) return;
    final prepare =
        widget._prepareExclusiveUsbOverride ?? _defaultPrepareExclusiveUsb;
    await prepare();
    _exclusiveUsbReady = true;
  }

  @override
  void initState() {
    super.initState();
    _wired.setKeepScreenOn(true).ignore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refresh();
      }
    });
  }

  @override
  void dispose() {
    _rescueStatusTimer?.cancel();
    _wired.setKeepScreenOn(false).ignore();
    super.dispose();
  }

  void _startRescueStatusPolling() {
    _rescueStatusTimer?.cancel();
    _pollRescueStatus();
    _rescueStatusTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollRescueStatus(),
    );
  }

  Future<void> _pollRescueStatus() async {
    try {
      final status = await _wired.getRescueStatus();
      if (!mounted) return;
      final progress = status.totalBytes <= 0
          ? ''
          : '（${_fmtMB(status.processedBytes)} / ${_fmtMB(status.totalBytes)}）';
      setState(() {
        _busy = status.running;
        _status =
            progress.isEmpty ? status.status : '${status.status} $progress';
      });
      if (!status.running) {
        _rescueStatusTimer?.cancel();
        _rescueStatusTimer = null;
      }
    } catch (_) {
      // Status polling is best-effort; user-visible errors come from start/list.
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'バックグラウンド同期を停止中...';
      _usbDiagnostics = null;
    });
    try {
      await _prepareExclusiveUsb();
      if (!mounted) return;
      setState(() => _status = 'USBデバイス確認中...');
      final pong = await _wired.ping().timeout(const Duration(seconds: 12));
      final files = await _wired
          .listRescueCandidates()
          .timeout(const Duration(seconds: 25));
      if (!mounted) return;
      setState(() {
        _files = files;
        _status = files.isEmpty
            ? '接続OK（$pong）。未救出の録音はありません'
            : '接続OK（$pong）。未救出 ${files.length}件見つかりました';
      });
    } catch (e) {
      if (!mounted) return;
      var diagnostics = '';
      try {
        diagnostics = await _wired.diagnoseUsb();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _status = 'USB確認エラー: $e';
        _usbDiagnostics = diagnostics.isEmpty ? null : diagnostics;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _queueAll() async {
    if (_busy) return;
    var serviceStarted = false;
    setState(() {
      _busy = true;
      _status = 'バックグラウンド同期を停止中...';
    });
    try {
      await _prepareExclusiveUsb();
      if (!mounted) return;
      await _wired
          .startQueueAllInBackground()
          .timeout(const Duration(seconds: 12));
      serviceStarted = true;
      setState(() {
        _status = 'USB救出をバックグラウンドで開始しました';
      });
      _startRescueStatusPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'USB救出エラー: $e');
    } finally {
      if (mounted && !serviceStarted) setState(() => _busy = false);
    }
  }

  Future<void> _queueOne(WrWiredFile file) async {
    if (_busy) return;
    var serviceStarted = false;
    setState(() {
      _busy = true;
      _status = 'バックグラウンド同期を停止中...';
    });
    try {
      await _prepareExclusiveUsb();
      if (!mounted) return;
      await _wired
          .startQueueOneInBackground(file.name)
          .timeout(const Duration(seconds: 12));
      serviceStarted = true;
      setState(() => _status = 'USB救出をバックグラウンドで開始しました: ${file.name}');
      _startRescueStatusPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'USB救出エラー: $e');
    } finally {
      if (mounted && !serviceStarted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes = _files.fold<int>(0, (sum, file) => sum + file.sizeBytes);
    return Scaffold(
      appBar: AppBar(
        title: const Text('USB救出'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '再確認',
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _status,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (_usbDiagnostics != null) ...[
            const SizedBox(height: 12),
            SelectableText(
              _usbDiagnostics!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          if (_busy) const LinearProgressIndicator(),
          const SizedBox(height: 16),
          if (_files.isEmpty || _usbDiagnostics != null) ...[
            Text(
              '画面を開くとUSB内の録音を自動で探します。接続し直した時だけ再読み込みしてください。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.usb),
              label: const Text('USB内を再読み込み'),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            '未救出の録音だけをスマホへ吸い出し、既存のDrive送信待ちキューに入れます。自動アップロードがONなら通常処理が順番に送信します。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy || _files.isEmpty ? null : _queueAll,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(_files.isEmpty
                ? '未救出だけ吸出して送信待ちに入れる'
                : '未救出だけ吸出して送信待ちに入れる（${_files.length}件 / ${_fmtMB(totalBytes)}）'),
          ),
          const SizedBox(height: 16),
          if (_files.isEmpty)
            const Text('USBで取得できる録音ファイルはまだ表示されていません。')
          else
            ..._files.map(
              (file) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.audiotrack),
                title: Text(file.name),
                subtitle: Text(_fmtMB(file.sizeBytes)),
                trailing: IconButton(
                  icon: const Icon(Icons.cloud_upload_outlined),
                  tooltip: 'このファイルを送信待ちに入れる',
                  onPressed: _busy ? null : () => _queueOne(file),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
