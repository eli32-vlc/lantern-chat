import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'chat.dart';
import 'onboarding.dart';
import 'settings.dart';
import 'tabs.dart';
import 'theme.dart';

class HomeShell extends StatefulWidget {
  final AppState state;
  const HomeShell({super.key, required this.state});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  bool get _cupertino => L.cupertino(context);

  void _openChat(String peerId, String name) {
    // Push on the root navigator: works from any tab on both platforms,
    // and the chat page is never trapped inside a tab scaffold body.
    Navigator.of(context, rootNavigator: true).push(
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
        if (_cupertino) return _ios(context);
        return _android(context);
      },
    );
  }

  // ---- iOS: one CupertinoTabScaffold, each tab owns its CupertinoTabView ----
  Widget _ios(BuildContext context) {
    final trust = widget.state.trustRequest;
    return Stack(
      children: [
        CupertinoTabScaffold(
          tabBar: CupertinoTabBar(
            currentIndex: _tab,
            onTap: (i) => setState(() => _tab = i),
            items: const [
              BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.chat_bubble_2), label: 'Chats'),
              BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.person_2), label: 'Peers'),
              BottomNavigationBarItem(
                  icon: Icon(CupertinoIcons.settings), label: 'Settings'),
            ],
          ),
          tabBuilder: (context, i) {
            final title = switch (i) {
              0 => 'Chats',
              1 => 'Peers',
              _ => 'Settings'
            };
            Widget tabBody;
            switch (i) {
              case 0:
                tabBody = ChatsTab(state: widget.state, onOpen: _openChat);
              case 1:
                tabBody = PeersTab(state: widget.state, onOpen: _openChat);
              default:
                tabBody = SettingsTab(state: widget.state);
            }
            return CupertinoTabView(
              builder: (context) => CupertinoPageScaffold(
                navigationBar: CupertinoNavigationBar(middle: Text(title)),
                child: SafeArea(child: tabBody),
              ),
            );
          },
        ),
        if (trust != null) _trustBanner(context, trust),
      ],
    );
  }

  // ---- Android: Material 3 NavigationBar, no dead scaffolds ----
  Widget _android(BuildContext context) {
    final trust = widget.state.trustRequest;
    final title = switch (_tab) {
      0 => 'Chats',
      1 => 'Peers',
      _ => 'Settings'
    };
    final body = switch (_tab) {
      0 => ChatsTab(state: widget.state, onOpen: _openChat),
      1 => PeersTab(state: widget.state, onOpen: _openChat),
      _ => SettingsTab(state: widget.state),
    };
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: Text(title,
                style: const TextStyle(
                    fontSize: L.title, fontWeight: FontWeight.w600)),
            centerTitle: false,
          ),
          body: SafeArea(child: body),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.forum_outlined),
                  selectedIcon: Icon(Icons.forum),
                  label: 'Chats'),
              NavigationDestination(
                  icon: Icon(Icons.people_outline),
                  selectedIcon: Icon(Icons.people),
                  label: 'Peers'),
              NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings'),
            ],
          ),
        ),
        if (trust != null) _trustBanner(context, trust),
      ],
    );
  }

  Widget _trustBanner(BuildContext context, trust) {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 92,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(L.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.shield_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${trust.name} found. Verify?',
                    style: const TextStyle(fontSize: L.body),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: widget.state.dismissTrust,
                child: const Text('Later',
                    style: TextStyle(fontSize: L.body)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                      fontSize: L.body, fontWeight: FontWeight.w600),
                ),
                onPressed: () {
                  widget.state.dismissTrust();
                  showModalBottomSheet(
                    context: context,
                    useRootNavigator: true,
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
    );
  }
}
