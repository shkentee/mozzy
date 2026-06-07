import 'package:flutter/material.dart';
import 'package:googleapis/drive/v3.dart' as drive;

import '../services/wr_drive_uploader.dart';

class DriveFilesPage extends StatefulWidget {
  const DriveFilesPage({super.key, WrDriveUploader? uploader})
      : uploaderOverride = uploader;

  final WrDriveUploader? uploaderOverride;

  @override
  State<DriveFilesPage> createState() => _DriveFilesPageState();
}

class _DriveFilesPageState extends State<DriveFilesPage> {
  WrDriveUploader get _uploader => widget.uploaderOverride ?? WrDriveUploader();

  List<drive.File> _files = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await _uploader.listFiles();
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

  Future<void> _delete(drive.File file) async {
    try {
      await _uploader.deleteFile(file.id!);
      if (!mounted) return;
      setState(() => _files.remove(file));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Delete failed: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drive Recordings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFiles,
            tooltip: 'Refresh',
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
      return Center(child: Text('Error: $_error'));
    }
    if (_files.isEmpty) {
      return const Center(child: Text('No recordings uploaded yet.'));
    }
    return RefreshIndicator(
      onRefresh: _loadFiles,
      child: ListView.builder(
        itemCount: _files.length,
        itemBuilder: (context, i) {
          final file = _files[i];
          return ListTile(
            leading: const Icon(Icons.audiotrack),
            title: Text(file.name ?? '(unnamed)'),
            subtitle: file.modifiedTime != null
                ? Text(file.modifiedTime!.toLocal().toString())
                : null,
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(file),
              tooltip: 'Delete',
            ),
          );
        },
      ),
    );
  }
}
