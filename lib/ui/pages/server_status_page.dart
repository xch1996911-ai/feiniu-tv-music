import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/exceptions.dart';
import '../../repositories/auth_repository.dart';
import '../../repositories/music_repository.dart';

/// 服务器状态页：验证 NAS 是否可达（GET /initialization/state）。
/// Phase 1 临时 UI，仅展示探测结果与原始状态，并提供进入歌曲列表的入口。
class ServerStatusPage extends StatefulWidget {
  final VoidCallback onContinue;
  final VoidCallback onBack;

  const ServerStatusPage({
    super.key,
    required this.onContinue,
    required this.onBack,
  });

  @override
  State<ServerStatusPage> createState() => _ServerStatusPageState();
}

class _ServerStatusPageState extends State<ServerStatusPage> {
  bool _loading = true;
  bool _reachable = false;
  String _detail = '';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _loading = true);
    final music = context.read<MusicRepository>();
    final auth = context.read<AuthRepository>();
    final res = await music.checkConnection();
    if (!mounted) return;
    if (res.isErr) {
      // token 失效等需要重新登录的情况，交给 AuthRepository 处理（已自动回登录页）。
      if (res.error.kind == ErrorKind.tokenExpired) {
        await auth.handleTokenExpired();
      }
      setState(() {
        _loading = false;
        _reachable = false;
        _detail = res.error.message;
      });
      return;
    }
    const encoder = JsonEncoder.withIndent('  ');
    setState(() {
      _loading = false;
      _reachable = true;
      _detail = encoder.convert(res.value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthRepository>();
    return WillPopScope(
      onWillPop: () async {
        widget.onBack();
        return false;
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('服务器状态')),
        body: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('NAS: ${auth.host ?? "(未知)"}',
                  style: const TextStyle(fontSize: 22)),
              Text('用户: ${auth.username ?? "(未知)"}',
                  style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 16),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else
                Row(
                  children: [
                    Icon(
                      _reachable ? Icons.check_circle : Icons.error,
                      color: _reachable ? Colors.green : Colors.red,
                      size: 28,
                    ),
                    const SizedBox(width: 10),
                    Text(_reachable ? '可达 (HTTP 5666 / initialization/state)'
                                    : '不可达',
                        style: const TextStyle(fontSize: 20)),
                  ],
                ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: Text(_detail, style: const TextStyle(fontFamily: 'monospace')),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  ElevatedButton(
                    onPressed: _loading ? null : _check,
                    child: const Text('重新探测'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: (_loading || !_reachable) ? null : widget.onContinue,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                    ),
                    child: const Text('进入歌曲列表', style: TextStyle(fontSize: 20)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
