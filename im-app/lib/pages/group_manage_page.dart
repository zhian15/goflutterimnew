import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/conversation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_seal_badge.dart';
import '../widgets/v2_settings.dart'; // V2SetCard / V2SetSwitch / context.setXxx
import 'group/group_file_page.dart';
import 'group_members_page.dart';
import 'group_qr_page.dart';
import 'search_page.dart';

// ============================================================================
// 群资料页（参考截图 Screenshot_2026_0914_183445.jpg / 1260×5331 / DPR 3）
//
// 逻辑宽基准 420（= 物理宽 1260 / DPR 3），与项目 `v2Scale` 基准一致，
// 所以下面所有实测逻辑 px 直接 `* v2Scale(context)` 落地。
// 逐元素「实测值 / 落地值 / 不确定项」见 `UI-ref/measure/audit_group_friend.md`。
//
// 页面结构（自上而下，均为本页实测）：
//   ① 顶部白条：< + …（无标题）                      高 = 状态栏 + 56
//   ② 白底头块：圆角方形群头像 128（圆角 31）+ 群名 30.6/粗 + 星徽 26
//      + 「741 位成员」19.3 + 三个 72×72 圆角方瓦片（静音/搜索/公告）+ 标签 15.35
//      白底总高 = 状态栏 + 56 + 384.3
//   ③ 卡1（高 201.3）：群简介正文 21.7 / 行距 31.3 → 「描述」15.7 → 分隔线
//      → @群组号 22 → 「群组号」15.7
//   ④ 卡2（高 381.8）：5 行 × 75.8：照片和视频 / 文件 / 共享链接 / 语音消息 / 群二维码
//   ⑤ 「成员」15.9（ink 左 **41.7**，逐页实测，不套用其它页）+ 右侧成员数 + 放大镜
//   ⑥ 成员卡：行高 77.1，头像 51（圆角 9.3）+ 昵称 21.7（群主绿 #66C7A3）
//      + 角色徽章（创建者 = #DCDCDC 底 + 近黑字；管理员 = #E5F3E6 底 + 绿字）
//      + 「离线」16.2
//
// 与参考截图的差异（后端没这些字段，**不硬编假值**，详见报告「未接后端」）：
//   1. 群简介：Conversation 无 description 字段 → 读 `descriptionZh`/`description`；
//      为空时显示 l10n「暂无群简介」占位，不编假文案。
//   2. 群组号：无群号/短号字段 → 回落显示会话 ID（真实值）。
//   3. 卡2 数字：只有「照片和视频」「文件」能取到真值（群文件接口的 total）；
//      「共享链接」「语音消息」后端无聚合接口 → 不显示数字。
// ============================================================================

// ---------- 实测尺寸（逻辑 px） ----------
/// 白底头块（状态栏 + 顶部条 56 **之外**）的总高
const double _kHeadH = 384.3;

/// 头像距顶部条底边 8.3；群头像 128 方、圆角拟合 31.1
const double _kAvatarTop = 8.3;
const double _kAvatarD = 128.0;
const double _kAvatarR = 31.0;

const double _kNameSize = 30.6; // 7 字 ink 211.4 ⇒ 逐字 30.6
const double _kSealSize = 26.0; // 星徽 ink 26.0
const double _kSealGap = 10.6;
const double _kCountSize = 19.3; // 「位成员」逐字 19.3

/// 三个操作瓦片：72×72、圆角拟合 20.5、瓦片间距 40.7、标签 15.35
const double _kTileD = 72.0;
const double _kTileR = 20.5;
const double _kTileGap = 40.7;
const double _kTileLabelSize = 15.35;
const double _kTileLabelGap = 14.5;

/// 卡1：正文 21.7 / 行距 31.3；两个小标签 15.7；群组号 22
const double _kDescSize = 21.7;
const double _kDescLine = 31.3;
const double _kMiniLabelSize = 15.7;
const double _kGroupIdSize = 22.0;
const double _kCardTextLeft = 22.6; // 正文 ink 左 43.3 - 卡左 20.7
const double _kCardLabelLeft = 23.0; // 「描述」ink 左 43.7 - 卡左 20.7

