import 'package:flutter/material.dart';

import '../services/wr_foreground_service.dart';
import '../services/wr_upload_outbox.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refresh();
      }
    });
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
      final pong = await _wired.ping();
      final files = await _wired.listFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _status = files.isEmpty
            ? '接続OK（$pong）。送信対象ファイルはありません'
            : '接続OK（$pong）。${files.length}件見つかりました';
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
    setState(() {
      _busy = true;
      _status = 'バックグラウンド同期を停止中...';
    });
    try {
      await _prepareExclusiveUsb();
      if (!mounted) return;
      setState(() => _status = 'USB吸出しを開始します...');
      final queued = await _wired.fetchAndQueueAll(
        onProgress: (message) {
          if (!mounted) return;
          setState(() => _status = message);
        },
      );
      final files = await _wired.listFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _status = queued == 0
            ? 'USB吸出し完了: すべて送信待ちに登録済みです'
            : 'USB吸出し完了: $queued件を送信待ちに入れました';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'USB救出エラー: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _queueOne(WrWiredFile file) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'バックグラウンド同期を停止中...';
    });
    try {
      await _prepareExclusiveUsb();
      if (!mounted) return;
      setState(() => _status = '録音を一時停止中...');
      await _wired.pauseRecording();
      late String resultStatus;
      try {
        setState(() => _status = 'USB吸出し中: ${file.name}');
        final local = await _wired.fetchToTemp(file);
        final queued = await const WrUploadOutbox().enqueue(
          local,
          file.name,
          deleteSource: true,
        );
        if (!mounted) return;
        resultStatus = queued.alreadyQueued
            ? '送信待ちに登録済み: ${queued.name}'
            : '送信待ちへ追加: ${queued.name}';
      } finally {
        if (mounted) setState(() => _status = '録音を再開中...');
        await _wired.resumeRecording();
      }
      if (mounted) {
        setState(() => _status = resultStatus);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'USB救出エラー: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
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
            '見つかった録音をスマホへ吸い出し、既存のDrive送信待ちキューに入れます。自動アップロードがONなら通常処理が順番に送信します。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy || _files.isEmpty ? null : _queueAll,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(_files.isEmpty
                ? 'スマホへ吸出して送信待ちに入れる'
                : 'スマホへ吸出して送信待ちに入れる（${_files.length}件 / ${_fmtMB(totalBytes)}）'),
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
