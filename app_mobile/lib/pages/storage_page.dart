import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/wr_ble_device.dart';
import '../services/wr_drive_uploader.dart';
import '../services/wr_storage_client.dart';

/// Shows files available on the device SD card and allows fetching +
/// uploading them to Google Drive.
class StoragePage extends StatefulWidget {
  const StoragePage({
    super.key,
    required this.device,
    WrDriveUploader? uploader,
    WrStorageSession? session,
  })  : _uploaderOverride = uploader,
        _sessionOverride = session;

  final WrBleDevice device;
  final WrDriveUploader? _uploaderOverride;
  // Injected in tests to bypass real BLE + Drive calls.
  final WrStorageSession? _sessionOverride;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  WrDriveUploader get _uploader =>
      widget._uploaderOverride ?? WrDriveUploader();

  WrStorageSession? _session;
  List<String> _files = [];
  bool _loading = true;
  String? _error;

  // Per-file transfer state: filename → progress message.
  final Map<String, String> _progress = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _session =
          widget._sessionOverride ?? await widget.device.openStorageSession();
      if (_session == null) {
        if (!mounted) return;
        setState(() {
          _error = 'Storage service not found on this firmware.';
          _loading = false;
        });
        return;
      }
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await _session!.listFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _fetchAndUpload(String filename) async {
    if (_progress.containsKey(filename)) return; // already in progress

    setState(() => _progress[filename] = 'Fetching…');
    try {
      // Fetch file from device.
      final bytes = await _session!.fetchFile(
        filename,
        onProgress: (n) {
          if (!mounted) return;
          setState(() => _progress[filename] =
              'Fetching… ${(n / 1024).toStringAsFixed(0)} KB');
        },
      );

      if (!mounted) return;
      setState(() => _progress[filename] = 'Uploading…');

      // Save to a temp file and upload to Drive.
      final dir = await getTemporaryDirectory();
      final tmp = File('${dir.path}/$filename');
      await tmp.writeAsBytes(bytes);

      await _uploader.uploadFile(tmp, filename);
      await tmp.delete();

      if (!mounted) return;
      setState(() => _progress.remove(filename));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$filename uploaded to Drive')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _progress[filename] = 'Error: $e');
    }
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device SD Files'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Error: $_error'),
        ),
      );
    }
    if (_files.isEmpty) {
      return const Center(child: Text('No .opus files on device SD card.'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _files.length,
        itemBuilder: (context, i) {
          final name = _files[i];
          final prog = _progress[name];
          return ListTile(
            leading: const Icon(Icons.audiotrack),
            title: Text(name),
            subtitle: prog != null ? Text(prog) : null,
            trailing: prog == null
                ? IconButton(
                    icon: const Icon(Icons.cloud_upload_outlined),
                    tooltip: 'Fetch from device → Upload to Drive',
                    onPressed: () => _fetchAndUpload(name),
                  )
                : prog.startsWith('Error:')
                    ? IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.red),
                        tooltip: 'Retry',
                        onPressed: () {
                          setState(() => _progress.remove(name));
                          _fetchAndUpload(name);
                        },
                      )
                    : const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
          );
        },
      ),
    );
  }
}
