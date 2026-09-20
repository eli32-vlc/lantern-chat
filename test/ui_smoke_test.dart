import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lantern_chat/core/app_state.dart';
import 'package:lantern_chat/ui/home.dart';

/// Boots the real HomeShell with a fresh AppState and asserts the first
/// frame renders without exceptions. Catches scaffold/navigator regressions
/// (e.g. the iOS blank-screen class of bug) at CI time.
void main() {
  testWidgets('HomeShell first frame renders', (tester) async {
    final state = AppState();
    await tester.pumpWidget(MaterialApp(home: HomeShell(state: state)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Onboarding shows when no profile exists.
    expect(find.text('Lantern'), findsWidgets);
    state.dispose();
  });
}
