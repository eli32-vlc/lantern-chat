import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Adaptive scaffold: Cupertino on iOS/macOS, Material elsewhere,
/// but a single shared structure so behavior is identical.
class LanternScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final Widget? floatingActionButton;

  const LanternScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.floatingActionButton,
  });

  bool _cupertino(BuildContext c) =>
      Theme.of(c).platform == TargetPlatform.iOS ||
      Theme.of(c).platform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    if (_cupertino(context)) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(title),
          trailing: actions == null
              ? null
              : Row(mainAxisSize: MainAxisSize.min, children: actions!),
        ),
        child: SafeArea(child: body),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: SafeArea(child: body),
      floatingActionButton: floatingActionButton,
    );
  }
}

class AdaptiveButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  const AdaptiveButton({
    super.key,
    required this.label,
    this.onPressed,
    this.filled = true,
  });

  @override
  Widget build(BuildContext context) {
    final cupertino = Theme.of(context).platform == TargetPlatform.iOS ||
        Theme.of(context).platform == TargetPlatform.macOS;
    if (cupertino) {
      return SizedBox(
        width: double.infinity,
        child: filled
            ? CupertinoButton.filled(
                onPressed: onPressed, child: Text(label))
            : CupertinoButton(onPressed: onPressed, child: Text(label)),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: filled
          ? FilledButton(onPressed: onPressed, child: Text(label))
          : OutlinedButton(onPressed: onPressed, child: Text(label)),
    );
  }
}