/// 卡2：行高 75.8（卡高 381.8 = 5 行 + 4 条 0.7 分隔线）
/// 图标 ink 左 54.7（卡左 + 34.0）、文字 ink 左 108.0（卡左 + 87.3）
const double _kRowH = 75.8;
const double _kRowIconLeft = 34.0;
const double _kRowIconBox = 22.0;
const double _kRowTextLeft = 87.3;
const double _kRowTextSize = 21.0;
const double _kRowNumSize = 17.0;
const double _kChevronRight = 21.75; // 使 chevron ink 中心落在 365.2

/// 「成员」分组标题：ink 左 41.7、字号 15.9；右侧成员数 17 + 放大镜 22
const double _kSecTitleLeft = 41.7;
const double _kSecTitleSize = 15.9;
const double _kSecCountSize = 17.0;
const double _kSecIconSize = 22.0;

/// 成员行：行高 77.1、头像 51（圆角 9.3、距卡左 20.6）、昵称 21.7、副标题 16.2
const double _kMemRowH = 77.1;
const double _kMemAvatarD = 51.0;
const double _kMemAvatarR = 9.3;
const double _kMemAvatarLeft = 20.6;
const double _kMemTextLeft = 88.0; // 昵称 ink 左 108.7 - 卡左 20.7
const double _kMemNameSize = 21.7;
const double _kMemSubSize = 16.2;

/// 角色徽章：57×23、圆角 5、字号 13.5、左右内边距 8
const double _kTagH = 23.0;
const double _kTagR = 5.0;
const double _kTagSize = 13.5;
const double _kTagPadX = 8.0;

/// 卡片节奏：头块→卡1 25.4；卡1→卡2 23.3；卡2→「成员」标题 45.0；标题→成员卡 23.4
const double _kHeadToCard = 25.4;
const double _kCardGap = 23.3;
const double _kSecTop = 45.0;
const double _kSecBottom = 23.4;

/// 顶部条：内容高 56（返回/「…」ink 垂直中心落在状态栏 + 28.2，实测 87.2）
/// 返回用 `arrow_back_ios_new` @31（ink ≈ 10.3×20.7，ink 左缘 = 13.0 + 10.3 = 23.3）
const double _kTopBarH = 56.0;
const double _kBackSize = 31.0;
const double _kBackLeft = 13.0;
const double _kBackTop = 12.7;
const double _kDotsTop = 14.3;

// ---------- 实测颜色（深浅色各自适配） ----------
const Color _kOwnerName = Color(0xFF66C7A3); // 群主昵称绿（实测 #66C7A3/#69C7A3）
const Color _kOwnerTagBg = Color(0xFFDCDCDC);
const Color _kOwnerTagFg = Color(0xFF141517);
const Color _kAdminTagBg = Color(0xFFE5F3E6);
const Color _kAdminTagFg = Color(0xFF559857);
const Color _kOffline = Color(0xFF9B9B9B);
const Color _kNumColor = Color(0xFF989EA7);
const Color _kMiniLabel = Color(0xFF9CA0A8);
const Color _kTileFill = Color(0xFFF1F2F6);
const Color _kTileIcon = Color(0xFF23272F);
const Color _kTileLabel = Color(0xFF141517);

Color _ownerNameColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF5FC79B) : _kOwnerName;
Color _ownerTagBg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF3A3A3C) : _kOwnerTagBg;
Color _ownerTagFg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : _kOwnerTagFg;
Color _adminTagBg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF1F3A22) : _kAdminTagBg;
Color _adminTagFg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF6ECB74) : _kAdminTagFg;
Color _offlineColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kOffline;
Color _numColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kNumColor;
Color _miniLabelColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kMiniLabel;
Color _tileFillColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF2C2C2E) : _kTileFill;
Color _tileIconColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : _kTileIcon;
Color _tileLabelColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : _kTileLabel;

