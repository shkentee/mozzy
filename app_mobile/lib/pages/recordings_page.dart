import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/wr_drive_uploader.dart';
import '../services/wr_local_recordings.dart';
import '../services/wr_opus_decoder.dart';

/// Lists locally-saved recordings and plays them in-app by decoding the raw
/// Opus dump to a temporary WAV (16 kHz mono) and playing it with just_audio.
class RecordingsPage extends StatefulWidget {
  const RecordingsPage({super.key, WrDriveUploader? uploader})
      : _uploaderOverride = uploader;

  final WrDriveUploader? _uploaderOverride;

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  final _player = AudioPlayer();
  WrDriveUploader get _uploader =>
      widget._uploaderOverride ?? WrDriveUploader();

  List<WrRecording> _recs = [];
  bool _loading = true;
  String? _playingPath; // dump path currently loaded into the player
  bool _isPlaying = false; // live play/pause state from the player
  double? _decodeProgress; // non-null while decoding
  final Set<String> _uploading = {};
  Set<String> _uploadedIds = {}; // "<name>:<size>" of already-uploaded files
  bool _uploadingAll = false;

  // Playback position/duration/speed for the "now playing" bar.
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _speed = 1.0;
  static const _speeds = [1.0, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    // Drive the UI from the player's own state stream so the play/pause icon
    // and the "now playing" highlight update the moment playback actually
    // starts, pauses, or finishes.
    _player.playerStateStream.listen((s) {
      if (!mounted) return;
      if (s.processingState == ProcessingState.completed) {
        _player.stop();
        setState(() {
          _isPlaying = false;
          _playingPath = null;
          _position = Duration.zero;
        });
      } else {
        setState(() => _isPlaying = s.playing);
      }
    });
    _player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _duration = d);
    });
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final recs = await WrLocalRecordings.list();
    final prefs = await SharedPreferences.getInstance();
    final ids = (prefs.getStringList('wr_uploaded_ids') ?? const <String>[]);
    if (!mounted) return;
    setState(() {
      _recs = recs;
      _uploadedIds = ids.toSet();
      _loading = false;
    });
  }

  bool _isUploaded(WrRecording rec) =>
      _uploadedIds.contains('${rec.name}:${rec.sizeBytes}');

  String _remoteName(File f) =>
      f.uri.pathSegments.last.replaceAll(':', '-').replaceAll('.bin', '.opus');

  Future<void> _togglePlay(WrRecording rec) async {
    // Tapping the currently-loaded item toggles pause/resume.
    // NOTE: do NOT await play() — just_audio's play() future only completes
    // when playback *finishes*, so awaiting it would freeze the icon on ▶.
    if (_playingPath == rec.file.path) {
      if (_isPlaying) {
        await _player.pause();
      } else {
        unawaited(_player.play());
      }
      return; // icon/highlight update arrives via playerStateStream
    }

    await _player.stop();
    setState(() {
      _playingPath = rec.file.path;
      _isPlaying = false;
      _decodeProgress = 0;
    });
    try {
      final tmp = await getTemporaryDirectory();
      final wavPath = '${tmp.path}/play_${rec.name}.wav';
      await WrOpusDecoder.decodeDumpToWav(
        rec.file,
        wavPath,
        onProgress: (p) {
          if (mounted) setState(() => _decodeProgress = p);
        },
      );
      if (!mounted) return;
      setState(() => _decodeProgress = null);
      await _player.setFilePath(wavPath);
      unawaited(_player.play());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _decodeProgress = null;
        _playingPath = null;
        _isPlaying = false;
      });
      _snack('Playback failed: $e', error: true);
    }
  }

  Future<void> _upload(WrRecording rec) async {
    setState(() => _uploading.add(rec.file.path));
    try {
      final id = await _uploader.uploadIfNew(rec.file, _remoteName(rec.file));
      if (mounted) {
        setState(() => _uploadedIds.add('${rec.name}:${rec.sizeBytes}'));
      }
      _snack(id == null ? 'Already uploaded.' : 'Uploaded to Drive (id: $id)');
    } catch (e) {
      _snack('Upload failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _uploading.remove(rec.file.path));
    }
  }

  Future<void> _uploadAll() async {
    final pending = _recs.where((r) => !_isUploaded(r)).toList();
    if (pending.isEmpty) {
      _snack('Everything is already uploaded.');
      return;
    }
    setState(() => _uploadingAll = true);
    try {
      final n = await _uploader.syncPending(
        pending.map((r) => r.file).toList(),
        nameFor: _remoteName,
        onUploaded: (f, _) {
          final name = f.uri.pathSegments.last;
          final len = f.lengthSync();
          if (mounted) setState(() => _uploadedIds.add('$name:$len'));
        },
      );
      _snack('Uploaded $n recording(s) to Drive.');
    } catch (e) {
      _snack('Upload all failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _uploadingAll = false);
    }
  }

  Future<void> _cycleSpeed() async {
    final i = _speeds.indexOf(_speed);
    final next = _speeds[(i + 1) % _speeds.length];
    await _player.setSpeed(next);
    if (mounted) setState(() => _speed = next);
  }

  Future<void> _delete(WrRecording rec) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(rec.name),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    if (_playingPath == rec.file.path) {
      await _player.stop();
      _playingPath = null;
    }
    await rec.file.delete();
    await _load();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m ${s}s';
  }

  String _fmtSize(int b) => b >= 1 << 20
      ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
      : '${(b / 1024).toStringAsFixed(0)} KB';

  String _fmtTime(DateTime t) {
    String two(int x) => x.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recordings'),
        actions: [
          IconButton(
            icon: _uploadingAll
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cloud_upload),
            tooltip: 'Upload all to Drive',
            onPressed: (_loading || _uploadingAll) ? null : _uploadAll,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _recs.isEmpty
              ? const Center(child: Text('No local recordings yet.'))
              : ListView.separated(
                  itemCount: _recs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _tile(_recs[i]),
                ),
      bottomNavigationBar: (_playingPath != null && _decodeProgress == null)
          ? _nowPlayingBar()
          : null,
    );
  }

  String _fmtPos(Duration d) {
    String two(int x) => x.toString().padLeft(2, '0');
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${two(m)}:${two(s)}';
  }

  Widget _nowPlayingBar() {
    final maxMs = _duration.inMilliseconds.toDouble();
    final posMs = _position.inMilliseconds.clamp(0, _duration.inMilliseconds);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            IconButton(
              iconSize: 36,
              icon: Icon(_isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_fill),
              onPressed: () {
                if (_isPlaying) {
                  unawaited(_player.pause());
                } else {
                  unawaited(_player.play());
                }
              },
            ),
            Text(_fmtPos(_position)),
            Expanded(
              child: Slider(
                value: maxMs <= 0 ? 0 : posMs.toDouble(),
                max: maxMs <= 0 ? 1 : maxMs,
                onChanged: maxMs <= 0
                    ? null
                    : (v) => unawaited(
                        _player.seek(Duration(milliseconds: v.round()))),
              ),
            ),
            Text(_fmtPos(_duration)),
            TextButton(
              onPressed: _cycleSpeed,
              child: Text('${_speed}x'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(WrRecording rec) {
    final theme = Theme.of(context);
    final isCurrent = _playingPath == rec.file.path;
    final decoding = isCurrent && _decodeProgress != null;
    final playing = isCurrent && _isPlaying && _decodeProgress == null;
    final paused = isCurrent && !_isPlaying && _decodeProgress == null;
    final busyUpload = _uploading.contains(rec.file.path);

    final accent = theme.colorScheme.primary;
    final status = decoding
        ? 'decoding ${(100 * (_decodeProgress ?? 0)).round()}%…'
        : playing
            ? '▶ playing'
            : paused
                ? '⏸ paused'
                : null;

    return ListTile(
      selected: isCurrent,
      selectedTileColor: accent.withOpacity(0.10),
      leading: IconButton(
        icon: decoding
            ? SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: (_decodeProgress ?? 0) > 0 ? _decodeProgress : null,
                ),
              )
            : Icon(
                playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                color: isCurrent ? accent : null,
              ),
        iconSize: 34,
        tooltip: playing ? 'Pause' : 'Play',
        onPressed: decoding ? null : () => _togglePlay(rec),
      ),
      title: Text(
        _fmtTime(rec.startedAt),
        style: TextStyle(
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        '${_fmtSize(rec.sizeBytes)} · ~${_fmtDur(rec.approxDuration)}'
        '${status != null ? '   ·   $status' : ''}',
        style: status != null
            ? TextStyle(color: accent, fontWeight: FontWeight.w500)
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          busyUpload
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : IconButton(
                  icon: Icon(
                    _isUploaded(rec)
                        ? Icons.cloud_done
                        : Icons.cloud_upload_outlined,
                    color: _isUploaded(rec) ? Colors.green : null,
                  ),
                  tooltip: _isUploaded(rec)
                      ? 'Uploaded · tap to re-upload'
                      : 'Upload to Drive',
                  onPressed: () => _upload(rec),
                ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete',
            onPressed: () => _delete(rec),
          ),
        ],
      ),
    );
  }
}
