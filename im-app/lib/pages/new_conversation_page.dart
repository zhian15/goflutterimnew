import 'package:flutter/material.dart';

import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import 'chat_page.dart';

/// 新建会话/建群：
/// 1. 选择联系人（多选 1 人=单聊/多人=建群）
/// 2. 多人时填群名
/// 3. 创建后进入聊天
class NewConversationPage extends StatefulWidget {
  final String myId;
  const NewConversationPage({super.key, required this.myId});

  @override
  State<NewConversationPage> createState() => _NewConversationPageState();
}

class _NewConversationPageState extends State<NewConversationPage> {
  final _svc = FriendService();
  final _convSvc = ConversationService();
  final _nameCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _friends = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _showGroupName = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final friends = await _svc.list();
      if (mounted) {
        setState(() {
          _friends = friends;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _name(Map<String, dynamic> u) {
    final r = u['remark']?.toString() ?? '';
    if (r.isNotEmpty) return r;
    return (u['nickname'] ??
            u['account'] ??
            AppLocalizations.of(context).t('newConvUser'))
        .toString();
  }

  String _sub(Map<String, dynamic> u) =>
      (u['account'] ?? u['email'] ?? u['phone'] ?? '').toString();

  Future<void> _next() async {
    if (_selected.length == 1) {
      // 单聊：标题显示好友昵称
      final friend =
          _friends.firstWhere((u) => (u['id']?.toString()) == _selected.first);
      try {
        final conv = await _convSvc.createDirect(_selected.first);
        _openChat(conv, _name(friend));
      } catch (e) {
        if (mounted) {
          _toast(AppLocalizations.of(context).t('newConvCreateFailed',
              {'reason': e.toString().replaceFirst('Exception: ', '')}));
        }
      }
    } else {
      setState(() => _showGroupName = true);
    }
  }

  Future<void> _createGroup() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast(AppLocalizations.of(context).t('newConvGroupNameRequired'));
      return;
    }
    try {
      final conv = await _convSvc.createGroup(name, _selected.toList());
      _openChat(conv, name);
    } catch (e) {
      if (mounted) {
        _toast(AppLocalizations.of(context).t('newConvCreateFailed',
            {'reason': e.toString().replaceFirst('Exception: ', '')}));
      }
    }
  }

  void _openChat(Map<String, dynamic> conv, String title) {
    if (!mounted) return;
    final item =
        ConvItem.fromJson({'conversation': conv, 'conversationName': title});
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ChatPage(conv: item, myId: widget.myId)));
  }

  void _toast(String msg) => AppDialogs.toast(context, msg);

  @override
  Widget build(BuildContext context) {
    if (_showGroupName) return _buildGroupNamePage();
    return _buildPickPage();
  }

  Widget _buildPickPage() {
    final t = AppLocalizations.of(context).t;
    final q = _searchCtrl.text.toLowerCase();
    final filtered = q.isEmpty
        ? _friends
        : _friends
            .where((u) => ('${_name(u)} ${_sub(u)}').toLowerCase().contains(q))
            .toList();
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(t('newConvSelectContacts')),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty ? null : _next,
            child: Text(t('newConvConfirm', {'count': '${_selected.length}'}),
                style: TextStyle(
                    fontSize: 15,
                    color: _selected.isEmpty
                        ? context.cs.onSurfaceVariant
                        : AppTheme.primary,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: AppTheme.authInput(
                  hint: t('newConvSearchHint'), icon: Icons.search),
            ),
          ),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2)
          else
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(t('newConvNoContacts'),
                          style: TextStyle(color: context.cs.onSurfaceVariant)))
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => Divider(
                          height: 1,
                          indent: 68,
                          endIndent: 16,
                          color: context.cs.outlineVariant),
                      itemBuilder: (_, i) {
                        final u = filtered[i];
                        final id = (u['id'] ?? '').toString();
                        final selected = _selected.contains(id);
                        final name = _name(u);
                        final avatar = (u['avatar'] ?? '').toString();
                        return ListTile(
                          onTap: () => setState(() {
                            selected ? _selected.remove(id) : _selected.add(id);
                          }),
                          leading: AppAvatar(
                            url: avatar,
                            name: name,
                            size: 42,
                            background: AppTheme.primary,
                          ),
                          title: Text(name,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w500)),
                          subtitle: _sub(u).isEmpty
                              ? null
                              : Text(_sub(u),
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: context.cs.onSurfaceVariant)),
                          trailing: Icon(
                            selected
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: selected
                                ? AppTheme.primary
                                : context.cs.onSurfaceVariant,
                            size: 22,
                          ),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildGroupNamePage() {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(t('newConvGroupInfo')),
        leading: IconButton(
          onPressed: () => setState(() => _showGroupName = false),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          TextButton(
            onPressed: _createGroup,
            child: Text(t('newConvCreate'),
                style: const TextStyle(
                    fontSize: 15,
                    color: AppTheme.primary,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              maxLength: 30,
              decoration: AppTheme.authInput(
                  hint: t('newConvGroupNameHint'), icon: Icons.group),
            ),
            const SizedBox(height: 12),
            Text(t('newConvSelectedCount', {'count': '${_selected.length}'}),
                style: TextStyle(
                    fontSize: 13, color: context.cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
