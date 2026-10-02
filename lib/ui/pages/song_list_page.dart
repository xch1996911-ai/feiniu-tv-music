import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/exceptions.dart';
import '../../domain/track.dart';
import '../../repositories/auth_repository.dart';
import '../../repositories/music_repository.dart';
import '../../repositories/playback_repository.dart';

/// 歌曲列表页（Phase 1 临时 UI）。
/// 读取分页曲目；每行显示「歌名 / 歌手 / 专辑 / 格式」；D-pad 可聚焦，OK 选曲播放。
class SongListPage extends StatefulWidget {
  final VoidCallback onPick;
  final VoidCallback onBack;

  const SongListPage({super.key, required this.onPick, required this.onBack});

  @override
  State<SongListPage> createState() => _SongListPageState();
}

class _SongListPageState extends State<SongListPage> {
  bool _loading = true;
  String? _error;
  List<Track> _tracks = const [];

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
    final music = context.read<MusicRepository>();
    final auth = context.read<AuthRepository>();
    final res = await music.getTracks(1, 30);
    if (!mounted) return;

    if (res.isErr) {
      if (res.error.kind == ErrorKind.tokenExpired) {
        // 自动重登后重试；若重登失败，AuthRepository 已 logout → 自动回登录页。
        final r = await auth.handleTokenExpired();
        if (r.isOk && mounted) {
          return _load();
        }
      }
      setState(() {
        _loading = false;
        _error = res.error.message;
      });
      return;
    }
    setState(() {
      _tracks = res.value.items;
      _loading = false;
    });
  }

  void _select(int index) {
    if (index < 0 || index >= _tracks.length) return;
    final pb = context.read<PlaybackRepository>();
    pb.setQueue(_tracks, startIndex: index);
    widget.onPick();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        widget.onBack();
        return false;
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('歌曲列表')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                        const SizedBox(height: 16),
                        ElevatedButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  )
                : _SongListView(tracks: _tracks, onSelect: _select),
      ),
    );
  }
}

class _SongListView extends StatelessWidget {
  final List<Track> tracks;
  final void Function(int) onSelect;

  const _SongListView({required this.tracks, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        final node = FocusNode();
        return FocusableActionDetector(
          focusNode: node,
          autofocus: i == 0,
          onActivate: () => onSelect(i),
          child: Builder(builder: (c) {
            final focused = node.hasFocus;
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: focused ? Colors.blue.withOpacity(0.25) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: focused
                    ? Border.all(color: Colors.blue, width: 2)
                    : Border.all(color: Colors.transparent),
              ),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text(t.title,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: focused ? FontWeight.w600 : FontWeight.normal)),
                  ),
                  Expanded(flex: 3, child: Text(t.artistNames)),
                  Expanded(flex: 3, child: Text(t.album.name)),
                  Expanded(
                    flex: 2,
                    child: Text(
                      t.audioSpec.format ?? '—',
                      style: const TextStyle(color: Colors.blueGrey),
                    ),
                  ),
                ],
              ),
            );
          }),
        );
      },
    );
  }
}