/// 群资料页（从会话设置页「群聊资料」推入）。
///
/// 构造签名 `GroupManagePage({required ConvItem conv})` 被
/// `conv_settings_page.dart:439` 使用，**不可更改**。
class GroupManagePage extends StatefulWidget {
  final ConvItem conv;
  const GroupManagePage({super.key, required this.conv});

  @override
  State<GroupManagePage> createState() => _GroupManagePageState();
}

class _GroupManagePageState extends State<GroupManagePage> {
  final _svc = ConversationService();

  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  bool _mute = false;
  int _memberTotal = 0;

  /// 卡2 的数字：photo/file 为 null = 接口不可用 → 不显示数字（不编 0）；
  /// link/voice 走 /message/media-count 真值（二十三批）。
  int? _photoCount;
  int? _fileCount;
  int _linkCount = 0;
  int _voiceCount = 0;

  ConvItem get conv => widget.conv;
  String get _convId => conv.id;

  String get _name {
    final n = conv.conversationName.trim();
    if (n.isNotEmpty) return n;
    final zh = conv.conversation['nameZh']?.toString().trim() ?? '';
    if (zh.isNotEmpty) return zh;
    return conv.conversation['nameEn']?.toString().trim() ?? '';
  }

  String get _avatarUrl => AppConfig.assetUrl(conv.avatarUrl);

  String get _announcement =>
      conv.conversation['announcementZh']?.toString() ?? '';

  String get _description {
    final d = conv.conversation['descriptionZh'] ??
        conv.conversation['description'] ??
        '';
    return d.toString().trim();
  }

  /// 群组号：后端暂无群号字段 → 回落会话 ID（真实值，不是编的）
  String get _groupId {
    final v = conv.conversation['shortId'] ?? conv.conversation['groupNo'] ?? '';
    final s = v.toString().trim();
    return s.isEmpty ? _convId : s;
  }

