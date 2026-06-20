import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_drive_uploader.dart';
import '../services/wr_foreground_service.dart';
import '../services/wr_led_settings.dart';
import '../services/wr_sd_sync.dart';
import '../services/wr_sync_schedule.dart';
import '../widgets/brand.dart';
import 'drive_files_page.dart';
import 'recordings_page.dart';
import 'settings_page.dart';
import 'storage_page.dart';
import 'transcripts_page.dart';
import 'wired_rescue_page.dart';

/// SharedPreferences key used to persist the last-connected device address.
const _kLastDeviceId = 'wr_last_device_id';
const _micGainLabels = [
  'Mute',
  '-20dB',
  '-10dB',
  '+0dB',
  '+6dB',
  '+10dB',
  '+20dB',
  '+30dB',
  '+40dB',
];

class DevicePage extends StatefulWidget {
  const DevicePage({
    super.key,
    required this.device,
    WrDriveUploader? uploader,
  }) : uploaderOverride = uploader;

  final WrBleDevice device;
  // Allow injection in tests; production code uses the default instance.
  final WrDriveUploader? uploaderOverride;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> with WidgetsBindingObserver {
  String _status = 'connecting…';
  int _packets = 0;
  int _savedBytes = 0;
  int _lostPackets = 0;
  int? _batteryPct; // null until first Battery Service notify/read
  double _level = 0.0; // live mic level 0..1
  final List<double> _levels = []; // rolling buffer for the live waveform
  bool _liveMonitor = false; // live audio subscription (off by default; power)
  bool? _recording; // device SD recording on/off; null = unsupported firmware
  int? _micGainLevel; // Mic gain level 0..8; null = unsupported firmware
  bool _driveUploadAuto = true;
  SyncSchedule _schedule = const SyncSchedule();
  WrSdSync? _sdSync;
  String? _syncStatus; // last SD-sync event, shown in the UI
  WrSyncProgress? _syncProg; // live backlog / pull progress, shown in the UI
  WrUploadStatus? _driveStatus; // Drive upload queue state
  WrLedSettings _ledSettings = WrLedSettings.defaults;
  String? _ledStatus;
  bool _serviceHandoffActive = false;
  bool _serviceHandoffBusy = false;

  WrDriveUploader get _uploader => widget.uploaderOverride ?? WrDriveUploader();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.device.state.listen((s) {
      if (!mounted) return;
      setState(() => _status = s.name);
      if (s == BluetoothConnectionState.disconnected) {
        if (!_serviceHandoffActive) {
          WrForegroundService.stop().ignore();
        }
        _sdSync?.stop();
      }
    });
    widget.device.packetCount.listen((n) {
      if (!mounted) return;
      setState(() => _packets = n);
      if (n % 100 == 0 && n > 0) {
        WrForegroundService.update(
          '${widget.device.name} · $n packets',
        ).ignore();
      }
    });
    widget.device.bytesSaved.listen((n) {
      if (!mounted) return;
      setState(() => _savedBytes = n);
    });
    widget.device.lostPackets.listen((n) {
      if (!mounted) return;
      setState(() => _lostPackets = n);
    });
    widget.device.batteryLevel.listen((pct) {
      if (!mounted) return;
      setState(() => _batteryPct = pct);
    });
    widget.device.audioLevel.listen((lvl) {
      if (!mounted) return;
      setState(() {
        _level = lvl;
        _levels.add(lvl);
        if (_levels.length > 96) _levels.removeAt(0);
      });
    });
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state.name == 'hidden') {
      unawaited(_handoffSyncToService());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_resumeSyncFromService());
    }
  }

  Future<void> _handoffSyncToService() async {
    if (_serviceHandoffBusy ||
        _serviceHandoffActive ||
        _status != 'connected') {
      return;
    }
    _serviceHandoffBusy = true;
    _serviceHandoffActive = true;
    if (mounted) {
      setState(() => _syncStatus = 'バックグラウンド同期へ引き継ぎ中');
    }
    try {
      await WrForegroundService.start(widget.device.name);
      await _sdSync?.dispose();
      _sdSync = null;
      await widget.device.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await WrForegroundService.startBackgroundSync(
        deviceId: widget.device.id,
        deviceName: widget.device.name,
      );
      if (mounted) {
        setState(() {
          _status = 'background';
          _syncStatus = 'バックグラウンド同期中';
        });
      }
    } catch (e) {
      _serviceHandoffActive = false;
      if (mounted) setState(() => _syncStatus = 'バックグラウンド同期エラー: $e');
    } finally {
      _serviceHandoffBusy = false;
    }
  }

  Future<void> _resumeSyncFromService() async {
    if (!_serviceHandoffActive || _serviceHandoffBusy) return;
    _serviceHandoffBusy = true;
    if (mounted) setState(() => _status = 'connecting…');
    try {
      await WrForegroundService.stopBackgroundSync();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await WrForegroundService.stop();
      _serviceHandoffActive = false;
      await _connect();
    } catch (e) {
      if (mounted) setState(() => _status = 'error: $e');
    } finally {
      _serviceHandoffBusy = false;
    }
  }

  Future<void> _init() async {
    await _loadSyncSettings();
    await _loadLedSettings();
    await _connect();
  }

  Future<void> _loadSyncSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final schedule = await SyncSchedule.load();
    if (!mounted) return;
    setState(() {
      _driveUploadAuto = prefs.getBool(kDriveUploadAutoKey) ?? true;
      _schedule = schedule;
    });
  }

  Future<void> _loadLedSettings() async {
    final settings = await WrLedSettings.load();
    if (!mounted) return;
    setState(() => _ledSettings = settings);
  }

  Future<void> _connect() async {
    try {
      await widget.device.connect();
      await WrForegroundService.start(widget.device.name);
      // Persist the device address so ScanPage can auto-reconnect next launch.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastDeviceId, widget.device.id);
      // Reflect the device's current recording on/off state (if supported).
      final rec = await widget.device.readRecordingState();
      if (mounted) setState(() => _recording = rec);
      // Reflect the device's current mic gain (if supported).
      final gain = await widget.device.readMicGainLevel();
      if (mounted) setState(() => _micGainLevel = gain);
      await _applyLedSettings();
      // Start SD pull + Drive upload service. Modes decide whether each side
      // runs automatically or waits for a card button.
      _startSdSync();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'error: $e');
    }
  }

  Future<void> _applyLedSettings() async {
    if (_status != 'connected') return;
    try {
      final ok = await widget.device.setLedSettings(_ledSettings);
      if (!mounted) return;
      setState(() {
        _ledStatus = ok ? 'デバイスへ反映済み' : 'このファームはLED設定に未対応です';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ledStatus = 'LED設定の反映に失敗しました: $e';
      });
    }
  }

  /// Starts the background SD-pull + Drive-upload coordinator.
  void _startSdSync() {
    _sdSync?.stop();
    _sdSync = null;
    final sync = WrSdSync(device: widget.device, uploader: _uploader);
    sync.events.listen((msg) {
      if (mounted) setState(() => _syncStatus = msg);
    });
    sync.progress.listen((p) {
      if (mounted) setState(() => _syncProg = p);
    });
    sync.uploadStatus.listen((s) {
      if (mounted) setState(() => _driveStatus = s);
    });
    sync.start();
    _sdSync = sync;
    if (mounted) setState(() {});
  }

  String _fmtMB(int b) => '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';

  double _progressValue(int done, int total) {
    if (total <= 0) return 0;
    return (done / total).clamp(0.0, 1.0);
  }

  String _progressText(int done, int total) {
    final pct = _progressValue(done, total) * 100;
    return '${_fmtMB(done)} / ${_fmtMB(total)}  ${pct.toStringAsFixed(0)}%完了';
  }

  String _pullModeText() => switch (_schedule.mode) {
        SyncMode.manual => '手動',
        SyncMode.scheduledTime =>
          'タイマー：毎日 ${SyncSchedule.fmtHm(_schedule.timeMinutes)}（BG対応）',
        SyncMode.intervalWindow =>
          'タイマー：${SyncSchedule.fmtHm(_schedule.windowStartMin)}〜${SyncSchedule.fmtHm(_schedule.windowEndMin)} / ${_schedule.intervalMin}分間隔（BG対応）',
        SyncMode.continuous => '自動：常時（BG対応）',
      };

  Widget _sectionTitle({
    required IconData icon,
    required String title,
    required String mode,
  }) {
    final cs = Theme.of(context).colorScheme;
    final dim = cs.onSurface.withOpacity(0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: cs.secondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: cs.secondary.withOpacity(0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            mode,
            softWrap: true,
            style: TextStyle(fontSize: 12, color: dim),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBlock({
    required int done,
    required int total,
    required String status,
  }) {
    final dim = Theme.of(context).colorScheme.onSurface.withOpacity(0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(status, style: TextStyle(fontSize: 13, color: dim)),
        const SizedBox(height: 8),
        GradientProgressBar(value: _progressValue(done, total), height: 8),
        const SizedBox(height: 6),
        Text(_progressText(done, total),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }

  Widget _statusNote(String text) {
    final cs = Theme.of(context).colorScheme;
    final fg = cs.onSurface.withOpacity(0.72);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.secondary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.secondary.withOpacity(0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: cs.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: fg)),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncStatus() {
    final p = _syncProg;
    final done = p?.synced ?? 0;
    final total = p?.committed ?? 0;
    final status = p == null
        ? '待機中${_syncStatus == null ? '' : '（$_syncStatus）'}'
        : p.fetching
            ? '吸出し中 ${p.bytesPerSec > 0 ? '(${(p.bytesPerSec / 1024).toStringAsFixed(1)} KB/s)' : ''}'
            : p.caughtUp
                ? '最新まで吸出し済み'
                : '待機中（${_fmtMB(p.backlogBytes)}未吸出し）';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          icon: Icons.sd_storage_outlined,
          title: '吸出し',
          mode: _pullModeText(),
        ),
        const SizedBox(height: 12),
        _buildProgressBlock(done: done, total: total, status: status),
        const SizedBox(height: 12),
        _statusNote(
            '画面OFFやアプリ切替時はForeground Serviceへ引き継いで吸出しを続けます。OSに止められた場合は再度アプリを開くと復帰します。'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: GradientButton(
            onPressed: _status == 'connected' && _sdSync != null
                ? () {
                    _sdSync?.triggerManualPull();
                    _showSnackBar('吸出しを開始します…');
                  }
                : null,
            icon: Icons.download,
            label: '手動吸出し',
          ),
        ),
      ],
    );
  }

  Widget _buildUploadStatus() {
    final us = _driveStatus;
    final auto = us?.autoUpload ?? _driveUploadAuto;
    final done = us?.completedBytes ?? 0;
    final total = us?.totalBytes ?? 0;
    final uploadDetail = us?.lastError != null
        ? '最終エラー：${us!.lastError}'
        : us?.lastUploadedFile != null
            ? '最終送信：${us!.lastUploadedFile}'
            : null;
    final status = us == null
        ? '待機中'
        : us.blockedNoWifi
            ? 'WiFi待ち（WiFiのみモード）'
            : us.uploading
                ? 'アップロード中：${us.currentFile ?? ''}'
                : us.waitingForManual
                    ? '手動待ち（未アップロード ${us.pendingFiles}件）'
                    : us.pendingFiles > 0
                        ? '待機中（未アップロード ${us.pendingFiles}件）'
                        : us.uploadedChunks > 0
                            ? '送信待ちなし（今回 ${us.uploadedChunks}件送信）'
                            : '送信待ちなし';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          icon: Icons.cloud_upload_outlined,
          title: 'Driveアップロード',
          mode: auto ? '自動（BG対応）' : '手動',
        ),
        const SizedBox(height: 12),
        _buildProgressBlock(done: done, total: total, status: status),
        const SizedBox(height: 12),
        if (uploadDetail != null) ...[
          _statusNote(uploadDetail),
          const SizedBox(height: 12),
        ],
        _statusNote('「送信待ちなし」はスマホ内キューが空という意味です。Drive上の再確認は録音一覧で確認してください。'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: GradientButton(
            onPressed: _status == 'connected' && _sdSync != null
                ? () {
                    _sdSync?.triggerManualUpload();
                    _showSnackBar('Drive同期を開始します…');
                  }
                : null,
            icon: Icons.cloud_upload,
            label: '手動同期',
          ),
        ),
      ],
    );
  }

  Widget _buildLedStatus() {
    final enabled = _ledSettings.enabled;
    final status = enabled
        ? '録音中 ${_ledSettings.recordingColor.label} / 停止中 ${_ledSettings.idleColor.label} / 明るさ ${_ledSettings.brightnessPct}% / ${_ledSettings.intervalSec}秒間隔'
        : 'オフ';
    final detail = _ledStatus ??
        (_status == 'connected' ? '接続時に自動で反映します' : 'デバイス接続後に反映します');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          icon: Icons.lightbulb_outline,
          title: 'デバイスLED',
          mode: enabled ? 'オン' : 'オフ',
        ),
        const SizedBox(height: 12),
        _buildProgressBlock(
            done: enabled ? _ledSettings.brightnessPct : 0,
            total: 30,
            status: status),
        const SizedBox(height: 10),
        _statusNote(detail),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _status == 'connected' ? _applyLedSettings : null,
            icon: const Icon(Icons.send_outlined),
            label: const Text('設定を反映'),
          ),
        ),
      ],
    );
  }

  Widget _buildWiredRescueCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(
          icon: Icons.usb,
          title: 'USB救出',
          mode: '有線で一括吸出し',
        ),
        const SizedBox(height: 12),
        _statusNote('デバイスをスマホへUSB接続して、SD内の未回収ファイルをまとめてDriveへ送ります。'),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WiredRescuePage()),
              );
            },
            icon: const Icon(Icons.usb),
            label: const Text('USB救出を開く'),
          ),
        ),
      ],
    );
  }

  Future<void> _sleepDevice() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sleep device?'),
        content: const Text(
            'The device powers down to save battery. Press its button to '
            'wake it (it restarts and resumes recording).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sleep')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final sent = await widget.device.sleepDevice();
      _showSnackBar(
          sent
              ? 'Sleep command sent — device powering down'
              : 'Sleep not supported by this firmware',
          isError: !sent);
    } catch (_) {
      // The link drops as the device powers off — expected.
      _showSnackBar('Sleep command sent — device powering down');
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sdSync?.dispose();
    if (!_serviceHandoffActive) {
      WrForegroundService.stop().ignore();
    }
    widget.device.dispose();
    super.dispose();
  }

  Widget _card(Widget child) => Card(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dim = cs.onSurface.withOpacity(0.6);
    final connected = _status == 'connected';
    final statusJa = _status == 'connected'
        ? '接続中'
        : _status == 'disconnected'
            ? '未接続'
            : _status.startsWith('error:')
                ? '接続エラー'
                : '接続中…';
    final statusDetail = _status.startsWith('error:')
        ? _status.replaceFirst(RegExp(r'^error:\s*'), '')
        : null;
    return Scaffold(
      appBar: AppBar(
        title: const MojioWordmark(fontSize: 24),
        actions: [
          if (_batteryPct != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _batteryPct! >= 80
                        ? Icons.battery_full
                        : _batteryPct! >= 40
                            ? Icons.battery_4_bar
                            : Icons.battery_alert,
                    color: _batteryPct! < 20 ? Colors.red : null,
                    size: 20,
                  ),
                  const SizedBox(width: 2),
                  Text('$_batteryPct%', style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          IconButton(
            icon: const Icon(Icons.sd_storage_outlined),
            tooltip: 'Device SD files',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StoragePage(
                  device: widget.device,
                  uploader: _uploader,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.library_music_outlined),
            tooltip: 'Recordings (play)',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RecordingsPage(uploader: _uploader),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.cloud_queue),
            tooltip: 'Drive recordings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DriveFilesPage(uploader: _uploader),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.description_outlined),
            tooltip: 'Transcripts',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => TranscriptsPage(uploader: _uploader),
              ),
            ),
          ),
          if (_recording != null)
            IconButton(
              icon: const Icon(Icons.bedtime_outlined),
              tooltip: 'Sleep device',
              onPressed: _sleepDevice,
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsPage(uploader: _uploader),
                ),
              );
              if (mounted) {
                await _loadSyncSettings();
                await _loadLedSettings();
                await _applyLedSettings();
                _startSdSync();
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          // ---- デバイスカード（製品写真） ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: 72,
                      height: 72,
                      color: Colors.white,
                      child: Image.asset('assets/mojio_device.png',
                          fit: BoxFit.cover),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('mojizo',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: connected ? cs.secondary : Colors.grey,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                statusJa,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: dim, fontSize: 13),
                              ),
                            ),
                            if (_batteryPct != null) ...[
                              const SizedBox(width: 8),
                              Icon(
                                _batteryPct! >= 80
                                    ? Icons.battery_full
                                    : _batteryPct! >= 40
                                        ? Icons.battery_4_bar
                                        : Icons.battery_alert,
                                size: 16,
                                color: _batteryPct! < 20 ? cs.error : dim,
                              ),
                              const SizedBox(width: 2),
                              Text('$_batteryPct%',
                                  style: TextStyle(color: dim, fontSize: 13)),
                            ],
                          ],
                        ),
                        if (statusDetail != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            statusDetail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: dim),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Text(
                          '受信 $_packets ・ 保存 ${_fmtMB(_savedBytes)} ・ ロスト $_lostPackets',
                          style: TextStyle(fontSize: 11, color: dim),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          _card(_buildWiredRescueCard()),
          const SizedBox(height: 14),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.mic, size: 20, color: cs.secondary),
                    const SizedBox(width: 8),
                    const Text('マイク入力',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('ライブモニター', style: TextStyle(fontSize: 12, color: dim)),
                    Switch(
                      value: _liveMonitor,
                      onChanged: (v) async {
                        setState(() {
                          _liveMonitor = v;
                          if (!v) {
                            _level = 0.0;
                            _levels.clear();
                          }
                        });
                        try {
                          await widget.device.setLiveMonitor(v);
                        } catch (_) {}
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                WaveformBars(
                    levels: _liveMonitor ? _levels : const [], height: 56),
                if (!_liveMonitor)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('オフ — マイク確認時だけオンに（省電力）',
                        style: TextStyle(fontSize: 11, color: dim)),
                  ),
              ],
            ),
          ),
          if (_micGainLevel != null) ...[
            const SizedBox(height: 14),
            _card(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.tune, size: 20, color: cs.secondary),
                      const SizedBox(width: 8),
                      const Text('マイクゲイン',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(micGainLabel(_micGainLevel!),
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 12),
                  LevelMeter(level: _liveMonitor ? _level : 0.0, height: 12),
                  if (!_liveMonitor)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('ライブモニターをオンにすると入力レベルを見ながら調整できます',
                          style: TextStyle(fontSize: 11, color: dim)),
                    ),
                  Slider(
                    min: 0,
                    max: 8,
                    divisions: 8,
                    value: _micGainLevel!.clamp(0, 8).toDouble(),
                    label: micGainLabel(_micGainLevel!),
                    onChanged: (v) => setState(() => _micGainLevel = v.round()),
                    onChangeEnd: (v) async {
                      final g = v.round();
                      try {
                        await widget.device.setMicGainLevel(g);
                      } catch (e) {
                        _showSnackBar('ゲイン設定に失敗しました: $e', isError: true);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
          if (_recording != null) ...[
            const SizedBox(height: 14),
            Card(
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                secondary: Icon(
                  _recording!
                      ? Icons.fiber_manual_record
                      : Icons.stop_circle_outlined,
                  color: _recording! ? cs.error : null,
                ),
                title: const Text('SDに録音'),
                subtitle: Text(_recording! ? 'オン — 本体に保存中' : 'オフ — 一時停止'),
                value: _recording!,
                onChanged: (v) async {
                  setState(() => _recording = v);
                  try {
                    await widget.device.setRecording(v);
                  } catch (e) {
                    if (mounted) {
                      setState(() => _recording = !v);
                      _showSnackBar('録音の${v ? '開始' : '停止'}に失敗しました: $e',
                          isError: true);
                    }
                  }
                },
              ),
            ),
          ],
          const SizedBox(height: 14),
          _card(_buildLedStatus()),
          const SizedBox(height: 14),
          _card(_buildSyncStatus()),
          const SizedBox(height: 14),
          _card(_buildUploadStatus()),
        ],
      ),
    );
  }
}

String micGainLabel(int level) {
  final i = level.clamp(0, _micGainLabels.length - 1);
  return _micGainLabels[i];
}

extension on BluetoothConnectionState {
  String get name => switch (this) {
        BluetoothConnectionState.connected => 'connected',
        BluetoothConnectionState.disconnected => 'disconnected',
        _ => toString(),
      };
}
