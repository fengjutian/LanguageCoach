import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which bottom-navigation destination is visible. Lifted out of
/// `HomePage`'s local `setState` so any tab (History, Practice, …) can ask
/// Home to reveal Chat without holding a reference to the widget.
final homeTabProvider = StateProvider<HomeTab>((_) => HomeTab.chat);

enum HomeTab { chat, practice, history, settings }

/// Ask Home to show the Chat tab. Used after "resume this conversation" from
/// the history page — without it the user had to find the tab by hand, and
/// the resume did not even load before.
void showChatTab(WidgetRef ref) {
  ref.read(homeTabProvider.notifier).state = HomeTab.chat;
}

/// Index into the NavigationBar destinations. The enum order and the
/// destination order must stay in lockstep.
int homeTabIndex(HomeTab tab) => HomeTab.values.indexOf(tab);