  @override
  void initState() {
    super.initState();
    _mute = conv.mute;
    _memberTotal = conv.memberCount;
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await _svc.members(_convId);
      if (!mounted) return;
      setState(() {
        _members = m;
        if (_svc.lastMembersCount > 0) _memberTotal = _svc.lastMembersCount;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    _loadCounts();
  }

  /// 卡2 的数字（2026-09-15 二十三批改口径）：改用 `/message/media-count`
  /// 按消息类型统计——原读群文件接口 total，但 conv_file 集合只在文件消息
  /// 落库时写入，图片/视频消息从不进集合 → 照片计数恒 0。四种类型现在都是真值。
  Future<void> _loadCounts() async {
    Future<int> count(String type) async {
      try {
        final r = await ApiClient.instance.dio.get(
          '/api/v1/message/media-count',
          queryParameters: {'conversationId': _convId, 'type': type},
          options: Options(
              headers: {'Authorization': 'Bearer ${await ApiClient.instance.readToken()}'}),
        );
        final body = r.data as Map<String, dynamic>;
        if (((body['code'] as num?)?.toInt() ?? 0) != 0) return 0;
        final d = body['data'];
        if (d is Map) return (d['count'] as num?)?.toInt() ?? 0;
        return 0;
      } catch (_) {
        return 0;
      }
    }

    final img = await count('image');
    final vid = await count('video');
    final doc = await count('file');
    final link = await count('link');
    final voice = await count('voice');
    if (!mounted) return;
    setState(() {
      _photoCount = img + vid;
      _fileCount = doc;
      _linkCount = link;
      _voiceCount = voice;
    });
  }

  // ---------------------------------------------------------------- 顶部条

  Widget _topBar(double top, double s) {
    return Container(
      color: context.setCard,
      height: top + _kTopBarH * s,
      padding: EdgeInsets.only(top: top),
      child: Stack(
        children: [
          // 返回「<」（实测 ink 11.3 × 19.7、ink 左缘 23.7、ink 中心 y 87.2）
          Positioned(
            left: _kBackLeft * s,
            top: _kBackTop * s,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: SizedBox(
                width: _kBackSize * s,
                height: _kBackSize * s,
                child: Icon(Icons.arrow_back_ios_new,
                    size: _kBackSize * s, color: context.setTitle),
              ),
            ),
          ),
          // 「…」（实测 ink 19.7 × 4.0、右缘 399.0、ink 中心 y 87.3）
          Positioned(
            right: 16.0 * s,
            top: _kDotsTop * s,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _showMoreSheet,
              child: SizedBox(
                width: 30 * s,
                height: 30 * s,
                child: Icon(Icons.more_horiz,
                    size: 30 * s, color: context.setTitle),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------- 白底头块

  Widget _profileHead(double s) {
    final t = AppLocalizations.of(context).t;
    return Container(
      color: context.setCard,
      height: _kHeadH * s,
      child: Column(
        children: [
          SizedBox(height: _kAvatarTop * s),
          AppAvatar(
            url: _avatarUrl,
            name: _name,
            size: _kAvatarD * s,
            radius: _kAvatarR * s,
          ),
          SizedBox(height: 21.55 * s),
          // 群名 + 星徽（整组居中：实测 86.3..334.3，中心 210.3）
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: _kNameSize * s,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                    color: context.setTitle,
                  ),
                ),
              ),
              SizedBox(width: _kSealGap * s),
              V2SealBadge(size: _kSealSize, color: context.setTitle),
            ],
          ),
          SizedBox(height: 16.4 * s),
          // 「741 位成员」
          Text(
            t('gmpMemberCount', {'count': '$_memberTotal'}),
            style: TextStyle(
              fontSize: _kCountSize * s,
              height: 1.0,
              color: _offlineColor(context),
            ),
          ),
          SizedBox(height: 29.15 * s),
          _actionTiles(s),
        ],
      ),
    );
  }

  Widget _actionTiles(double s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _tile(s,
            icon: Icons.notifications_off_outlined,
            labelKey: 'gmpMute',
            onTap: _toggleMute),
        SizedBox(width: _kTileGap * s),
        _tile(s,
            icon: Icons.search_rounded,
            labelKey: 'gmpSearch',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SearchPage()))),
        SizedBox(width: _kTileGap * s),
        _tile(s,
            icon: Icons.campaign_outlined,
            labelKey: 'gmpAnnounce',
            onTap: _showAnnouncement),
      ],
    );
  }

  Widget _tile(double s,
      {required IconData icon,
      required String labelKey,
      required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _kTileD * s,
            height: _kTileD * s,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _tileFillColor(context),
              borderRadius: BorderRadius.circular(_kTileR * s),
            ),
            child: Icon(icon, size: 30 * s, color: _tileIconColor(context)),
          ),
          SizedBox(height: _kTileLabelGap * s),
          Text(
            AppLocalizations.of(context).t(labelKey),
            style: TextStyle(
              fontSize: _kTileLabelSize * s,
              height: 1.0,
              color: _tileLabelColor(context),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 卡 1

  Widget _descCard(double s) {
    final t = AppLocalizations.of(context).t;
    final desc = _description;
    return V2SetCard(rows: [
      Padding(
        padding: EdgeInsets.only(
            left: _kCardTextLeft * s,
            right: _kCardTextLeft * s,
            top: 14.7 * s,
            bottom: 16.1 * s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              // 后端无群简介字段 → 读 descriptionZh；为空显示占位文案（不编假数据）
              desc.isEmpty ? t('gmpNoDescription') : desc,
              style: TextStyle(
                fontSize: _kDescSize * s,
                height: _kDescLine / _kDescSize,
                color:
                    desc.isEmpty ? _miniLabelColor(context) : context.setTitle,
              ),
            ),
            SizedBox(height: 5.7 * s),
            Text(
              t('gmpDescription'),
              style: TextStyle(
                fontSize: _kMiniLabelSize * s,
                height: 1.0,
                color: _miniLabelColor(context),
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: EdgeInsets.only(
            left: _kCardLabelLeft * s,
            right: _kCardLabelLeft * s,
            top: 19.85 * s,
            bottom: 18.95 * s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '@$_groupId',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _kGroupIdSize * s,
                height: 1.0,
                color: context.setTitle,
              ),
            ),
            SizedBox(height: 9.3 * s),
            Text(
              t('gmpGroupNo'),
              style: TextStyle(
                fontSize: _kMiniLabelSize * s,
                height: 1.0,
                color: _miniLabelColor(context),
              ),
            ),
          ],
        ),
      ),
    ]);
  }

  // ------------------------------------------------------------------ 卡 2

  Widget _mediaCard(double s) {
    return V2SetCard(rows: [
      _mediaRow(s,
          icon: Icons.image_outlined,
          labelKey: 'gmpPhotosVideos',
          count: _photoCount,
          onTap: _openFiles),
      _mediaRow(s,
          icon: Icons.insert_drive_file_outlined,
          labelKey: 'chatDrawerFile',
          count: _fileCount,
          onTap: _openFiles),
      _mediaRow(s,
          icon: Icons.link_rounded,
          labelKey: 'gmpSharedLinks',
          count: _linkCount,
          onTap: _openFiles),
      _mediaRow(s,
          icon: Icons.mic_none,
          labelKey: 'gmpVoiceMessages',
          count: _voiceCount,
          onTap: _openFiles),
      _mediaRow(s,
          icon: Icons.qr_code_2,
          labelKey: 'groupQrSection',
          count: null,
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => GroupQrPage(conv: conv)))),
    ]);
  }

  void _openFiles() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => GroupFilePage(convId: _convId, convName: _name)));
  }

  Widget _mediaRow(double s,
      {required IconData icon,
      required String labelKey,
      required int? count,
      required VoidCallback onTap}) {
    return SizedBox(
      height: _kRowH * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              SizedBox(width: _kRowIconLeft * s),
              SizedBox(
                width: _kRowIconBox * s,
                child: Icon(icon, size: 26 * s, color: context.setTitle),
              ),
              SizedBox(
                  width: (_kRowTextLeft - _kRowIconLeft - _kRowIconBox) * s),
              Expanded(
                child: Text(
                  AppLocalizations.of(context).t(labelKey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: _kRowTextSize * s,
                      height: 1.0,
                      color: context.setTitle),
                ),
              ),
              // 只有拿到真实统计的项才显示数字（后端无接口的项不编 0）
              if (count != null)
                Text(
                  '$count',
                  style: TextStyle(
                      fontSize: _kRowNumSize * s,
                      height: 1.0,
                      color: _numColor(context)),
                ),
              SizedBox(width: 21.7 * s),
              Padding(
                padding: EdgeInsets.only(right: _kChevronRight * s),
                child: Icon(Icons.chevron_right,
                    size: 24 * s, color: context.setChevron),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 成员区

  Widget _membersHeader(double s) {
    return Padding(
      padding: EdgeInsets.only(left: _kSecTitleLeft * s, right: 15.9 * s),
      child: SizedBox(
        height: _kSecIconSize * s,
        child: Row(
          children: [
            Text(
              AppLocalizations.of(context).t('chatMember'),
              style: TextStyle(
                  fontSize: _kSecTitleSize * s,
                  height: 1.0,
                  color: context.setLabel),
            ),
            const Spacer(),
            Text(
              _loading ? '' : '${_members.length}',
              style: TextStyle(
                  fontSize: _kSecCountSize * s,
                  height: 1.0,
                  color: _numColor(context)),
            ),
            SizedBox(width: 15.2 * s),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openMembers,
              child: Icon(Icons.search_rounded,
                  size: _kSecIconSize * s, color: context.setTitle),
            ),
          ],
        ),
      ),
    );
  }

  void _openMembers() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => GroupMembersPage(conv: conv)))
        .then((_) {
      if (mounted) _load();
    });
  }

  Widget _membersCard(double s) {
    if (_loading) {
      return const V2SetCard(rows: [SizedBox(height: 120)]);
    }
    if (_members.isEmpty) {
      return V2SetCard(rows: [
        SizedBox(
          height: _kMemRowH * s,
          child: Center(
            child: Text(
              AppLocalizations.of(context).t('convSetNoMembers'),
              style:
                  TextStyle(fontSize: _kMemSubSize * s, color: context.setSub),
            ),
          ),
        ),
      ]);
    }
    return V2SetCard(rows: [for (final m in _members) _memberRow(s, m)]);
  }

  Widget _memberRow(double s, Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final realName = (m['nickname']?.toString().trim().isNotEmpty ?? false)
        ? m['nickname'].toString()
        : (m['account']?.toString() ?? t('contactsUser'));
    final remark = m['remark']?.toString() ?? '';
    final name = remark.isNotEmpty ? remark : realName;
    final role = (m['role'] as num?)?.toInt() ?? 3;
    final isOwner = role == 1;
    final isAdmin = role == 2;

    return SizedBox(
      height: _kMemRowH * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          // 与「查看全部成员」一致：走群成员页（成员详情复用同一入口）
          onTap: _openMembers,
          child: Row(
            children: [
              SizedBox(width: _kMemAvatarLeft * s),
              AppAvatar(
                url: AppConfig.assetUrl(m['avatar']?.toString() ?? ''),
                name: name,
                size: _kMemAvatarD * s,
                radius: _kMemAvatarR * s,
              ),
              SizedBox(
                  width: (_kMemTextLeft - _kMemAvatarLeft - _kMemAvatarD) * s),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _kMemNameSize * s,
                              height: 1.0,
                              // 群主昵称绿色（实测 #66C7A3），其余近黑
                              color: isOwner
                                  ? _ownerNameColor(context)
                                  : context.setTitle,
                            ),
                          ),
                        ),
                        if (isOwner || isAdmin) ...[
                          SizedBox(width: 8.7 * s),
                          _roleTag(
                              s,
                              isOwner ? 'gmpRoleCreator' : 'groupRoleAdmin',
                              isOwner),
                        ],
                      ],
                    ),
                    SizedBox(height: 10.7 * s),
                    Text(
                      (m['online'] == true)
                          ? t('chatStatusOnline')
                          : t('convSetOffline'),
                      style: TextStyle(
                          fontSize: _kMemSubSize * s,
                          height: 1.0,
                          color: _offlineColor(context)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.only(right: _kChevronRight * s),
                child: Icon(Icons.chevron_right,
                    size: 24 * s, color: context.setChevron),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 角色徽章：创建者 = 灰底近黑字；管理员 = 浅绿底绿字（均为参考包实测）
  Widget _roleTag(double s, String labelKey, bool owner) {
    return Container(
      height: _kTagH * s,
      padding: EdgeInsets.symmetric(horizontal: _kTagPadX * s),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: owner ? _ownerTagBg(context) : _adminTagBg(context),
        borderRadius: BorderRadius.circular(_kTagR * s),
      ),
      child: Text(
        AppLocalizations.of(context).t(labelKey),
        style: TextStyle(
          fontSize: _kTagSize * s,
          height: 1.0,
          color: owner ? _ownerTagFg(context) : _adminTagFg(context),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 交互

  Future<void> _toggleMute() async {
    final t = AppLocalizations.of(context).t;
    final next = !_mute;
    setState(() => _mute = next);
    final ok = await _svc.setMute(_convId, next);
    if (!mounted) return;
    if (!ok) {
      setState(() => _mute = !next); // 失败回滚
      AppDialogs.toast(context, t('groupSettingsSaveFailed'));
      return;
    }
    conv.conversation['mute'] = next;
    AppDialogs.toast(context, next ? t('gmpMuteOn') : t('gmpMuteOff'));
  }

  void _showAnnouncement() {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.setCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16 * s))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20.7 * s, 18 * s, 20.7 * s, 20 * s),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('convSetGroupAnnouncement'),
                  style: TextStyle(
                      fontSize: 17 * s,
                      fontWeight: FontWeight.w600,
                      color: ctx.setTitle)),
              SizedBox(height: 14 * s),
              Text(
                _announcement.isEmpty
                    ? t('convSetNoAnnouncement')
                    : _announcement,
                style: TextStyle(
                    fontSize: 16 * s,
                    height: 1.5,
                    color:
                        _announcement.isEmpty ? ctx.setSub : ctx.setTitle),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右上「…」：群管理设置 / 群二维码（保留原有全部入口）
  void _showMoreSheet() {
    final s = v2Scale(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.setCard,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16 * s))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 8 * s),
            ListTile(
              leading: Icon(Icons.settings_outlined,
                  size: 22 * s, color: ctx.setTitle),
              title: Text(AppLocalizations.of(ctx).t('convSetGroupAdmin'),
                  style: TextStyle(fontSize: 16 * s, color: ctx.setTitle)),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => _GroupSettingsPage(conv: conv)));
              },
            ),
            ListTile(
              leading: Icon(Icons.qr_code_2, size: 22 * s, color: ctx.setTitle),
              title: Text(AppLocalizations.of(ctx).t('groupQrTitle'),
                  style: TextStyle(fontSize: 16 * s, color: ctx.setTitle)),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => GroupQrPage(conv: conv)));
              },
            ),
            SizedBox(height: 8 * s),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: context.setPageBg,
      body: Column(
        children: [
          _topBar(top, s),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _profileHead(s),
                SizedBox(height: _kHeadToCard * s),
                _descCard(s),
                SizedBox(height: _kCardGap * s),
                _mediaCard(s),
                SizedBox(height: _kSecTop * s),
                _membersHeader(s),
                SizedBox(height: _kSecBottom * s),
                _membersCard(s),
                SizedBox(height: 40 * s + MediaQuery.paddingOf(context).bottom),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 群管理设置（原 `group_manage_page` 的全部业务：二维码进群 / 成员隐私 /
// 全员禁言 / 允许成员邀请 / 群管理员增删 / 群成员管理入口），
// 现由群资料页右上「…」进入。接口调用、乐观更新、失败回滚逻辑与原实现一致。
// ============================================================================
class _GroupSettingsPage extends StatefulWidget {
  final ConvItem conv;
  const _GroupSettingsPage({required this.conv});

  @override
  State<_GroupSettingsPage> createState() => _GroupSettingsPageState();
}

class _GroupSettingsPageState extends State<_GroupSettingsPage> {
  final _svc = ConversationService();
  Map<String, dynamic> _settings = {};
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _svc.groupSettings(widget.conv.id);
      final m = await _svc.members(widget.conv.id);
      if (mounted) {
        setState(() {
          _settings = s;
          _members = m;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(String key, bool v) async {
    if (_saving) return;
    final t = AppLocalizations.of(context).t;
    setState(() {
      _settings = {..._settings, key: v}; // 乐观更新
      _saving = true;
    });
    try {
      switch (key) {
        case 'muteAll':
          await _svc.setGroupSettings(widget.conv.id, muteAll: v);
        case 'privacyEnabled':
          await _svc.setGroupSettings(widget.conv.id, privacyEnabled: v);
        case 'allowMemberInvite':
          await _svc.setGroupSettings(widget.conv.id, allowInvite: v);
        case 'qrJoinEnabled':
          await _svc.setGroupSettings(widget.conv.id, qrJoin: v);
      }
      if (mounted) AppDialogs.toast(context, t('groupSettingsSaved'));
    } catch (_) {
      if (mounted) {
        setState(() => _settings = {..._settings, key: !v}); // 失败回滚
        AppDialogs.toast(context, t('groupSettingsSaveFailed'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 添加管理员：从普通成员中单选
  Future<void> _addAdmin() async {
    final t = AppLocalizations.of(context).t;
    final candidates =
        _members.where((m) => (m['role'] as num?)?.toInt() == 3).toList();
    if (candidates.isEmpty) {
      AppDialogs.toast(context, t('groupNoAdminCandidate'));
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: ctx.cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(t('groupAddAdminPick'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (_, i) {
                  final m = candidates[i];
                  final name = m['nickname']?.toString() ??
                      m['account']?.toString() ??
                      '';
                  return ListTile(
                    leading: AppAvatar(
                        url: AppConfig.assetUrl(m['avatar']?.toString() ?? ''),
                        name: name,
                        size: 36),
                    title:
                        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.of(ctx).pop(m),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await _svc.setGroupAdmin(
          widget.conv.id, picked['id']?.toString() ?? '', true);
      if (mounted) {
        AppDialogs.toast(context, t('groupSetAdminSuccess'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupSetAdminFailed'));
    }
  }

  Future<void> _removeAdmin(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context).t;
    try {
      await _svc.setGroupAdmin(widget.conv.id, m['id']?.toString() ?? '', false);
      if (mounted) {
        AppDialogs.toast(context, t('groupUnsetAdminSuccess'));
        _load();
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('groupSetAdminFailed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final admins =
        _members.where((m) => (m['role'] as num?)?.toInt() == 2).toList();
    if (_loading) {
      return V2SetScaffold(
        title: t('convSetGroupAdmin'),
        children: const [Center(child: CircularProgressIndicator())],
      );
    }
    return V2SetScaffold(
      title: t('convSetGroupAdmin'),
      children: [
        V2SetCard(rows: [
          V2SetRow(
            title: t('groupSwitchQrJoin'),
            subtitle: t('groupSwitchQrJoinSub'),
            trailing: V2SetSwitch(
                value: _settings['qrJoinEnabled'] == true,
                onChanged: (v) => _toggle('qrJoinEnabled', v)),
          ),
          V2SetRow(
            title: t('groupSwitchPrivacy'),
            subtitle: t('groupSwitchPrivacySub'),
            trailing: V2SetSwitch(
                value: _settings['privacyEnabled'] == true,
                onChanged: (v) => _toggle('privacyEnabled', v)),
          ),
          V2SetRow(
            title: t('groupSwitchMuteAll'),
            subtitle: t('groupSwitchMuteAllSub'),
            trailing: V2SetSwitch(
                value: _settings['muteAll'] == true,
                onChanged: (v) => _toggle('muteAll', v)),
          ),
          V2SetRow(
            title: t('groupSwitchAllowInvite'),
            subtitle: t('groupSwitchAllowInviteSub'),
            trailing: V2SetSwitch(
                value: _settings['allowMemberInvite'] == true,
                onChanged: (v) => _toggle('allowMemberInvite', v)),
          ),
        ]),
        const V2SetGap.beforeLabel(),
        V2SetSectionLabel(t('groupAdminsSection')),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [
          for (final m in admins)
            V2SetRow(
              title: m['nickname']?.toString() ??
                  m['account']?.toString() ??
                  t('contactsUser'),
              leading: AppAvatar(
                  url: AppConfig.assetUrl(m['avatar']?.toString() ?? ''),
                  name: m['nickname']?.toString() ?? '',
                  size: 40 * s,
                  radius: 9 * s),
              trailing: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _removeAdmin(m),
                child: Text(t('groupRemoveAdmin'),
                    style:
                        TextStyle(fontSize: 14 * s, color: context.setDanger)),
              ),
            ),
          V2SetRow(
            title: t('groupAddAdmin'),
            leading: Icon(Icons.person_add_alt_1,
                size: 22 * s, color: context.setTitle),
            showChevron: true,
            onTap: _addAdmin,
          ),
        ]),
        const V2SetGap.beforeLabel(),
        V2SetSectionLabel(t('convSetGroupMembers')),
        const V2SetGap.afterLabel(),
        V2SetCard(rows: [
          V2SetRow(
            title: t('groupMembersManageEntry'),
            leading:
                Icon(Icons.group_outlined, size: 22 * s, color: context.setTitle),
            showChevron: true,
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => GroupMembersPage(conv: widget.conv)));
              if (mounted) _load();
            },
          ),
        ]),
      ],
    );
  }
}
