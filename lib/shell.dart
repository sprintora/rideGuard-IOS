import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'admin.dart';
import 'auth.dart';
import 'app_models.dart';
import 'driver.dart';
import 'parent.dart';
import 'firestore_repository.dart';
import 'widgets.dart';
import 'ui_components.dart';
import 'pilot_features.dart';
import 'connectivity_banner.dart';

class NavItem {
  const NavItem(this.label, this.icon, this.builder, {this.footer = false});
  final String label;
  final IconData icon;
  final Widget Function(BuildContext) builder;
  final bool footer;
}

List<NavItem> itemsFor(Role r) {
  switch (r) {
    case Role.admin:
      return [
        NavItem('Dashboard', Icons.dashboard_outlined,
            (_) => const AdminDashboard(),
            footer: true),
        NavItem('Schools', Icons.school_outlined, (_) => const SchoolsPage()),
        NavItem(
            'Buses', Icons.directions_bus_outlined, (_) => const BusesPage()),
        NavItem('Devices', Icons.memory, (_) => const DevicesPage()),
        NavItem('Routes', Icons.alt_route, (_) => const RoutesPage()),
        NavItem('Drivers', Icons.badge_outlined, (_) => const DriversPage()),
        NavItem('Parents', Icons.family_restroom, (_) => const ParentsPage()),
        NavItem('Students', Icons.child_care, (_) => const StudentsPage()),
        NavItem('Cards', Icons.credit_card, (_) => const CardsPage()),
        if (PilotFeatures.enableAnalytics)
          NavItem('Reports', Icons.bar_chart, (_) => const ReportsPage(),
              footer: true),
        if (PilotFeatures.enableAuditLogs)
          NavItem(
              'Audit log', Icons.fact_check_outlined, (_) => const AuditPage()),
        NavItem('Profile', Icons.person_outline,
            (_) => const ProfilePage(role: Role.admin),
            footer: true),
      ];
    case Role.driver:
      return [
        NavItem('List', Icons.list_alt, (_) => const DriverList(),
            footer: true),
        NavItem('Home', Icons.home_outlined, (_) => const DriverHome(),
            footer: true),
        NavItem('Profile', Icons.person_outline,
            (_) => const ProfilePage(role: Role.driver),
            footer: true),
      ];
    case Role.parent:
      return [
        NavItem('Home', Icons.home_outlined, (_) => const ParentHome(),
            footer: true),
        if (PilotFeatures.enableParentCalendar)
          NavItem('Calendar', Icons.calendar_month_outlined,
              (_) => const CalendarPage(),
              footer: true),
        NavItem('Notification settings', Icons.notifications_active_outlined,
            (_) => const NotifSettingsPage()),
        NavItem('Profile', Icons.person_outline,
            (_) => const ProfilePage(role: Role.parent),
            footer: true),
      ];
  }
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.role});
  final Role role;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final List<NavItem> items = itemsFor(widget.role);
  late int index = widget.role == Role.driver ? 1 : 0;

  void _openBell() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _NotificationsSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = FirebaseAuth.instance.currentUser;
    final displayName = user?.displayName?.trim().isNotEmpty == true
        ? user!.displayName!.trim()
        : user?.email ?? 'Signed-in user';
    final footer = [
      for (var i = 0; i < items.length; i++)
        if (items[i].footer) i
    ];
    final fi = footer.indexOf(index);
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppHeader(
        title: roleName(widget.role),
        onMenu: () => _scaffoldKey.currentState?.openDrawer(),
        actions: [
          Builder(
            builder: (context) {
              final notifications = ref.watch(notificationsProvider);
              final uid = FirebaseAuth.instance.currentUser?.uid;
              final count = notifications.value?.where((notification) {
                    return isNotificationUnread(notification, uid);
                  }).length ??
                  0;
              return Stack(
                alignment: Alignment.topRight,
                children: [
                  CircleIconButton(
                    tooltip: 'Notifications',
                    onPressed: _openBell,
                    icon: Icons.notifications_outlined,
                  ),
                  if (count > 0)
                    IgnorePointer(
                      child: Container(
                        constraints:
                            const BoxConstraints(minWidth: 18, minHeight: 18),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: scheme.error,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: scheme.surface, width: 2),
                        ),
                        child: Text(
                          count > 99 ? '99+' : '$count',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: scheme.onError,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: scheme.primaryContainer,
              child: Text(roleName(widget.role).substring(0, 1),
                  style: TextStyle(
                      color: scheme.primary, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(children: [
            Container(
              width: double.infinity,
              color: scheme.primaryContainer,
              padding: const EdgeInsets.all(20),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const RideGuardLogo(size: 30),
                    const SizedBox(height: 16),
                    Text(displayName,
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: scheme.onPrimaryContainer)),
                    Text(roleName(widget.role),
                        style: TextStyle(color: scheme.onPrimaryContainer)),
                  ]),
            ),
            Expanded(
              child: ListView(children: [
                for (var i = 0; i < items.length; i++)
                  ListTile(
                    leading: Icon(items[i].icon),
                    title: Text(items[i].label),
                    selected: i == index,
                    onTap: () {
                      Navigator.of(context).pop();
                      setState(() => index = i);
                    },
                  ),
              ]),
            ),
            const Divider(height: 1),
            ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Log out'),
                onTap: () => logout(context)),
          ]),
        ),
      ),
      body: RideGuardConnectivityBanner(
        child: KeyedSubtree(
            key: ValueKey(index), child: items[index].builder(context)),
      ),
      bottomNavigationBar: SafeArea(
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFE4E6EA)),
              ),
              child: NavigationBar(
                selectedIndex: fi < 0 ? 0 : fi,
                onDestinationSelected: (i) => setState(() => index = footer[i]),
                destinations: [
                  for (final i in footer)
                    NavigationDestination(
                        icon: Icon(items[i].icon), label: items[i].label),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationsSheet extends ConsumerStatefulWidget {
  const _NotificationsSheet();

  @override
  ConsumerState<_NotificationsSheet> createState() =>
      _NotificationsSheetState();
}

class _NotificationsSheetState extends ConsumerState<_NotificationsSheet> {
  static const _pageSize = 10;
  final List<DocumentSnapshot<Map<String, dynamic>>?> _cursors = [null];
  int _page = 0;

  Query<Map<String, dynamic>> _query() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    var query = FirebaseFirestore.instance
        .collection('notifications')
        .where('parentId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(_pageSize);
    final cursor = _cursors[_page];
    if (cursor != null) query = query.startAfterDocument(cursor);
    return query;
  }

  Future<void> _markAll() async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('markAllNotificationsRead')
          .call();
      ref.invalidate(notificationsProvider);
    } catch (error) {
      if (mounted) {
        snackError(context, error, prefix: 'Unable to mark notifications');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _query().snapshots(),
          builder: (context, snapshot) {
            final docs = snapshot.data?.docs ?? const [];
            return ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Notifications',
                            style: Theme.of(context).textTheme.titleLarge),
                      ),
                    ],
                  ),
                ),
                if (snapshot.hasError)
                  const ListTile(title: Text('Unable to load notifications.')),
                for (final document in docs)
                  _NotificationTile(
                    document: document,
                    uid: uid,
                    onChanged: () => ref.invalidate(notificationsProvider),
                  ),
                if (docs.isEmpty && !snapshot.hasError)
                  const ListTile(title: Text('No notifications.')),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: docs.isEmpty ? null : _markAll,
                        child: const Text('Read all'),
                      ),
                      const Spacer(),
                      Text('Page ${_page + 1}'),
                      Row(children: [
                        TextButton(
                          onPressed:
                              _page == 0 ? null : () => setState(() => _page--),
                          child: const Text('Previous'),
                        ),
                        TextButton(
                          onPressed: docs.length < _pageSize
                              ? null
                              : () => setState(() {
                                    _cursors.add(docs.last);
                                    _page++;
                                  }),
                          child: const Text('Next'),
                        ),
                      ]),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.document,
    required this.uid,
    required this.onChanged,
  });

  final DocumentSnapshot<Map<String, dynamic>> document;
  final String uid;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final notification = FirestoreRecord(document.id, document.data()!);
    final isRead = !isNotificationUnread(notification, uid);
    return ListTile(
      leading: Icon(isRead ? Icons.circle_outlined : Icons.circle, size: 12),
      title: Text(notification.text('title', 'Notification')),
      subtitle: Text(notification.text('body', notification.text('message'))),
      trailing: isRead
          ? const Text('Read')
          : TextButton(
              onPressed: () async {
                try {
                  await FirebaseFunctions.instance
                      .httpsCallable('markNotificationRead')
                      .call({'notificationId': document.id});
                  onChanged();
                } catch (error) {
                  if (context.mounted) {
                    snackError(context, error,
                        prefix: 'Unable to mark notification');
                  }
                }
              },
              child: const Text('Mark as read'),
            ),
    );
  }
}
