// 输入条上方的终端权限胶囊：显示当前档位，点一下进设置。
// 原版灰 / 安全黄 / 高危红——危险档位不该安安静静待在那儿。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/phone_state.dart';
import '../../phone/shell_permissions_page.dart';
import '../../theme/theme.dart';
import 'dock_pill.dart';

/// 「▣ 启用终端                  点击设置」
/// 「▣ 终端 · 安全               点击设置」
/// 「▣ 终端 · 高危               点击设置」
class RootPill extends ConsumerWidget {
  const RootPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shell = ref.watch(phoneProvider.select((s) => s.status.shell));
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final (label, color, icon) = switch (shell.mode) {
      'safe' => ('终端 · 安全', Colors.amber.shade700, Icons.shield_outlined),
      'full' => ('终端 · 高危', Colors.red.shade600, Icons.terminal),
      _ => ('启用终端', theme.colorScheme.onSurfaceVariant, Icons.terminal_outlined),
    };
    return Semantics(
      button: true,
      label: '$label，点击设置终端权限',
      onTap: () => _open(context),
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        borderRadius: DockMetrics.shape,
        grouped: true,
        onTap: () => _open(context),
        child: DockRow(
          leading: DockGlyph.icon(icon, color: color),
          content: Text(label, style: DockText.title(context, color: color)),
          accessory: Text('点击设置', style: DockText.detail(context)),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ShellPermissionsPage()),
    );
  }
}
