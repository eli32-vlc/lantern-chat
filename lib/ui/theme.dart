import 'package:flutter/material.dart';

// Simple theme helpers
class L {
  static const double body = 15;
  static const double title = 17;
  static const double small = 13;
  static const double tiny = 11;
  static const double pad = 16;
  static const double radius = 12;

  static Widget txt(String text, {double size = body, FontWeight weight = FontWeight.normal, Color? color, TextAlign? align, int? maxLines, TextOverflow? overflow}) {
    return Text(text, style: TextStyle(fontSize: size, fontWeight: weight, color: color, decoration: TextDecoration.none), textAlign: align, maxLines: maxLines, overflow: overflow);
  }

  static Widget muteTxt(BuildContext context, String text, {int? maxLines, TextOverflow? overflow, TextAlign? align}) {
    return Text(text, style: TextStyle(fontSize: small, color: Colors.grey), maxLines: maxLines, overflow: overflow, textAlign: align);
  }

  static Widget mute(String text, {TextAlign? align}) {
    return Text(text, style: TextStyle(fontSize: small, color: Colors.grey), textAlign: align);
  }

  static Color muted(BuildContext context) => Colors.grey;

  static bool cupertino(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.iOS ||
      Theme.of(context).platform == TargetPlatform.macOS;
}

class LEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? hint;
  const LEmpty({super.key, required this.icon, required this.title, this.hint});

  @override
  Widget build(BuildContext context) {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 48, color: Colors.grey),
      SizedBox(height: 12),
      Text(title, style: TextStyle(fontSize: 16, color: Colors.grey)),
      if (hint != null) ...[
        SizedBox(height: 4),
        Text(hint!, style: TextStyle(fontSize: 13, color: Colors.grey)),
      ],
    ]));
  }
}

class LButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const LButton({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(padding: EdgeInsets.symmetric(vertical: 14)),
      child: Text(label, style: TextStyle(fontSize: 16)),
    );
  }
}

void showCupertinoOrMaterialSheet(BuildContext context, Widget child) {
  showModalBottomSheet(context: context, builder: (_) => child);
}
