import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show themeModeNotifier, setThemeMode, themeModeLabelJa;
import '../services/wr_drive_uploader.dart';
import '../services/wr_sd_sync.dart' show kDriveUploadAutoKey, kWifiOnlyKey;
import '../services/wr_sync_schedule.dart';

/// SharedPreferences keys (kept in sync with device_page.dart / uploader).
const _kFolderKey = 'wr_drive_folder';
const _kFolderIdKey = 'wr_drive_folder_id';
const _kDefaultFolder = 'wearable-recordings';

/// App settings: which Google Drive account + folder recordings upload to,
/// and whether uploads happen automatically on disconnect.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, WrDriveUploader? uploader})
      : _uploaderOverride = uploader;

  final WrDriveUploader? _uploaderOverride;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  WrDriveUploader get _uploader =>
      widget._uploaderOverride ?? WrDriveUploader();

  String _folderName = _kDefaultFolder;
  String? _email;
  bool _driveUploadAuto = true;
  bool _wifiOnly = false;
  bool _loadingEmail = true;
  bool _busy = false;
  SyncSchedule _schedule = const SyncSchedule();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _driveUploadAuto = prefs.getBool(kDriveUploadAutoKey) ?? true;
        _wifiOnly = prefs.getBool(kWifiOnlyKey) ?? false;
        _folderName = prefs.getString(_kFolderKey) ?? _kDefaultFolder;
      });
    }
    final sched = await SyncSchedule.load();
    if (mounted) setState(() => _schedule = sched);
    try {
      final email = await _uploader.currentEmail();
      if (mounted) setState(() => _email = email);
    } catch (_) {
      // ignore — offline / not signed in
    } finally {
      if (mounted) setState(() => _loadingEmail = false);
    }
  }

  Future<void> _switchAccount() async {
    setState(() => _busy = true);
    try {
      final email = await _uploader.chooseAccount();
      if (mounted) setState(() => _email = email);
      _snack(email == null ? 'サインインをキャンセルしました' : '$email でサインインしました');
    } catch (e) {
      _snack('サインインに失敗しました: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await _uploader.signOut();
      if (mounted) setState(() => _email = null);
      _snack('サインアウトしました');
    } catch (e) {
      _snack('サインアウトに失敗しました: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFolder() async {
    final picked = await Navigator.push<({String id, String name})>(
      context,
      MaterialPageRoute(
        builder: (_) => _FolderPickerPage(uploader: _uploader),
      ),
    );
    if (picked == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFolderIdKey, picked.id);
    await prefs.setString(_kFolderKey, picked.name);
    if (mounted) setState(() => _folderName = picked.name);
    _snack('アップロード先を「${picked.name}」に設定しました');
  }

  Future<void> _setDriveUploadAuto(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kDriveUploadAutoKey, v);
    if (mounted) setState(() => _driveUploadAuto = v);
  }

  Future<void> _setWifiOnly(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kWifiOnlyKey, v);
    if (mounted) setState(() => _wifiOnly = v);
  }

  Future<void> _saveSchedule(SyncSchedule s) async {
    await s.save();
    if (mounted) setState(() => _schedule = s);
  }

  Future<void> _pickTime(int currentMin, ValueChanged<int> onPicked) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: currentMin ~/ 60, minute: currentMin % 60),
    );
    if (picked != null) onPicked(picked.hour * 60 + picked.minute);
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          children: [
            // ---- 表示テーマ ----
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child:
                  Text('表示テーマ', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ValueListenableBuilder<ThemeMode>(
              valueListenable: themeModeNotifier,
              builder: (context, mode, _) => Column(
                children: [
                  for (final m in const [
                    ThemeMode.dark,
                    ThemeMode.light,
                    ThemeMode.system,
                  ])
                    RadioListTile<ThemeMode>(
                      value: m,
                      groupValue: mode,
                      onChanged: (v) {
                        if (v != null) setThemeMode(v);
                      },
                      secondary: Icon(switch (m) {
                        ThemeMode.light => Icons.light_mode_outlined,
                        ThemeMode.system => Icons.brightness_auto_outlined,
                        _ => Icons.dark_mode_outlined,
                      }),
                      title: Text(themeModeLabelJa(m)),
                    ),
                ],
              ),
            ),
            const Divider(),
            // ---- 保存先（Google Drive） ----
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('保存先（Google Drive）',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.account_circle),
              title: Text(_loadingEmail ? 'アカウント確認中…' : (_email ?? '未サインイン')),
              subtitle: const Text('録音のアップロード先アカウント'),
              trailing: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : null,
            ),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              children: [
                if (_email != null)
                  TextButton(
                    onPressed: _busy ? null : _signOut,
                    child: const Text('サインアウト'),
                  ),
                TextButton.icon(
                  onPressed: _busy ? null : _switchAccount,
                  icon: const Icon(Icons.swap_horiz),
                  label: Text(_email == null ? 'サインイン' : 'アカウント切替'),
                ),
              ],
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('アップロード先フォルダ'),
              subtitle: Text(_folderName),
              trailing: TextButton.icon(
                onPressed: _busy ? null : _pickFolder,
                icon: const Icon(Icons.drive_folder_upload_outlined),
                label: const Text('変更'),
              ),
              onTap: _busy ? null : _pickFolder,
            ),
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Drive自動同期'),
              subtitle: Text(_driveUploadAuto
                  ? '自動：未アップロード分を自動でDriveへ送る'
                  : '手動：メイン画面のボタンでDriveへ送る'),
              value: _driveUploadAuto,
              onChanged: _busy ? null : _setDriveUploadAuto,
            ),
            const Divider(),
            SwitchListTile(
              secondary: const Icon(Icons.wifi),
              title: const Text('WiFiのみアップロード'),
              subtitle: const Text('モバイルデータではアップロードしない'),
              value: _wifiOnly,
              onChanged: _busy ? null : _setWifiOnly,
            ),
            const Divider(),
            // ---- 自動吸出し（タイマー） ----
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('自動吸出し（タイマー）',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final m in SyncMode.values)
              RadioListTile<SyncMode>(
                value: m,
                groupValue: _schedule.mode,
                onChanged: (v) {
                  if (v != null) _saveSchedule(_schedule.copyWith(mode: v));
                },
                secondary: Icon(switch (m) {
                  SyncMode.scheduledTime => Icons.schedule,
                  SyncMode.intervalWindow => Icons.timelapse,
                  SyncMode.manual => Icons.touch_app,
                  _ => Icons.sync,
                }),
                title: Text(syncModeLabelJa(m)),
              ),
            if (_schedule.mode == SyncMode.scheduledTime)
              ListTile(
                leading: const Icon(Icons.access_time),
                title: const Text('時刻'),
                trailing: Text(SyncSchedule.fmtHm(_schedule.timeMinutes),
                    style: Theme.of(context).textTheme.titleMedium),
                onTap: () => _pickTime(_schedule.timeMinutes,
                    (m) => _saveSchedule(_schedule.copyWith(timeMinutes: m))),
              ),
            if (_schedule.mode == SyncMode.intervalWindow) ...[
              ListTile(
                leading: const Icon(Icons.timelapse),
                title: const Text('間隔'),
                trailing: DropdownButton<int>(
                  value: _schedule.intervalMin,
                  underline: const SizedBox.shrink(),
                  items: const [5, 10, 15, 30, 60]
                      .map(
                          (n) => DropdownMenuItem(value: n, child: Text('$n分')))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      _saveSchedule(_schedule.copyWith(intervalMin: v));
                    }
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.wb_sunny_outlined),
                title: const Text('開始時刻'),
                trailing: Text(SyncSchedule.fmtHm(_schedule.windowStartMin),
                    style: Theme.of(context).textTheme.titleMedium),
                onTap: () => _pickTime(
                    _schedule.windowStartMin,
                    (m) =>
                        _saveSchedule(_schedule.copyWith(windowStartMin: m))),
              ),
              ListTile(
                leading: const Icon(Icons.nightlight_outlined),
                title: const Text('終了時刻'),
                trailing: Text(SyncSchedule.fmtHm(_schedule.windowEndMin),
                    style: Theme.of(context).textTheme.titleMedium),
                onTap: () => _pickTime(_schedule.windowEndMin,
                    (m) => _saveSchedule(_schedule.copyWith(windowEndMin: m))),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                _schedule.describeJa(),
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.6)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A hierarchical Drive folder browser that mirrors Drive's own tree: start at
/// My Drive, tap a folder to descend, use the breadcrumb / system-back to go
/// up, and "Save here" to choose the current folder. Pops with the chosen
/// `(id, name)` record, or null if cancelled.
class _FolderPickerPage extends StatefulWidget {
  const _FolderPickerPage({required this.uploader});

