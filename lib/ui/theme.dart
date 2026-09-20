import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Single source of truth for sizing + colors that work in both
/// Material and Cupertino contexts, light and dark.
class L {
  static const double title = 17;
  static const double body = 15;
  static const double small = 13;
  static const double tiny = 11;

  static const double pad = 16;
  static const double gap = 12;
  static const double radius = 12;

  static const double iconLg = 44;
  static const double bubbleMax = 0.75;

  /// Muted text that stays readable in dark mode.
  static Color muted(BuildContext c) =>
      Theme.of(c).colorScheme.onSurfaceVariant;

  /// Chat bubble backgrounds.
  static Color bubbleMe(BuildContext c) =>
      Theme.of(c).colorScheme.primaryContainer;
  static Color bubblePeer(BuildContext c) =>
      Theme.of(c).colorScheme.surfaceContainerHighest;

  static bool cupertino(BuildContext c) {
    final p = Theme.of(c).platform;
    return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
  }
}

/// Compact filled button, same metrics on both platforms.
class LButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  const LButton(
      {super.key, required this.label, this.onPressed, this.primary = true});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: L.body, fontWeight: FontWeight.w600);
    if (L.cupertino(context)) {
      return SizedBox(
        width: double.infinity,
        child: primary
            ? CupertinoButton.filled(
                padding: const EdgeInsets.symmetric(vertical: 12),
                onPressed: onPressed,
                child: Text(label, style: style),
              )
            : CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 12),
                onPressed: onPressed,
                child: Text(label, style: style),
              ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: primary
          ? FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                textStyle: style,
              ),
              onPressed: onPressed,
              child: Text(label),
            )
          : OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                textStyle: style,
              ),
              onPressed: onPressed,
              child: Text(label),
            ),
    );
  }
}

/// Small muted helper line. Always explicit color (no inherited grey that
/// vanishes in dark mode), never underlined.
class LMute extends StatelessWidget {
  final String text;
  final TextAlign align;
  const LMute(this.text, {super.key, this.align = TextAlign.center});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: align,
      style: TextStyle(fontSize: L.small, color: L.muted(context)),
    );
  }
}

/// Empty-state block: icon + title + one line. No paragraphs.
class LEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String hint;
  const LEmpty(
      {super.key, required this.icon, required this.title, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: L.iconLg,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: L.gap),
            Text(title,
                style: const TextStyle(
                    fontSize: L.title, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            LMute(hint),
          ],
        ),
      ),
    );
  }
}
