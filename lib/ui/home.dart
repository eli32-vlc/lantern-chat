import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'adaptive.dart';
import 'chat.dart';
import 'onboarding.dart';
import 'settings.dart';
import 'tabs.dart';

class HomeShell extends StatefulWidget {
  final AppState state;
  const HomeShell({super.key, required this.state});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  bool get _cupertino =>
      Theme.of(context).platform == TargetPlatform.iOS ||
      Theme.of(context).platform == TargetPlatform.macOS;

  void _openChat(String peerId, String name) {
    Navigator.of(context).push(
      _cupertino
          ? CupertinoPageRoute(
              builder: (_) => ChatPage(
                  state: widget.state, peerId: peerId, peerName: name))
          : MaterialPageRoute(
              builder: (_) => ChatPage(
                  state: widget.state, peerId: peerId, peerName: name)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        if (!widget.state.onboarded) {
          return OnboardingPage(state: widget.state);
        }
        final trust = widget.state.trustRequest;
        final body = switch (_tab) {
          0 => ChatsTab(state: widget.state, onOpen: _openChat),
          1 => PeersTab(state: widget.state, onOpen: _openChat),
          _ => SettingsTab(state: widget.state),
        };
        final title = switch (_tab) { 0 => 'Chats', 1 => 'Peers', _ => 'Settings' };

        Widget shell;
        if (_cupertino) {
          shell = CupertinoTabScaffold(
            tabBar: CupertinoTabBar(items: const [
              BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.chat_bubble_2), label: 'Chats'),
              BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.person_2), label: 'Peers'),
              BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.settings), label: 'Settings'),
            ], currentIndex: _tab, onTap: (i) => setState(() => _tab = i)),
            tabBuilder: (_, i) => CupertinoTabView(
              builder: (_) => CupertinoPageScaffold(
                navigationBar: CupertinoNavigationBar(middle: Text(title)),
                child: SafeArea(child: body),
              ),
            ),
          );
        } else {
          shell = LanternScaffold(
            title: 'Lantern — $title',
            body: body,
            floatingActionButton: _tab == 1
                ? FloatingActionButton(
                    onPressed: () => setState(() {}),
                    tooltip: 'Refresh',
                    child: const Icon(Icons.refresh),
                  )
                : null,
          );
          shell = Scaffold(
            appBar: AppBar(title: Text('Lantern — $title')),
            body: SafeArea(child: body),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: const [
                NavigationDestination(
                    icon: Icon(Icons.forum_outlined), label: 'Chats'),
                NavigationDestination(
                    icon: Icon(Icons.people_outline), label: 'Peers'),
                NavigationDestination(
                    icon: Icon(Icons.settings_outlined), label: 'Settings'),
              ],
            ),
            floatingActionButton: _tab == 1
                ? FloatingActionButton(
                    onPressed: () => setState(() {}),
                    tooltip: 'Refresh',
                    child: const Icon(Icons.refresh),
                  )
                : null,
          );
        }

        // Incoming trust request banner
        if (trust != null) {
          return Stack(
            children: [
              shell,
              Positioned(
                left: 12,
                right: 12,
                bottom: 90,
                child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(Icons.shield_outlined),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                '${trust.name} wants to connect. Verify safety code?')),
                        TextButton(
                            onPressed: widget.state.dismissTrust,
                            child: const Text('Later')),
                        FilledButton(
                          onPressed: () {
                            widget.state.dismissTrust();
                            showModalBottomSheet(
                              context: context,
                              showDragHandle: true,
                              builder: (_) =>
                                  TrustSheet(peer: trust, state: widget.state),
                            );
                          },
                          child: const Text('Verify'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return shell;
      },
    );
  }
}
