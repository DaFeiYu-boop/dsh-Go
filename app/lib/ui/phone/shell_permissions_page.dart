import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../phone/phone_channel.dart';
import '../../state/phone_state.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';

const _prefShowCommands = 'shell_show_commands';
const _prefShowRecent = 'shell_show_recent';

/// 终端权限：三档 + 分类命令开关 + 最近记录。
///
/// 设计上刻意分开两种展开状态：
/// - 「展开命令清单」是总开关，写进 prefs，退出重进要记住；
/// - 每个分类的展开只是当前页面里的临时状态，退出重进一律收起。
class ShellPermissionsPage extends ConsumerStatefulWidget {
  const ShellPermissionsPage({super.key});

  @override
  ConsumerState<ShellPermissionsPage> createState() => _ShellPermissionsPageState();
}

class _ShellPermissionsPageState extends ConsumerState<ShellPermissionsPage> {
  bool _showCommands = false;
  // 最近记录的展开状态也要提到页面级：放在子组件的 State 里，滚出视口
  // 被 Flutter 回收后就会重置成默认值，看起来像「开关自己又打开了」。
  bool _showRecent = true;
  final Set<String> _expanded = <String>{};
  bool _loaded = false;

  /// 乐观更新的本地副本：点一下就改这里，背后的写入合并成一次。
  String? _mode;
  Set<String>? _allowed;
  bool? _sdcard;
  Future<void>? _flush;
  late final PhoneController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(phoneProvider.notifier);
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _showCommands = p.getBool(_prefShowCommands) ?? false;
        _showRecent = p.getBool(_prefShowRecent) ?? true;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    // 页面一关就立刻把还没落盘的勾选写掉，别等 300ms 的合并窗口。
    if (_flush != null && _allowed != null) {
      _controller.setAllowedCommands(_allowed!.toList());
    }
    super.dispose();
  }

  void _setShowCommands(bool on) {
    setState(() => _showCommands = on);
    SharedPreferences.getInstance().then((p) => p.setBool(_prefShowCommands, on));
  }

  void _setShowRecent(bool on) {
    setState(() => _showRecent = on);
    SharedPreferences.getInstance().then((p) => p.setBool(_prefShowRecent, on));
  }

  /// 切档位：先改本地、立刻重建，再异步落盘。
  void _pickMode(PhoneShellStatus shell, String mode) {
    if (mode == shell.mode) return;
    final controller = ref.read(phoneProvider.notifier);

    Future<void> apply() async {
      setState(() => _mode = mode);
      final ok = await controller.setShellMode(mode);
      if (!mounted) return;
      if (!ok) setState(() => _mode = null);
    }

    if (mode == 'full') {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('切到高危模式？'),
          content: const Text(
            '这个档位里，AI 能在你的手机上执行任意命令，包括删文件、改系统设置。\n\n'
            '所有操作都会留在对话和下面的记录里，但它不会每次问你。',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                apply();
              },
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
      return;
    }
    apply();
  }

  void _toggleCommand(PhoneShellStatus shell, String name, bool on) {
    final base = Set<String>.from(_allowed ?? shell.allowed);
    if (on) {
      base.add(name);
    } else {
      base.remove(name);
    }
    setState(() => _allowed = base);
    _scheduleFlush(() => _controller.setAllowedCommands(base.toList()));
  }

  void _toggleGroup(PhoneShellStatus shell, String group, bool on) {
    final names = shell.commands.where((c) => c.group == group).map((c) => c.name);
    final base = Set<String>.from(_allowed ?? shell.allowed);
    if (on) {
      base.addAll(names);
    } else {
      base.removeAll(names);
    }
    setState(() => _allowed = base);
    _scheduleFlush(() => _controller.setAllowedCommands(base.toList()));
  }

  /// 300ms 内的连续点击合并成一次写入。
  void _scheduleFlush(Future<void> Function() run) {
    _flush = run();
  }

  Future<void> _toggleSdcard(PhoneShellStatus shell, bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('允许读写整个 /sdcard？'),
          content: const Text(
            '/sdcard 里除了 Download，还有照片（DCIM）、别的 App 的文件夹。\n\n'
            '打开之后 AI 就能动这些地方，删掉的东西没有回收站。\n'
            '系统的 /system、/data/adb 和其他 App 的私有目录仍然碰不到。',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仍然打开')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _sdcard = on);
    final done = await ref.read(phoneProvider.notifier).setSdcardAllowed(on);
    if (!mounted) return;
    if (!done) setState(() => _sdcard = null);
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(phoneProvider.select((s) => s.status.shell));
    final mode = _mode ?? shell.mode;
    final allowed = _allowed ?? shell.allowed.toSet();
    // 刚切档、服务端 status 还没回来时，别拿旧档位留下的 sdcardAllowed 顶包
    // （高危恒开，切回进阶会先显示开、1.5 秒后再关，闪一下）。
    // 服务端确认（shell.mode == _mode）之前才算「切档中」，否则一直卡在 false 上。
    final pendingMode = _mode != null && shell.mode != _mode;
    final sdcard = _sdcard ?? (mode == 'full' ? true : (pendingMode ? false : shell.sdcardAllowed));
    final isOriginal = mode == 'original';
    final isSafe = mode == 'safe';
    final isFull = mode == 'full';

    // 档位一变，本地乐观副本就作废，以服务端为准。
    if (_mode != null && shell.mode == _mode) {
      _mode = null;
      _allowed = null;
      _sdcard = null;
    }

    return AppPage.list(
      title: '终端权限',
      subtitle: const Text('决定 AI 能在这台手机上执行哪些命令'),
      children: [
        SettingsSection(
          title: '档位',
          children: [
            _TierTile(
              label: '原版模式',
              tone: Colors.green,
              selected: isOriginal,
              summary: '和原版一样：只能看屏幕、点屏幕、打字、开 App，不能执行命令。',
              onTap: () => _pickMode(shell, 'original'),
            ),
            _TierTile(
              label: '进阶模式',
              tone: Colors.amber,
              selected: isSafe,
              summary: '只跑你勾选的命令：能读文件、看状态、复制；脚本和包管理锁死。',
              onTap: () => _pickMode(shell, 'safe'),
            ),
            _TierTile(
              label: '高危模式',
              tone: Colors.red,
              selected: mode == 'full',
              summary: '能执行任意命令，包括删文件、改系统设置。',
              onTap: () => _pickMode(shell, 'full'),
            ),
          ],
        ),
        if (!isOriginal && _loaded) ...[
          SettingsSection(
            title: '额外设置',
            children: [
              SettingsSwitchTile(
                title: '展开命令清单',
                subtitle: '展开后可以逐条开关；收起仍保留你的选择',
                value: _showCommands,
                onChanged: _setShowCommands,
              ),
              if (!isFull)
                SettingsSwitchTile(
                  title: '允许读写整个 /sdcard',
                  subtitle: sdcard ? '已允许：包括照片和别的 App 的文件夹（相册只能读和新建，不能删）' : '未允许：只能写 Download',
                  value: sdcard,
                  onChanged: (v) => _toggleSdcard(shell, v),
                ),
            ],
          ),
          if (_showCommands)
            for (final group in _groups(shell))
              _groupSection(shell, group, allowed, isSafe),
          _RecentSection(limit: 100, open: _showRecent, onOpenChanged: _setShowRecent),
        ],
      ],
    );
  }

  List<_CommandGroup> _groups(PhoneShellStatus shell) {
    final order = <String>['read', 'file', 'system', 'network', 'packages', 'script'];
    final titles = <String, String>{
      'read': '只读命令',
      'file': '文件操作',
      'system': '系统操作',
      'network': '网络',
      'packages': '包管理',
      'script': '脚本执行',
    };
    final descs = <String, String>{
      'read': '只看不改：读文件、看进程和系统状态',
      'file': '复制、移动、删除；只能碰 Download、tmp、App 私有目录',
      'system': '安卓层面的开关：装应用、模拟点击、改设置',
      'network': '联网请求、测速、查 DNS',
      'packages': 'apt / pip / npm / git，第一次用要联网',
      'script': '把整段脚本交给解释器：内容不受白名单约束',
    };
    return [
      for (final id in order)
        if (shell.commands.any((c) => c.group == id))
          _CommandGroup(
            id: id,
            title: titles[id] ?? id,
            desc: descs[id] ?? '',
            commands: shell.commands.where((c) => c.group == id).toList(growable: false),
          ),
    ];
  }

  Widget _groupSection(
    PhoneShellStatus shell,
    _CommandGroup group,
    Set<String> allowed,
    bool isSafe,
  ) {
    // 进阶模式：包管理和脚本整组锁死，不可勾选。
    final locked = isSafe && (group.id == 'packages' || group.id == 'script');
    final on = group.commands.every((c) => allowed.contains(c.name));
    final open = _expanded.contains(group.id);

    return SettingsSection(
      title: group.title,
      children: [
        SettingsTile(
          title: '整组开关',
          subtitle: locked ? '进阶模式下这一组锁死，切到高危才能用' : group.desc,
          // 点整行 = 展开这一组；总开关在右边的 Switch 上，两个互不干扰。
          onTap: () => setState(() {
            if (open) {
              _expanded.remove(group.id);
            } else {
              _expanded.add(group.id);
            }
          }),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                open ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: Theme.of(context).colorScheme.outline,
              ),
              Switch(
                value: locked ? false : on,
                onChanged: locked ? null : (v) => _toggleGroup(shell, group.id, v),
              ),

            ],
          ),
        ),
        if (open)
          for (final c in group.commands)
            SettingsSwitchTile(
              title: c.name,
              subtitle: c.desc,
              value: locked ? false : allowed.contains(c.name),
              onChanged: locked ? null : (v) => _toggleCommand(shell, c.name, v),
            ),
      ],
    );
  }
}