  final WrDriveUploader uploader;

  @override
  State<_FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends State<_FolderPickerPage> {
  // Navigation stack from My Drive down to the current folder.
  final List<({String id, String name})> _stack = [
    (id: 'root', name: 'My Drive')
  ];
  List<({String id, String name})> _children = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  // Cross-Drive folder search (reaches "Computers"/PC-synced folders that the
  // My-Drive tree can't).
  final _searchController = TextEditingController();
  bool _searching = false;
  List<({String id, String name, List<String>? parents})> _searchResults = [];
  final Map<String, String> _pathById = {}; // result id -> location string

  ({String id, String name}) get _current => _stack.last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await widget.uploader.listSubfolders(_current.id);
      final list = files
          .where((f) => f.id != null && f.name != null)
          .map((f) => (id: f.id!, name: f.name!))
          .toList();
      if (!mounted) return;
      setState(() {
        _children = list;
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

  void _enter(({String id, String name}) folder) {
    setState(() => _stack.add(folder));
    _load();
  }

  bool _goUp() {
    if (_stack.length <= 1) return false;
    setState(() => _stack.removeLast());
    _load();
    return true;
  }

  void _selectCurrent() => Navigator.pop(context, _current);

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      _clearSearch();
      return;
    }
    setState(() {
      _searching = true;
      _loading = true;
      _error = null;
    });
    try {
      final files = await widget.uploader.searchFolders(q);
      final list = files
          .where((f) => f.id != null && f.name != null)
          .map((f) => (id: f.id!, name: f.name!, parents: f.parents))
          .toList();
      if (!mounted) return;
      setState(() {
        _searchResults = list;
        _pathById.clear();
        _loading = false;
      });
      _resolvePaths(list);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searching = false;
      _searchResults = [];
      _pathById.clear();
    });
  }

