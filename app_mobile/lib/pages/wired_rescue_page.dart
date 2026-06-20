import 'package:flutter/material.dart';

import '../services/wr_drive_uploader.dart';
import '../services/wr_foreground_service.dart';
import '../services/wr_wired_usb.dart';

typedef PrepareExclusiveUsb = Future<void> Function();

class WiredRescuePage extends StatefulWidget {
  const WiredRescuePage({
    super.key,
    WrWiredUsb? wired,
    WrDriveUploader? uploader,
    PrepareExclusiveUsb? prepareExclusiveUsb,
  })  : _wiredOverride = wired,
        _uploaderOverride = uploader,
        _prepareExclusiveUsbOverride = prepareExclusiveUsb;

  final WrWiredUsb? _wiredOverride;
  final WrDriveUploader? _uploaderOverride;
  final PrepareExclusiveUsb? _prepareExclusiveUsbOverride;

  @override
  State<WiredRescuePage> createState() => _WiredRescuePageState();
}

class _WiredRescuePageState extends State<WiredRescuePage> {
  WrWiredUsb get _wired => widget._wiredOverride ?? WrWiredUsb();
  WrDriveUploader get _uploader =>
      widget._uploaderOverride ?? WrDriveUploader();

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

  Future<void> _rescueAll() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'バックグラウンド同期を停止中...';
    });
    try {
      await _prepareExclusiveUsb();
      if (!mounted) return;
      setState(() => _status = 'USB救出を開始します...');
      final uploaded = await _wired.fetchAndUploadAll(
        uploader: _uploader,
        onProgress: (message) {
          if (!mounted) return;
          setState(() => _status = message);
        },
      );
      final files = await _wired.listFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _status = 'USB救出完了: $uploaded件をDriveへ送信しました';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'USB救出エラー: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rescueOne(WrWiredFile file) async {
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
      try {
        setState(() => _status = 'USB吸出し中: ${file.name}');
        final local = await _wired.fetchToTemp(file);
        try {
          setState(() => _status = 'Drive送信中: ${file.name}');
          final id = await _uploader.uploadIfNew(local, file.name);
          if (!mounted) return;
          setState(() => _status =
              id == null ? '送信済みです: ${file.name}' : 'Drive送信完了: ${file.name}');
        } finally {
          try {
            await local.delete();
          } catch (_) {}
        }
      } finally {
        if (mounted) setState(() => _status = '録音を再開中...');
        await _wired.resumeRecording();
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
          FilledButton.icon(
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.usb),
            label: const Text('USB接続を確認'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy || _files.isEmpty ? null : _rescueAll,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: Text(_files.isEmpty
                ? 'Driveへ一括送信'
                : 'Driveへ一括送信（${_files.length}件 / ${_fmtMB(totalBytes)}）'),
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
                  tooltip: 'このファイルをDriveへ送信',
                  onPressed: _busy ? null : () => _rescueOne(file),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
