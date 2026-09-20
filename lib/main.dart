import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  runApp(LanternApp(state: state));
  try {
    await state.init();
  } catch (e) {
    debugPrint('init failed: $e');
  }
}

class LanternApp extends StatelessWidget {
  final AppState state;
  const LanternApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => MaterialApp(
        title: 'Lantern',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal, brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: HomeShell(state: state),
      ),
    );
  }
}
