import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../phone/phone_channel.dart';
import '../../state/phone_state.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';

/// 设置 → 手机操控 → 终端权限：三档 + 额外设置（命令清单、脚本确认）。
class ShellPermissionsPage extends ConsumerStatefulWidget {
  const ShellPermissionsPage({super.key});

  @override
  ConsumerState<ShellPermissionsPage> createState() => _ShellPermissionsPageState();
}

class _ShellPermissionsPageState extends ConsumerState<ShellPermissionsPage> {
  bool _extraOpen = false;

  static const _groups = <String, String>{
    'read': '只读命令',
    'file': '文件操作',
    'system': '系统命令',
    'network': '网络',
    'packages': '包管理',
    'script': '脚本执行',
  };

  Future<void> _pick(String mode) async {
    final notifier = ref.read(phoneProvider.notifier);
    if (mode == 'original') {
      await notifier.setShellMode('original');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(mode == 'safe' ? '切到安全模式？' : '切到高危模式？'),
        content: Text(
          mode == 'safe'
              ? 'AI 能执行你允许的命令，可以读文件、看系统状态、复制文件；但改不了系统分区，碰不到你的照片，也不能运行脚本。'
              : 'AI 能在你的手机上执行任意命令，包括删文件、改系统设置。所有操作都留在对话里。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('确认切换'),
          ),
        ],
      ),
    );
    if (ok == true) await notifier.setShellMode(mode);
  }

  Future<void> _confirmBypass(bool on) async {
    final notifier = ref.read(phoneProvider.notifier);
    if (!on) {
      await notifier.setScriptConfirmBypass(false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('脚本不再逐次确认？'),
        content: const Text(
          '打开后，AI 执行脚本类命令（sh / python / node 等）时不会再弹窗问你。脚本里可以写任何东西，包括删除文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('我知道了，打开'),
          ),
        ],
      ),
    );
    if (ok == true) await notifier.setScriptConfirmBypass(true);
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(phoneProvider.select((s) => s.status.shell));
    return AppPage(
      title: '终端权限',
      subtitle: const Text('AI 能在这台手机上执行什么'),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            children: [
              SettingsSection(
                title: '档位',
                children: [
                  _mode(
                    'original',
                    '原版模式',
                    '和原版 DSH Go 一样，AI 只能看屏幕、点屏幕、打字、开 App；不能执行终端命令。',
                    Colors.green.shade600,
                    shell,
                  ),
                  _mode(
                    'safe',
                    '安全模式',
                    'AI 能执行你允许的命令，可以读文件、看系统状态、复制文件；但改不了系统分区，碰不到你的照片，也不能运行脚本。',
                    Colors.amber.shade700,
                    shell,
                  ),
                  _mode(
                    'full',
                    '高危模式',
                    'AI 能在你的手机上执行任意命令，包括删文件、改系统设置；所有操作都留在对话里。',
                    Colors.red.shade600,
                    shell,
                  ),
                ],
              ),
              if (!shell.isOriginal)
                SettingsSection(
                  title: '额外设置',
                  children: [
                    SettingsSwitchTile(
                      icon: Icons.tune,
                      tint: 0,
                      title: '展开命令清单',
                      subtitle: '按组开关，没开组的命令会被直接拒绝',
                      value: _extraOpen,
                      onChanged: (v) => setState(() => _extraOpen = v),
                    ),
                    if (_extraOpen) ...[
                      for (final entry in _groups.entries)
                        _groupTile(entry.key, entry.value, shell),
                      if (shell.mode == 'safe')
                        SettingsSwitchTile(
                          icon: Icons.terminal,
                          tint: 0,
                          title: '后续脚本无需确认',
                          subtitle: '打开后，脚本类命令不再每次弹窗',
                          value: shell.scriptConfirmBypass,
                          onChanged: (v) => unawaited(_confirmBypass(v)),
                        ),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _mode(
    String key,
    String title,
    String desc,
    Color color,
    PhoneShellStatus shell,
  ) {
    final on = shell.mode == key;
    return SettingsTile(
      icon: Icons.terminal,
      tint: 0,
      title: title,
      subtitle: desc,
      chevron: false,
      trailing: Icon(
        on ? Icons.check_circle : Icons.circle_outlined,
        color: on ? color : color.withOpacity(0.45),
        size: 22,
      ),
      onTap: () => unawaited(_pick(key)),
    );
  }

  Widget _groupTile(String key, String label, PhoneShellStatus shell) {
    final names = shell.commands
        .where((c) => c.group == key)
        .map((c) => c.name)
        .toList(growable: false);
    if (names.isEmpty) return const SizedBox.shrink();
    final on = names.where(shell.isAllowed).length;
    return SettingsSwitchTile(
      icon: Icons.playlist_add_check,
      tint: 0,
      title: label,
      subtitle: '$on / ${names.length} 个命令',
      value: on == names.length,
      onChanged: (v) {
        final next = shell.allowed.toSet();
        if (v) {
          next.addAll(names);
        } else {
          next.removeAll(names);
        }
        unawaited(
          ref.read(phoneProvider.notifier).setAllowedCommands(next.toList()),
        );
      },
    );
  }
}