  /// Resolves each search result's full location (e.g. "My Drive › Projects"
  /// or "MyLaptop › Documents") so identically-named folders are
  /// distinguishable. Fills [_pathById] incrementally.
  Future<void> _resolvePaths(
      List<({String id, String name, List<String>? parents})> results) async {
    for (final r in results) {
      try {
        final path = await widget.uploader.folderPath(r.parents);
        if (!mounted) return;
        setState(() => _pathById[r.id] = path);
      } catch (_) {
        // Leave this one unresolved; the name is still shown.
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('New folder in "${_current.name}"'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => _busy = true);
    try {
      final folder =
          await widget.uploader.createFolder(name, parentId: _current.id);
      if (!mounted) return;
      Navigator.pop(context, (id: folder.id!, name: folder.name ?? name));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Create failed: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stack.length <= 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_current.name),
          actions: [
            IconButton(
              icon: const Icon(Icons.create_new_folder_outlined),
              tooltip: 'New folder here',
              onPressed: _busy ? null : _createFolder,
            ),
          ],
        ),
        body: Column(
          children: [
            _searchField(),
            if (!_searching) _breadcrumb(),
            const Divider(height: 1),
            Expanded(child: _searching ? _searchBody() : _body()),
          ],
        ),
        bottomNavigationBar: _searching
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _selectCurrent,
                    icon: const Icon(Icons.check),
                    label: Text('Save here: "${_current.name}"'),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        onSubmitted: _search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search all folders (incl. Computers / PC)',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searching
              ? IconButton(
                  icon: const Icon(Icons.close), onPressed: _clearSearch)
              : null,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _searchBody() {
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
    if (_searchResults.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No matching folders.'),
        ),
      );
    }
    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, i) {
        final f = _searchResults[i];
        final path = _pathById[f.id];
        return ListTile(
          leading: const Icon(Icons.folder_special_outlined),
          title: Text(f.name),
          subtitle: Text(path == null ? 'resolving location…' : '📁 $path',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          isThreeLine: false,
          onTap: () => Navigator.pop(context, (id: f.id, name: f.name)),
        );
      },
    );
  }

  Widget _breadcrumb() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _stack.length,
        separatorBuilder: (_, __) =>
            const Center(child: Icon(Icons.chevron_right, size: 18)),
        itemBuilder: (context, i) {
          final crumb = _stack[i];
          final isLast = i == _stack.length - 1;
          return Center(
            child: TextButton(
              onPressed: isLast
                  ? null
                  : () {
                      setState(() => _stack.removeRange(i + 1, _stack.length));
                      _load();
                    },
              child: Text(crumb.name),
            ),
          );
        },
      ),
    );
  }

  Widget _body() {
    if (_loading || _busy) {
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
    if (_children.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No subfolders here.\nUse "Save here" to pick this folder, '
            'or + to create a new one.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _children.length,
      itemBuilder: (context, i) {
        final f = _children[i];
        return ListTile(
          leading: const Icon(Icons.folder),
          title: Text(f.name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _enter(f),
        );
      },
    );
  }
}
