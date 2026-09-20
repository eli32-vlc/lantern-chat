import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Single source of truth for sizing + colors that work in both
/// Material and Cupertino contexts, light and dark.
///
/// iOS-16 underline rule: inside a CupertinoPageScaffold WITHOUT a Material
/// ancestor, Text falls back to a default style WITH yellow underlines.
/// Every text widget in this file sets `decoration: TextDecoration.none`
/// explicitly, and tab bodies are wrapped in Material (see home.dart).
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

  /// Plain body text: explicit color + no underline. Use everywhere instead
  /// of a bare Text() so iOS 16 never shows yellow underlines.
  static Text txt(String s,
      {double size = body,
      FontWeight weight = FontWeight.normal,
      Color? color,
      TextAlign? align,
      int? maxLines,
      TextOverflow? overflow}) {
    return Text(s,
        textAlign: align,
        maxLines: maxLines,
        overflow: overflow,
        style: TextStyle(
            fontSize: size,
            fontWeight: weight,
            color: color,
            decoration: TextDecoration.none));
  }

  /// Muted text that stays readable in dark mode.
  static Color muted(BuildContext c) =>
      Theme.of(c).colorScheme.onSurfaceVariant;

  static Text muteTxt(BuildContext c, String s,
      {double size = small,
      TextAlign? align,
      int? maxLines,
      TextOverflow? overflow}) {
    return Text(s,
        textAlign: align,
        maxLines: maxLines,
        overflow: overflow,
        style: TextStyle(
            fontSize: size,
            color: muted(c),
            decoration: TextDecoration.none));
  }

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
    final style = const TextStyle(
        fontSize: L.body,
        fontWeight: FontWeight.w600,
        decoration: TextDecoration.none);
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

/// Small muted helper line. Always explicit color, never underlined.
class LMute extends StatelessWidget {
  final String text;
  final TextAlign align;
  const LMute(this.text, {super.key, this.align = TextAlign.center});

  @override
  Widget build(BuildContext context) {
    return L.muteTxt(context, text, align: align);
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
            Icon(icon,
                size: L.iconLg,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: L.gap),
            L.txt(title, size: L.title, weight: FontWeight.w600),
            const SizedBox(height: 4),
            LMute(hint),
          ],
        ),
      ),
    );
  }
}

/// Show a sheet correctly on both platforms: CupertinoActionSheet-style
/// modal on iOS (inside the tab's navigator), Material sheet on Android.
/// Using the wrong one inside CupertinoTabView causes white screens.
Future<T?> showCupertinoOrMaterialSheet<T>(
    BuildContext context, Widget child) {
  if (L.cupertino(context)) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: (_) => Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: CupertinoColors.systemBackground.resolveFrom(context),
              borderRadius: BorderRadius.circular(L.radius),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (_) => child,
  );
}
