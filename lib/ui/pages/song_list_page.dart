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
    // Flutter 3.47 已废弃 WillPopScope，改用 PopScope。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onBack();
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
        return _TrackRow(
          track: tracks[i],
          autofocus: i == 0,
          onActivate: () => onSelect(i),
        );
      },
    );
  }
}

/// 单行曲目。
///
/// Flutter 3.47 的 `FocusableActionDetector` 已移除 `onActivate` 参数，
/// 改用 `ListTile`：它自带焦点能力与「OK/Enter 触发 `onTap`」行为，
/// 更契合 D-pad 优先的电视界面。
///
/// 焦点节点放在 State 中持有（而非在 build 里 new），否则会泄漏且重建时丢失焦点。
class _TrackRow extends StatefulWidget {
  final Track track;
  final bool autofocus;
  final VoidCallback onActivate;

  const _TrackRow({
    required this.track,
    required this.autofocus,
    required this.onActivate,
  });

  @override
  State<_TrackRow> createState() => _TrackRowState();
}

class _TrackRowState extends State<_TrackRow> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChanged);
    _node.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _focused = _node.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    return ListTile(
      focusNode: _node,
      autofocus: widget.autofocus,
      onTap: widget.onActivate,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: _focused ? Colors.blue : Colors.transparent,
          width: 2,
        ),
      ),
      tileColor: _focused ? Colors.blue.withValues(alpha: 0.25) : null,
      focusColor: Colors.blue.withValues(alpha: 0.25),
      title: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              t.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 20,
                fontWeight: _focused ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(t.artistNames,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 3,
            child: Text(t.album.name,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
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
  }
}