class _CommandGroup {
  const _CommandGroup({
    required this.id,
    required this.title,
    required this.desc,
    required this.commands,
  });

  final String id;
  final String title;
  final String desc;
  final List<PhoneShellCommand> commands;
}

class _TierTile extends StatelessWidget {
  const _TierTile({
    required this.label,
    required this.tone,
    required this.selected,
    required this.summary,
    required this.onTap,
  });

  final String label;
  final Color tone;
  final bool selected;
  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsTile(
      icon: Icons.circle,
      tint: 0,
      title: label,
      subtitle: summary,
      onTap: onTap,
      trailing: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? tone : scheme.outlineVariant,
      ),
    );
  }
}

/// 最近记录：默认展开，显示真实命令。
class _RecentSection extends ConsumerStatefulWidget {
  const _RecentSection({
    required this.limit,
    required this.open,
    required this.onOpenChanged,
  });

  final int limit;
  final bool open;
  final ValueChanged<bool> onOpenChanged;

  @override
  ConsumerState<_RecentSection> createState() => _RecentSectionState();
}

class _RecentSectionState extends ConsumerState<_RecentSection> {
  @override
  void initState() {
    super.initState();
    // 进页面拉一次，之后跟着 state 走，不再自己持有列表。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(phoneProvider.notifier).refreshLog(limit: widget.limit);
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(phoneProvider.select((s) => s.log));
    return SettingsSection(
      title: '最近记录',
      children: [
        SettingsSwitchTile(
          title: '展开最近记录',
          subtitle: entries.isEmpty
              ? '还没有记录'
              : '最近 ${entries.length} 条（最多 ${widget.limit}）',
          value: widget.open,
          onChanged: widget.onOpenChanged,
        ),
        if (widget.open)
          for (final e in entries.take(widget.limit))
            SettingsTile(
              icon: Icons.chevron_right,
              title: e.summary.isEmpty ? e.tool : e.summary,
              subtitle: [
                e.tool,
                _stamp(e.time),
                if (e.rawDecision != null && e.rawDecision!.isNotEmpty) e.rawDecision!,
              ].where((x) => x.isNotEmpty).join(' · '),
            ),
      ],
    );
  }

  String _stamp(DateTime? t) {
    if (t == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
