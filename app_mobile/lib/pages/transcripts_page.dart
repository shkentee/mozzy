import 'package:flutter/material.dart';

import '../services/wr_drive_uploader.dart';

class TranscriptsPage extends StatefulWidget {
  const TranscriptsPage({super.key, WrDriveUploader? uploader})
      : uploaderOverride = uploader;

  final WrDriveUploader? uploaderOverride;

  @override
  State<TranscriptsPage> createState() => _TranscriptsPageState();
}

class _TranscriptsPageState extends State<TranscriptsPage> {
  WrDriveUploader get _uploader => widget.uploaderOverride ?? WrDriveUploader();

  List<WrTranscriptFile> _files = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final files = await _uploader.listTranscripts();
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

  String _dateLabel(WrTranscriptFile f) {
    final dt = f.modifiedTime?.toLocal();
    if (dt != null) {
      return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return f.name.replaceFirst(RegExp(r'\.md$', caseSensitive: false), '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('トランスクリプト'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新',
            onPressed: _load,
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
          child: Text('読み込みに失敗しました\n$_error', textAlign: TextAlign.center),
        ),
      );
    }
    if (_files.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 160),
            Icon(Icons.description_outlined, size: 48),
            SizedBox(height: 16),
            Center(child: Text('transcripts フォルダに md がまだありません')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _files.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final f = _files[i];
          return Card(
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: const Icon(Icons.article_outlined),
              title: Text(
                f.name.replaceFirst(RegExp(r'\.md$', caseSensitive: false), ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(_dateLabel(f)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      TranscriptDetailPage(file: f, uploader: _uploader),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class TranscriptDetailPage extends StatefulWidget {
  const TranscriptDetailPage({
    super.key,
    required this.file,
    required this.uploader,
  });

  final WrTranscriptFile file;
  final WrDriveUploader uploader;

  @override
  State<TranscriptDetailPage> createState() => _TranscriptDetailPageState();
}

class _TranscriptDetailPageState extends State<TranscriptDetailPage> {
  String? _markdown;
  bool _loading = true;
  String? _error;

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
      final text =
          await widget.uploader.downloadTranscriptMarkdown(widget.file.id);
      if (!mounted) return;
      setState(() {
        _markdown = text;
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

  @override
  Widget build(BuildContext context) {
    final title = _titleFromMarkdown(_markdown) ??
        widget.file.name
            .replaceFirst(RegExp(r'\.md$', caseSensitive: false), '');
    return Scaffold(
      appBar: AppBar(
        title: const Text('トランスクリプト'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '更新',
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(title),
    );
  }

  Widget _buildBody(String title) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('読み込みに失敗しました\n$_error', textAlign: TextAlign.center),
        ),
      );
    }
    final blocks = _parseBlocks(_markdown ?? '');
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
      children: [
        Text(title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(widget.file.name, style: _dimStyle(context)),
        const SizedBox(height: 18),
        for (final b in blocks) _TranscriptBlockView(block: b),
      ],
    );
  }
}

class _TranscriptBlock {
  const _TranscriptBlock({
    this.time,
    this.speaker,
    required this.text,
    this.heading = false,
  });

  final String? time;
  final String? speaker;
  final String text;
  final bool heading;
}

String? _titleFromMarkdown(String? markdown) {
  if (markdown == null) return null;
  for (final line in markdown.split('\n')) {
    final t = line.trim();
    if (t.startsWith('# ')) return t.substring(2).trim();
  }
  return null;
}

List<_TranscriptBlock> _parseBlocks(String markdown) {
  final blocks = <_TranscriptBlock>[];
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  final timePattern = RegExp(
    r'^((?:\d{1,2}:)?\d{1,2}:\d{2})\s+(.+?)(?:[:：]\s*(.*))?$',
  );

  String? curTime;
  String? curSpeaker;
  final buf = <String>[];

  void flush() {
    final text = buf.join('\n').trim();
    if (text.isNotEmpty) {
      blocks.add(_TranscriptBlock(
        time: curTime,
        speaker: curSpeaker,
        text: text,
      ));
    }
    buf.clear();
  }

  for (final raw in lines) {
    final line = raw.trimRight();
    final t = line.trim();
    if (t.isEmpty) {
      flush();
      curTime = null;
      curSpeaker = null;
      continue;
    }
    if (t.startsWith('#')) {
      flush();
      blocks.add(_TranscriptBlock(
        text: t.replaceFirst(RegExp(r'^#+\s*'), ''),
        heading: true,
      ));
      curTime = null;
      curSpeaker = null;
      continue;
    }
    final m = timePattern.firstMatch(t);
    if (m != null) {
      flush();
      curTime = m.group(1);
      curSpeaker = m.group(2)?.trim();
      final body = m.group(3)?.trim();
      if (body != null && body.isNotEmpty) buf.add(body);
      continue;
    }
    buf.add(t.replaceFirst(RegExp(r'^[-*]\s+'), ''));
  }
  flush();
  return blocks;
}

TextStyle _dimStyle(BuildContext context) =>
    TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.58));

class _TranscriptBlockView extends StatelessWidget {
  const _TranscriptBlockView({required this.block});

  final _TranscriptBlock block;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (block.heading) {
      return Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 8),
        child: Text(block.text,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Text(block.time ?? '',
                style: TextStyle(fontSize: 12, color: cs.primary)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (block.speaker != null && block.speaker!.isNotEmpty)
                  Text(block.speaker!,
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.secondary,
                          fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                SelectableText(
                  block.text,
                  style: const TextStyle(fontSize: 14, height: 1.55),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
