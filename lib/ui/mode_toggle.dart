import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'chaos_mode.dart';
import 'help_tip.dart';

/// Header pill switching between Focus (calm) and Chaos (meme sounds +
/// effects). Tapping the already-active Chaos side opens the sound config.
class ModeToggle extends StatelessWidget {
  const ModeToggle({super.key, this.compact = false});

  /// Emoji-only segments (for tight app bars).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final chaos = state.settings.chaosMode;

    void setMode(bool toChaos) {
      if (toChaos == chaos) {
        // Re-tapping active Chaos opens its sound configuration.
        if (chaos) showChaosModeDialog(context);
        return;
      }
      state.settings.chaosMode = toChaos;
      state.updateSettings(state.settings);
      if (toChaos) state.sounds.play('meme_201'); // vine boom: hello chaos
    }

    return Container(
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Palette.bg,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(
            emoji: '🧘',
            label: 'Focus',
            selected: !chaos,
            color: Palette.accent,
            title: 'Focus mode',
            tooltip: 'Quiet working: no sounds and no effects on responses.',
            onTap: () => setMode(false),
          ),
          _seg(
            emoji: '🎲',
            label: 'Chaos',
            selected: chaos,
            color: Palette.post,
            title: 'Chaos mode',
            tooltip: chaos
                ? 'On: each response plays a sound for its status. Click again '
                      'to choose the sounds.'
                : 'Each response plays a meme sound for its status, with '
                      'confetti on success and a shake on errors.',
            example: '404 plays its own clip',
            onTap: () => setMode(true),
          ),
        ],
      ),
    );
  }

  Widget _seg({
    required String emoji,
    required String label,
    required bool selected,
    required Color color,
    required String title,
    required String tooltip,
    String? example,
    required VoidCallback onTap,
  }) {
    return HelpHover(
      tooltip,
      title: title,
      example: example,
      essential: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 7 : 9,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 12.5)),
              if (!compact && selected) ...[
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
