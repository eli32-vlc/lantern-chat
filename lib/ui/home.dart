import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'chat.dart';
import 'compat_chat.dart';
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
    // Compat (plaintext) chats open the compat page; E2EE peers open ChatPage.
    // Push on the tab's own navigator (NOT rootNavigator): each
    // CupertinoTabView owns a navigator, and rootNavigator pushes from
    // inside a tab break the tab scaffold on iOS 16 (white screen).
    final compat = AppState.isCompatChat(peerId);
    final page = compat
        ? CompatChatStoreScope(
            state: widget.state,
            child: CompatChatPage(chatId: peerId, title: name),
          )
        : ChatPage(state: widget.state, peerId: peerId, peerName: name);
    Navigator.of(context).push(
      _cupertino
          ? CupertinoPageRoute(builder: (_) => page)
          : MaterialPageRoute(builder: (_) => page),
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

  // ---- iOS: one CupertinoTabScaffold, each tab owns its CupertinoTabView.
  // Every tab body is wrapped in Material(type: transparency) so Material
  // widgets (ListTile, RefreshIndicator, Dismissible, sheets) always have
  // a Material ancestor — without it iOS 16 renders text with yellow
  // underlines and ink effects white-screen. ----
  Widget _ios(BuildContext context) {
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
                backgroundColor: CupertinoColors.systemGroupedBackground,
                navigationBar:
                    CupertinoNavigationBar(middle: Text(title)),
                // Material ancestor kills the iOS-16 yellow-underline text
                // and gives RefreshIndicator/Dismissible a canvas.
                child: Material(
                  type: MaterialType.transparency,
                  child: SafeArea(child: tabBody),
                ),
              ),
            );
          },
        ),
        if (widget.state.trustRequest != null)
          _trustBanner(context, widget.state.trustRequest!),
      ],
    );
  }

  // ---- Android: Material 3 NavigationBar ----
  Widget _android(BuildContext context) {
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
        if (widget.state.trustRequest != null)
          _trustBanner(context, widget.state.trustRequest!),
      ],
    );
  }

  Widget _trustBanner(BuildContext context, trust) {
    // Material ancestor is provided by the _android Scaffold; on iOS the
    // banner sits above the CupertinoTabScaffold so wrap it explicitly.
    final card = Material(
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
                  style: const TextStyle(
                      fontSize: L.body, decoration: TextDecoration.none),
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
              child: L.txt('Later', size: L.body),
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
                showCupertinoOrMaterialSheet(
                    context, TrustSheet(peer: trust, state: widget.state));
              },
              child: L.txt('Verify', size: L.body, weight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
    return Positioned(left: 12, right: 12, bottom: 92, child: card);
  }
}
