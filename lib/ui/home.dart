import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/protocol.dart';
import 'chat.dart';
import 'group_chat.dart';
import 'l10n.dart';
import 'onboarding.dart';
import 'people.dart';
import 'me.dart';
import 'ptt.dart';
import 'theme.dart';

class HomeShell extends StatefulWidget {
  final AppState state;
  const HomeShell({super.key, required this.state});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  void _openChat(String id, String name, {bool group = false}) {
    final page = group
        ? GroupChatPage(state: widget.state, groupId: id, groupName: name)
        : ChatPage(state: widget.state, peerId: id, peerName: name);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        if (!widget.state.onboarded) {
          return OnboardingPage(state: widget.state);
        }
        return Scaffold(
          body: IndexedStack(
            index: _tab,
            children: [
              ChatsTab(state: widget.state, onOpen: _openChat),
              PeopleTab(state: widget.state, onOpen: _openChat),
              PttScreen(state: widget.state),
              MeTab(state: widget.state),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: S.of(context).chats,
              ),
              NavigationDestination(
                icon: Icon(Icons.people_outline),
                selectedIcon: Icon(Icons.people),
                label: S.of(context).people,
              ),
              NavigationDestination(
                icon: Icon(Icons.radio),
                selectedIcon: Icon(Icons.radio),
                label: S.of(context).ptt,
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: S.of(context).me,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Chats tab — all conversations in one list.
class ChatsTab extends StatelessWidget {
  final AppState state;
  final void Function(String id, String name, {bool group}) onOpen;
  const ChatsTab({super.key, required this.state, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final chats = state.chats;
    return Scaffold(
      appBar: AppBar(title: Text(S.of(context).chats)),
      body: chats.isEmpty
          ? Center(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey),
                SizedBox(height: 12),
                Text(S.of(context).noChats, style: TextStyle(color: Colors.grey)),
                SizedBox(height: 4),
                Text(S.of(context).goToPeople, style: TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ))
          : RefreshIndicator(
              onRefresh: () async { await state.refreshChats(); },
              child: ListView.separated(
                itemCount: chats.length,
                separatorBuilder: (_, __) => Divider(height: 1, indent: 72),
                itemBuilder: (context, i) {
                  final c = chats[i];
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(c.name.isNotEmpty ? c.name[0].toUpperCase() : '?'),
                    ),
                    title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(c.lastText ?? S.of(context).sayHello,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: c.unread > 0
                        ? Container(
                            padding: EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('${c.unread}', style: TextStyle(color: Colors.white, fontSize: 12)),
                          )
                        : null,
                    onTap: () => onOpen(c.id, c.name, group: c.isGroup),
                  );
                },
              ),
            ),
    );
  }
}
