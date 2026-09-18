import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../theme/app_theme.dart';

/// 我的收藏：收藏的消息列表
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  final _svc = ConversationService();
  List<Map<String, dynamic>> _favs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _svc.favorites();
      if (mounted) {
        setState(() {
          _favs = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _preview(Map<String, dynamic> m) {
    final t = AppLocalizations.instance.t;
    final typeMap = {
      2: t('favoritesPreviewImage'),
      3: t('favoritesPreviewFile'),
      4: t('favoritesPreviewVoice'),
      5: t('favoritesPreviewVideo'),
    };
    return (typeMap[(m['type'] as num?)?.toInt()] ?? '') +
        (m['content']?.toString() ?? '');
  }

  String _time(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(t('favoritesTitle'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _favs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.star_border,
                          size: 48, color: context.cs.onSurfaceVariant),
                      SizedBox(height: 8),
                      Text(t('favoritesEmpty'),
                          style: TextStyle(color: context.cs.onSurfaceVariant)),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _favs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final m = _favs[i];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: context.cs.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.star,
                                  size: 14, color: Color(0xFFFFB800)),
                              const SizedBox(width: 4),
                              Text(
                                  t('favoritesConversation',
                                      {'id': '${m['conversationId']}'}),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: context.cs.onSurfaceVariant)),
                              const Spacer(),
                              Text(_time(m['createdAt']?.toString()),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: context.cs.onSurfaceVariant)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(_preview(m),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 14, color: context.cs.onSurface)),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
