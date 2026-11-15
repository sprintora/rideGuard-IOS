import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'firestore_repository.dart';
import 'route_repository.dart';
import 'forms.dart';
import 'cache_service.dart';
import 'widgets.dart';
import 'location_models.dart';
import 'ride_reader_service.dart';
import 'permission_service.dart';
import 'auth_repository.dart';
import 'core/input_rules.dart';

class RowData {
  const RowData(this.title, this.subtitle,
      {this.chip,
      this.chipColor,
      this.icon = Icons.circle_outlined,
      this.actions = const [],
      this.onTap});
  final String title, subtitle;
  final String? chip;
  final Color? chipColor;
  final IconData icon;
  final List<String> actions;
  final void Function(BuildContext)? onTap;
}

class _RecordEditDialog extends StatefulWidget {
  const _RecordEditDialog({
    required this.title,
    required this.name,
    required this.address,
    required this.phone,
    required this.includeContactFields,
  });
  final String title;
  final String name;
  final String address;
  final String phone;
  final bool includeContactFields;

  @override
  State<_RecordEditDialog> createState() => _RecordEditDialogState();
}

class _RecordEditDialogState extends State<_RecordEditDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.name);
  late final TextEditingController _address =
      TextEditingController(text: widget.address);
  late final TextEditingController _phone =
      TextEditingController(text: widget.phone);

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name')),
          if (widget.includeContactFields) ...[
            TextField(
                controller: _address,
                decoration: const InputDecoration(labelText: 'Address')),
            TextField(
                controller: _phone,
                decoration: const InputDecoration(labelText: 'Contact phone')),
          ],
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'name': _name.text,
              'address': _address.text,
              'contactPhone': _phone.text,
            }),
            child: const Text('Save'),
          ),
        ],
      );
}

String _firstRecordValue(FirestoreRecord record, List<String> keys,
    [String fallback = '']) {
  for (final key in keys) {
    final value = record.data[key]?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  return fallback;
}

class ListPage extends ConsumerWidget {
  const ListPage(
      {super.key,
      required this.title,
      required this.rows,
      this.collection,
      this.addLabel,
      this.onAdd});
  final String title;
  final List<RowData> rows;
  final String? collection;
  final String? addLabel;
  final void Function(BuildContext)? onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records =
        collection == null ? null : ref.watch(collectionProvider(collection!));
    final displayRows = records == null
        ? rows
        : records.when(
            loading: () => const <RowData>[],
            error: (error, _) => [
              RowData('Unable to load records', friendlyErrorMessage(error),
                  icon: Icons.error),
            ],
            data: (items) => [
              for (final item in items)
                RowData(
                  _firstRecordValue(
                      item,
                      [
                        'fullName',
                        'name',
                        'schoolName',
                        'School name',
                        'displayName',
                        'plate',
                        'deviceId',
                      ],
                      recordName(collection!, item)),
                  collection == 'devices'
                      ? 'Bus ${item.data['busPlate']?.toString().trim().isNotEmpty == true ? item.data['busPlate'] : 'not assigned'}'
                      : _firstRecordValue(item, [
                          'description',
                          'address',
                          'phone',
                          'contactPhone',
                          'status',
                        ]),
                  icon: _iconFor(collection!),
                  actions: const ['Edit', 'Delete'],
                  onTap: (_) => _showRecord(context, collection!, item),
                ),
            ],
          );
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: addLabel == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => onAdd!(context),
              icon: const Icon(Icons.add),
              label: Text(addLabel!)),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 96),
        itemCount: displayRows.length + 1,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          if (i == 0)
            return Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child:
                    Text(title, style: Theme.of(ctx).textTheme.headlineSmall));
          if (displayRows.isEmpty) {
            return const ListTile(
              leading: Icon(Icons.inbox_outlined),
              title: Text('No records yet'),
            );
          }
          final r = displayRows[i - 1];
          final record =
              records?.valueOrNull != null && i - 1 < records!.value!.length
                  ? records.value![i - 1]
                  : null;
          return ListTile(
            leading: CircleAvatar(child: Icon(r.icon)),
            title: Text(r.title),
            subtitle: Text(r.subtitle),
            onTap: r.onTap == null
                ? null
                : () {
                    if (collection == 'drivers' && record != null) {
                      _showDriverDetails(ctx, record);
                    } else {
                      r.onTap!(ctx);
                    }
                  },
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (r.chip != null)
                Chip2(r.chip!, r.chipColor ?? Colors.blueGrey),
              if (r.actions.isNotEmpty)
                PopupMenuButton<String>(
                  itemBuilder: (context) => [
                    for (final action in r.actions)
                      PopupMenuItem(
                        value: action,
                        child: Text(
                          action,
                          style: action == 'Delete'
                              ? TextStyle(
                                  color: Theme.of(context).colorScheme.error)
                              : null,
                        ),
                      ),
                  ],
                  onSelected: (a) async {
                    if (record == null) {
                      snack(ctx, '$a: ${r.title}');
                    } else if (a == 'Delete') {
                      final confirmed = await confirmAction(
                        ctx,
                        title: 'Delete ${r.title}?',
                        message: 'This record will be disabled and hidden.',
                      );
                      if (!confirmed) return;
                      try {
                        await FirestoreRepository(FirebaseFirestore.instance)
                            .delete(
                                collection == 'drivers' ? 'users' : collection!,
                                record.id);
                        if (ctx.mounted) snack(ctx, 'Deleted ${r.title}');
                      } catch (error) {
                        if (ctx.mounted)
                          snackError(ctx, error, prefix: 'Delete failed');
                      }
                    } else if (a == 'Edit') {
                      if (collection == 'schools') {
                        await showDialog<void>(
                          context: ctx,
                          builder: (_) => _SchoolDialog(record: record),
                        );
                      } else if (collection == 'drivers') {
                        await showDialog<void>(
                          context: ctx,
                          builder: (_) => _DriverDialog(record: record),
                        );
                      } else if (collection == 'parents') {
                        await showDialog<void>(
                          context: ctx,
                          builder: (_) => _ParentDialog(record: record),
                        );
                      } else {
                        await _editRecord(ctx, collection!, record);
                      }
                    }
                  },
                ),
            ]),
          );
        },
      ),
    );
  }

  Future<void> _editRecord(
      BuildContext context, String collection, FirestoreRecord record) async {
    if (collection == 'students') {
      final values = await Navigator.of(context).push<Map<String, dynamic>>(
        MaterialPageRoute(builder: (_) => _StudentEditPage(record: record)),
      );
      if (values == null ||
          !await confirmAction(context,
              title: 'Save student changes?',
              message: 'A replaced card will be permanently disabled.')) {
        return;
      }
      try {
        final firestore = FirebaseFirestore.instance;
        final oldUid = record.data['cardUid']?.toString();
        final newUid = values['cardUid']?.toString();
        await firestore.runTransaction((transaction) async {
          transaction.update(firestore.collection('students').doc(record.id), {
            'name': values['name'],
            'grade': values['grade'],
            'status': values['status'],
            if (newUid != null) 'cardUid': newUid,
            if (values['cardNumber'] != null)
              'cardNumber': values['cardNumber'],
            ..._pointUpdate('pickup', values['pickup']),
            ..._pointUpdate('drop', values['drop']),
            if (values['routeChanged'] == true && values['routeId'] != null)
              'routeId': values['routeId'],
            if (values['busChanged'] == true && values['busId'] != null)
              'busId': values['busId'],
            if (values['routeChanged'] == true)
              'schoolId': values['schoolId'] ?? FieldValue.delete()
            else if (values['schoolId'] != null)
              'schoolId': values['schoolId'],
            'updatedAt': FieldValue.serverTimestamp(),
          });
          // The card follows the student's bus (drivers load cards by bus).
          final activeCard =
              (newUid != null && newUid.isNotEmpty) ? newUid : oldUid;
          if (values['busChanged'] == true &&
              values['busId'] != null &&
              activeCard != null &&
              activeCard.isNotEmpty) {
            transaction.update(firestore.collection('cards').doc(activeCard), {
              'busId': values['busId'],
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
          if (oldUid != null && oldUid.isNotEmpty && oldUid != newUid) {
            transaction.update(firestore.collection('cards').doc(oldUid), {
              'status': 'disabled',
              'enabled': false,
              'disabledReason': 'replaced',
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
          if (newUid != null && newUid.isNotEmpty && oldUid != newUid) {
            transaction.update(firestore.collection('cards').doc(newUid), {
              'status': 'active',
              'enabled': true,
              'studentId': record.id,
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
        });
        RideGuardCacheService.instance.invalidate('cards');
        RideGuardCacheService.instance.invalidate('students');
        if (values['routeChanged'] == true || values['busChanged'] == true) {
          await _syncParentLinks(record, values);
        }
        if (context.mounted) snack(context, 'Student updated successfully');
      } catch (error) {
        if (context.mounted) {
          snackError(context, error, prefix: 'Unable to update student');
        }
      }
      return;
    }
    if (collection == 'buses') {
      final values = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _BusEditDialog(record: record),
      );
      if (values == null) return;
      if (!await confirmAction(context,
          title: 'Save bus changes?',
          message: 'Devices assigned to this bus will show the new plate.')) {
        return;
      }
      try {
        final firestore = FirebaseFirestore.instance;
        final batch = firestore.batch();
        batch.update(firestore.collection('buses').doc(record.id), {
          'plate': values['plate'],
          if (values['capacity'] != null) 'capacity': values['capacity'],
          'updatedAt': FieldValue.serverTimestamp(),
        });
        final devices = await firestore
            .collection('devices')
            .where('busId', isEqualTo: record.id)
            .get();
        for (final device in devices.docs) {
          batch.update(device.reference, {
            'busPlate': values['plate'],
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
        RideGuardCacheService.instance.invalidate('buses');
        RideGuardCacheService.instance.invalidate('devices');
        if (context.mounted) snack(context, 'Bus updated successfully');
      } catch (error) {
        if (context.mounted) {
          snackError(context, error, prefix: 'Unable to update bus');
        }
      }
      return;
    }
    if (collection == 'devices') {
      final values = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _DeviceEditDialog(record: record),
      );
      if (values == null) return;
      try {
        await FirebaseFirestore.instance
            .collection('devices')
            .doc(record.id)
            .update({
          'deviceId': values['deviceId'],
          'busId': values['busId'],
          'busPlate': values['busPlate'],
          'updatedAt': FieldValue.serverTimestamp(),
        });
        RideGuardCacheService.instance.invalidate('devices');
        if (context.mounted) snack(context, 'Device updated successfully');
      } catch (error) {
        if (context.mounted) {
          snackError(context, error, prefix: 'Unable to update device');
        }
      }
      return;
    }
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _RecordEditDialog(
        title: 'Edit ${recordName(collection, record)}',
        name: record.text('name'),
        address: record.text('address'),
        phone: record.text('contactPhone'),
        includeContactFields: collection == 'schools',
      ),
    );
    if (values == null) return;
    if (!await confirmAction(context,
        title: 'Confirm edit', message: 'Save the changes to this record?')) {
      return;
    }
    await FirebaseFirestore.instance
        .collection(collection)
        .doc(record.id)
        .update({
      'name': values['name']!.trim(),
      if (collection == 'schools') 'address': values['address']!.trim(),
      if (collection == 'schools')
        'contactPhone': values['contactPhone']!.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (context.mounted) snack(context, 'Saved successfully');
  }

  /// Firestore fields for a pickup/drop point. Stop name is written to both
  /// `<x>Stop` and `<x>Location` (as the Add Student form does) so other
  /// screens keep working. A route stop clears any old map pin.
  Map<String, dynamic> _pointUpdate(String prefix, dynamic point) {
    if (point is! Map) return const {};
    final name = point['name']?.toString() ?? '';
    final lat = point['lat'];
    final lng = point['lng'];
    return {
      '${prefix}Stop': name,
      '${prefix}Location': name,
      '${prefix}Lat': lat is num ? lat : FieldValue.delete(),
      '${prefix}Lng': lng is num ? lng : FieldValue.delete(),
    };
  }

  /// Keeps the parent -> route/bus links (used by the parent app to see the
  /// bus) correct after a student moves to another route or bus.
  Future<void> _syncParentLinks(
      FirestoreRecord record, Map<String, dynamic> values) async {
    final firestore = FirebaseFirestore.instance;
    final old = record.data;
    final parentIds = <String>{
      for (final id
          in (old['parentIds'] is List ? old['parentIds'] as List : const []))
        id.toString(),
      old['parentId']?.toString() ?? '',
    }..removeWhere((id) => id.isEmpty);
    if (parentIds.isEmpty) return;
    final oldRoute = old['routeId']?.toString() ?? '';
    final oldBus = old['busId']?.toString() ?? '';
    final newRoute = values['routeId']?.toString() ?? oldRoute;
    final newBus = values['busId']?.toString() ?? oldBus;
    try {
      final adds = FieldValue.arrayUnion(parentIds.toList());
      if (newRoute.isNotEmpty) {
        await firestore.collection('routes').doc(newRoute).set(
            {'parentIds': adds, 'updatedAt': FieldValue.serverTimestamp()},
            SetOptions(merge: true));
      }
      if (newBus.isNotEmpty) {
        await firestore.collection('buses').doc(newBus).set(
            {'parentIds': adds, 'updatedAt': FieldValue.serverTimestamp()},
            SetOptions(merge: true));
      }
      Set<String> stillUsed(
          Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
        final used = <String>{};
        for (final doc in docs) {
          final item = doc.data();
          if (doc.id == record.id || item['deleted'] == true) continue;
          if (item['parentIds'] is List) {
            for (final id in item['parentIds'] as List) {
              used.add(id.toString());
            }
          }
          used.add(item['parentId']?.toString() ?? '');
        }
        return used;
      }

      if (oldRoute.isNotEmpty && oldRoute != newRoute) {
        final others = await firestore
            .collection('students')
            .where('routeId', isEqualTo: oldRoute)
            .get();
        final removable = parentIds.difference(stillUsed(others.docs));
        if (removable.isNotEmpty) {
          await firestore.collection('routes').doc(oldRoute).update({
            'parentIds': FieldValue.arrayRemove(removable.toList()),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }
      if (oldBus.isNotEmpty && oldBus != newBus) {
        final others = await firestore
            .collection('students')
            .where('busId', isEqualTo: oldBus)
            .get();
        final removable = parentIds.difference(stillUsed(others.docs));
        if (removable.isNotEmpty) {
          await firestore.collection('buses').doc(oldBus).update({
            'parentIds': FieldValue.arrayRemove(removable.toList()),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }
    } catch (error) {
      developer.log('Parent link sync failed',
          name: 'rideguard.admin', error: error);
    }
  }

  void _showInfoDetails(
      BuildContext context, String collection, FirestoreRecord record) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _InfoDetailsDialog(
        loader: _loadInfo(collection, record),
        onEdit: () async {
          Navigator.pop(dialogContext);
          if (collection == 'parents') {
            await showDialog<void>(
              context: context,
              builder: (_) => _ParentDialog(record: record),
            );
          } else {
            await _editRecord(context, collection, record);
          }
        },
        onDelete: () async {
          Navigator.pop(dialogContext);
          if (!await confirmAction(context,
              title: 'Delete record?',
              message: 'This record will be disabled and hidden.')) {
            return;
          }
          try {
            await FirestoreRepository(FirebaseFirestore.instance)
                .delete(collection, record.id);
            if (context.mounted) snack(context, 'Record deleted');
          } catch (error) {
            if (context.mounted) {
              snackError(context, error, prefix: 'Delete failed');
            }
          }
        },
      ),
    );
  }

  void _showStudentDetails(BuildContext context, FirestoreRecord record) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _StudentDetailsDialog(
        record: record,
        onEdit: () {
          Navigator.pop(dialogContext);
          _editRecord(context, 'students', record);
        },
        onDelete: () async {
          Navigator.pop(dialogContext);
          if (!await confirmAction(context,
              title: 'Delete record?',
              message: 'This record will be disabled and hidden.')) {
            return;
          }
          try {
            await FirestoreRepository(FirebaseFirestore.instance)
                .delete('students', record.id);
            if (context.mounted) snack(context, 'Record deleted');
          } catch (error) {
            if (context.mounted) {
              snackError(context, error, prefix: 'Delete failed');
            }
          }
        },
      ),
    );
  }

  void _showRecord(
      BuildContext context, String collection, FirestoreRecord record) {
    if (collection == 'students') {
      _showStudentDetails(context, record);
      return;
    }
    if (collection == 'buses' ||
        collection == 'parents' ||
        collection == 'devices') {
      _showInfoDetails(context, collection, record);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_firstRecordValue(
            record,
            [
              'fullName',
              'name',
              'schoolName',
              'School name',
              'displayName',
            ],
            recordName(collection, record))),
        content: SingleChildScrollView(
          child: collection == 'schools' &&
                  record.data['lat'] is num &&
                  record.data['lng'] is num
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(record.text('address', 'Address not set')),
                  const SizedBox(height: 12),
                  RealMap(
                    height: 220,
                    initialCenter: LatLng(
                      (record.data['lat'] as num).toDouble(),
                      (record.data['lng'] as num).toDouble(),
                    ),
                    markers: [
                      MapMarker(
                        LatLng(
                          (record.data['lat'] as num).toDouble(),
                          (record.data['lng'] as num).toDouble(),
                        ),
                        Colors.red,
                        Icons.school,
                        label: recordName(collection, record),
                      ),
                    ],
                  ),
                  const Text('© OpenStreetMap contributors'),
                ])
              : Text(record.data.entries
                  .where((entry) => entry.value is! Timestamp)
                  .map((entry) => '${entry.key}: ${entry.value}')
                  .join('\n')),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              if (!await confirmAction(context,
                  title: 'Delete record?',
                  message: 'This record will be disabled and hidden.')) {
                return;
              }
              try {
                await FirestoreRepository(FirebaseFirestore.instance).delete(
                    collection == 'drivers' ? 'users' : collection, record.id);
                if (context.mounted) snack(context, 'Record deleted');
              } catch (error) {
                if (context.mounted)
                  snackError(context, error, prefix: 'Delete failed');
              }
            },
            child: const Text('Delete'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showDriverDetails(BuildContext context, FirestoreRecord record) {
    final data = record.data;
    final createdAt = data['createdAt'];
    final lastLogin = data['lastLogin'] ?? data['lastLoginAt'];
    final busId = data['busId']?.toString();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(recordName('drivers', record)),
        content: SizedBox(
          width: 420,
          child: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            future: busId == null || busId.isEmpty
                ? null
                : FirebaseFirestore.instance
                    .collection('buses')
                    .doc(busId)
                    .get(),
            builder: (context, snapshot) {
              final busName = snapshot.data?.data()?['plate']?.toString() ??
                  snapshot.data?.data()?['name']?.toString() ??
                  'Not assigned';
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _driverDetail('Assigned bus', busName),
                  _driverDetail(
                      'Phone', data['phone']?.toString() ?? 'Not set'),
                  _driverDetail(
                      'Email', data['email']?.toString() ?? 'Not set'),
                  _driverDetail('Registered',
                      _formatDriverDate(createdAt) ?? 'Not available'),
                  _driverDetail('Last login',
                      _formatDriverDate(lastLogin) ?? 'Not available'),
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _driverDetail(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(label)),
            Expanded(child: Text(value)),
          ],
        ),
      );

  String? _formatDriverDate(dynamic value) {
    DateTime? date;
    if (value is Timestamp) date = value.toDate();
    if (value is DateTime) date = value;
    if (date == null) return null;
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }
}

final collectionProvider = StreamProvider.family<List<FirestoreRecord>, String>(
  (ref, collection) => ref.watch(firestoreRepositoryProvider).watch(
        collection == 'drivers' ? 'users' : collection,
        query: collection == 'drivers'
            ? (items) => items.where('roles', arrayContains: 'driver')
            : null,
      ),
);

IconData _iconFor(String collection) => switch (collection) {
      'schools' => Icons.school,
      'buses' => Icons.directions_bus,
      'devices' => Icons.memory,
      'parents' => Icons.family_restroom,
      'students' => Icons.child_care,
      'cards' => Icons.credit_card,
      'drivers' => Icons.person,
      _ => Icons.circle_outlined,
    };

class AdminDashboard extends ConsumerStatefulWidget {
  const AdminDashboard({super.key});

  @override
  ConsumerState<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends ConsumerState<AdminDashboard> {
  String? _selectedBusId;

  @override
  Widget build(BuildContext context) {
    final schools = ref.watch(schoolsProvider).value?.length;
    final buses = ref.watch(busesProvider).value?.length;
    final devices = ref.watch(devicesProvider).value?.length;
    final parents = ref.watch(parentsProvider).value?.length;
    final students = ref.watch(studentsProvider).value?.length;
    final cards = ref.watch(cardsProvider).value?.length;
    final stats = [
      ('Schools', '${schools ?? 0}', Icons.school),
      ('Buses', '${buses ?? 0}', Icons.directions_bus),
      ('Devices', '${devices ?? 0}', Icons.memory),
      ('Parents', '${parents ?? 0}', Icons.family_restroom),
      ('Students', '${students ?? 0}', Icons.child_care),
      ('Cards', '${cards ?? 0}', Icons.credit_card),
    ];
    final s = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Dashboard', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (ctx, c) {
        final w = (c.maxWidth - 12) / 2;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final e in stats)
            SizedBox(
              width: w,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Icon(e.$3, color: s.primary, size: 30),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(e.$2,
                              style: Theme.of(ctx)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          Text(e.$1),
                        ])),
                  ]),
                ),
              ),
            ),
        ]);
      }),
      const SizedBox(height: 20),
      Text('Live buses', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream:
            FirebaseFirestore.instance.collection('liveLocations').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Text('Unable to load live fleet. Please retry.');
          }
          final liveDocuments = snapshot.data?.docs ?? const [];
          final liveBusIds = liveDocuments.map((document) => document.id);
          final busRecords = ref.watch(busesProvider).value ?? const [];
          final availableBusIds = <String>{
            ...busRecords.map((record) => record.id),
            ...liveBusIds,
          }.toList()
            ..sort();
          final selectedBusId =
              availableBusIds.contains(_selectedBusId) ? _selectedBusId : null;
          final markers = <MapMarker>[];
          final details = <Widget>[];
          for (final document in liveDocuments) {
            final data = document.data();
            final tripId = data['tripId']?.toString();
            final updated = data['updatedAt'];
            final updatedAt = updated is Timestamp ? updated.toDate() : null;
            final stale = updatedAt == null ||
                DateTime.now().difference(updatedAt).inMinutes >= 2;
            if ((selectedBusId == null || document.id == selectedBusId) &&
                tripId != null &&
                tripId.isNotEmpty &&
                data['lat'] is num &&
                data['lng'] is num) {
              markers.add(MapMarker(
                LatLng((data['lat'] as num).toDouble(),
                    (data['lng'] as num).toDouble()),
                stale ? Colors.orange.shade800 : Colors.green.shade700,
                Icons.directions_bus,
                label: busRecords
                        .where((record) => record.id == document.id)
                        .map((record) => record.data['plate']?.toString())
                        .firstWhere((plate) => plate?.trim().isNotEmpty == true,
                            orElse: () => 'Bus') ??
                    'Bus',
              ));
              details.add(_FleetTripDetails(
                tripId: tripId,
                busId: data['busId']?.toString() ?? '',
                updatedAt: updatedAt,
                stale: stale,
              ));
            }
          }
          if (availableBusIds.isEmpty) {
            return const SizedBox(
              height: 120,
              child: Center(
                  child:
                      Text('No buses are currently reporting GPS locations.')),
            );
          }
          return Column(children: [
            DropdownButtonFormField<String?>(
              value: selectedBusId,
              decoration: const InputDecoration(
                labelText: 'Bus to track',
                prefixIcon: Icon(Icons.directions_bus),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All live buses'),
                ),
                for (final busId in availableBusIds)
                  DropdownMenuItem<String?>(
                    value: busId,
                    child: Text(
                      busRecords
                          .where((record) => record.id == busId)
                          .map((record) =>
                              record.data['plate']?.toString() ?? '')
                          .firstWhere((plate) => plate.isNotEmpty,
                              orElse: () => 'Bus unavailable'),
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _selectedBusId = value),
            ),
            const SizedBox(height: 8),
            if (markers.isEmpty)
              const SizedBox(
                height: 120,
                child: Center(
                    child: Text(
                        'The selected bus has no active trip or GPS location.')),
              )
            else
              RealMap(
                height: 300,
                initialCenter: markers.first.at,
                markers: markers,
              ),
            ...details,
          ]);
        },
      ),
    ]);
  }
}

class _FleetTripDetails extends StatelessWidget {
  const _FleetTripDetails({
    required this.tripId,
    required this.busId,
    required this.updatedAt,
    required this.stale,
  });

  final String tripId;
  final String busId;
  final DateTime? updatedAt;
  final bool stale;

  Future<Map<String, dynamic>> _load() async {
    final firestore = FirebaseFirestore.instance;
    final trip = await firestore.collection('trips').doc(tripId).get();
    final tripData = trip.data() ?? const <String, dynamic>{};
    final routeId = tripData['routeId']?.toString();
    final driverId = tripData['driverId']?.toString();
    final bus = busId.isEmpty
        ? null
        : await firestore.collection('buses').doc(busId).get();
    final route = routeId == null
        ? null
        : await firestore.collection('routes').doc(routeId).get();
    final driver = driverId == null
        ? null
        : await firestore.collection('users').doc(driverId).get();
    return {
      'bus': bus?.data()?['plate']?.toString() ?? 'Unnamed bus',
      'route': tripData['routeName']?.toString() ??
          route?.data()?['name']?.toString() ??
          'Unnamed route',
      'driver': tripData['driverName']?.toString() ??
          driver?.data()?['name']?.toString() ??
          driver?.data()?['displayName']?.toString() ??
          'Unnamed driver',
      'count': tripData['onBoardCount'] ??
          (tripData['onBoardStudentIds'] is List
              ? (tripData['onBoardStudentIds'] as List).length
              : 0),
    };
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _load(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListTile(
            leading: const Icon(Icons.error),
            title: const Text('Unable to load trip details'),
            subtitle: const Text('Unable to load this location.'),
          );
        }
        if (!snapshot.hasData) {
          return const ListTile(
            leading: CircularProgressIndicator(),
            title: Text('Loading live trip details'),
          );
        }
        final data = snapshot.data!;
        return ListTile(
          leading: Icon(
            stale ? Icons.warning_amber : Icons.directions_bus,
            color: stale ? Colors.orange.shade800 : Colors.green.shade700,
          ),
          title: Text('${data['bus']} • ${data['route']}'),
          subtitle: Text(
              'Driver: ${data['driver']} • On board: ${data['count']}\n'
              '${stale ? 'Location delayed' : 'Updated ${updatedAt ?? 'not available'}'}'),
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text('Trip details: ${data['route']}'),
              content: Text('Bus: ${data['bus']}\n'
                  'Driver: ${data['driver']}\n'
                  'On board: ${data['count']}\n'
                  'Last update: ${updatedAt ?? 'not available'}'),
            ),
          ),
        );
      },
    );
  }
}

class SchoolsPage extends StatelessWidget {
  const SchoolsPage({super.key});
  @override
  Widget build(BuildContext context) => ListPage(
        title: 'Schools',
        collection: 'schools',
        rows: const [],
        addLabel: 'Add school',
        onAdd: (c) => showDialog<void>(
          context: c,
          builder: (_) => const _SchoolDialog(),
        ),
      );
}

class _SchoolDialog extends StatelessWidget {
  const _SchoolDialog({this.record});
  final FirestoreRecord? record;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 48).clamp(280.0, 620.0).toDouble();
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: size.height * 0.85,
        ),
        child: SizedBox(
          width: dialogWidth,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    record == null ? 'Add school' : 'Edit school',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const Divider(),
                Expanded(child: _SchoolForm(record: record)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SchoolForm extends StatefulWidget {
  const _SchoolForm({this.record});
  final FirestoreRecord? record;

  @override
  State<_SchoolForm> createState() => _SchoolFormState();
}

class _SchoolFormState extends State<_SchoolForm> {
  late final TextEditingController _name;
  late final TextEditingController _address;
  late final TextEditingController _phone;
  late final TextEditingController _search;
  LatLng? _location;
  bool _searching = false;
  Timer? _searchTimer;
  DateTime? _lastSearchAt;
  List<Map<String, dynamic>> _results = const [];
  List<BusRoute> _routes = const [];
  String? _routeId;

  @override
  void initState() {
    super.initState();
    final data = widget.record?.data ?? const <String, dynamic>{};
    _routeId = data['routeId']?.toString();
    FirebaseFirestore.instance.collection('routes').get().then((snapshot) {
      if (mounted) {
        setState(
            () => _routes = snapshot.docs.map(BusRoute.fromDocument).toList());
      }
    });
    _name = TextEditingController(
        text: widget.record == null
            ? ''
            : _firstRecordValue(widget.record!, [
                'name',
                'schoolName',
                'School name',
                'displayName',
              ]));
    _address = TextEditingController(text: data['address']?.toString() ?? '');
    _phone =
        TextEditingController(text: data['contactPhone']?.toString() ?? '');
    _search = TextEditingController();
    final lat = data['lat'];
    final lng = data['lng'];
    if (lat is num && lng is num)
      _location = LatLng(lat.toDouble(), lng.toDouble());
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    _search.dispose();
    _searchTimer?.cancel();
    super.dispose();
  }

  void _scheduleSearch(String value) {
    _searchTimer?.cancel();
    if (value.trim().isEmpty) {
      setState(() => _results = const []);
      return;
    }
    _searchTimer = Timer(const Duration(milliseconds: 650), _searchLocation);
  }

  Future<void> _searchLocation() async {
    final query = _search.text.trim();
    if (query.isEmpty) return;
    final last = _lastSearchAt;
    final wait = last == null
        ? Duration.zero
        : const Duration(seconds: 1) - DateTime.now().difference(last);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _lastSearchAt = DateTime.now();
    setState(() => _searching = true);
    try {
      final response = await http.get(
          Uri.https('nominatim.openstreetmap.org', '/search', {
            'q': query,
            'format': 'jsonv2',
            'limit': '5',
            'countrycodes': 'lk',
            'viewbox': '79.4,10.1,82.1,5.8',
            'bounded': '1',
          }),
          headers: {'User-Agent': 'RideGuard/1.0 (school location picker)'});
      if (response.statusCode != 200) throw StateError('Map search failed.');
      final results = jsonDecode(response.body) as List;
      if (!mounted) return;
      setState(() => _results = [
            for (final result in results)
              Map<String, dynamic>.from(result as Map),
          ]);
      if (_results.isEmpty) {
        snack(context, 'No school location found.', warn: true);
      }
    } catch (error) {
      if (mounted) snackError(context, error, prefix: 'Unable to find school');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _selectResult(Map<String, dynamic> result) {
    final selected = parseSchoolSearchResult(result);
    if (selected == null) return;
    setState(() {
      _location = selected.location;
      _address.text = selected.name;
      _results = const [];
    });
  }

  Future<void> _useCurrentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('Location services are disabled.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Location permission was denied.');
      }
      final position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _location = LatLng(position.latitude, position.longitude);
        _results = const [];
      });
    } catch (error) {
      if (mounted) {
        snackError(context, error, prefix: 'Unable to get current location');
      }
    }
  }

  Future<void> _save() async {
    if (!hasRequiredSchoolLocation(_name.text, _location)) {
      snack(context, 'Enter a school name and choose its map location.',
          error: true);
      return;
    }
    if (!await confirmAction(context,
        title: widget.record == null ? 'Create school?' : 'Save school edits?',
        message: 'The school details and location will be saved.')) {
      return;
    }
    final data = {
      'name': _name.text.trim(),
      'address': _address.text.trim(),
      'contactPhone': _phone.text.trim(),
      'routeId': _routeId,
      'lat': _location!.latitude,
      'lng': _location!.longitude,
      'enabled': true,
      'deleted': false,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    try {
      final collection = FirebaseFirestore.instance.collection('schools');
      if (widget.record == null) {
        await collection
            .add({...data, 'createdAt': FieldValue.serverTimestamp()});
      } else {
        await collection.doc(widget.record!.id).update(data);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) snackError(context, error, prefix: 'Unable to save school');
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'School name')),
          const SizedBox(height: 12),
          TextField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'Address')),
          const SizedBox(height: 12),
          TextField(
              controller: _phone,
              decoration: const InputDecoration(labelText: 'Contact phone')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            value: _routeId,
            decoration: const InputDecoration(labelText: 'Route'),
            items: [
              for (final route in _routes)
                DropdownMenuItem(value: route.id, child: Text(route.name)),
            ],
            onChanged: (value) => setState(() => _routeId = value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _search,
            decoration: InputDecoration(
              labelText: 'Search school on map',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                onPressed: _searching ? null : _searchLocation,
                icon: _searching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.travel_explore),
              ),
            ),
            onChanged: _scheduleSearch,
            onSubmitted: (_) => _searchLocation(),
          ),
          if (_results.isNotEmpty)
            ..._results.map((result) => ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(
                      result['display_name']?.toString() ?? 'Unnamed result'),
                  onTap: () => _selectResult(result),
                )),
          const SizedBox(height: 12),
          RealMap(
            height: 240,
            markers: _location == null
                ? const []
                : [
                    MapMarker(_location!, Colors.red, Icons.school,
                        label: 'School')
                  ],
            initialCenter: _location,
            onTap: (point) => setState(() => _location = point),
          ),
          const SizedBox(height: 8),
          Text(_location == null
              ? 'Tap the map or search for the school'
              : 'Location: ${_location!.latitude.toStringAsFixed(5)}, ${_location!.longitude.toStringAsFixed(5)}'),
          TextButton.icon(
            onPressed: _useCurrentLocation,
            icon: const Icon(Icons.my_location),
            label: const Text('Use my current location'),
          ),
          const Text('© OpenStreetMap contributors'),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            const SizedBox(width: 8),
            Flexible(
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
          ]),
        ]),
      );
}

class BusesPage extends StatelessWidget {
  const BusesPage({super.key});

  @override
  Widget build(BuildContext context) => ListPage(
        title: 'Buses',
        collection: 'buses',
        rows: const [],
        addLabel: 'Add bus',
        onAdd: (c) => simpleForm(c, 'Add bus', ['Number plate', 'Capacity']),
      );
}

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});
  @override
  Widget build(BuildContext context) => ListPage(
        title: 'Devices (ESP32)',
        collection: 'devices',
        rows: const [],
        addLabel: 'Add device',
        onAdd: (c) => showDialog<void>(
          context: c,
          builder: (_) => const _DeviceDialog(),
        ),
      );
}

class _DeviceDialog extends StatefulWidget {
  const _DeviceDialog();

  @override
  State<_DeviceDialog> createState() => _DeviceDialogState();
}

class _DeviceDialogState extends State<_DeviceDialog> {
  final _device = TextEditingController();
  String? _busId;

  @override
  void dispose() {
    _device.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_device.text.trim().isEmpty || _busId == null) {
      snack(context, 'Enter a device code and select a bus.', error: true);
      return;
    }
    final busSnapshot =
        await FirebaseFirestore.instance.collection('buses').doc(_busId).get();
    final busData = busSnapshot.data();
    final busLabel = busSnapshot.exists &&
            busData?['plate']?.toString().trim().isNotEmpty == true
        ? busData!['plate'].toString().trim()
        : 'the selected bus';
    if (!await confirmAction(context,
        title: 'Create device?', message: 'Assign this device to $busLabel?')) {
      return;
    }
    try {
      await FirebaseFirestore.instance.collection('devices').add({
        'deviceId': _device.text.trim(),
        'busId': _busId,
        'busPlate': busLabel == 'the selected bus' ? null : busLabel,
        'enabled': true,
        'deleted': false,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted)
        snackError(context, error, prefix: 'Unable to create device');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add device'),
        content: SizedBox(
          width: 420,
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection('buses').snapshots(),
            builder: (context, snapshot) {
              final buses = [...snapshot.data?.docs ?? const []]
                ..sort((a, b) => _busLabel(a).compareTo(_busLabel(b)));
              return Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: _device,
                  decoration: const InputDecoration(labelText: 'Device code'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: _busId,
                  decoration: const InputDecoration(labelText: 'Bus number'),
                  items: [
                    for (final bus in buses)
                      DropdownMenuItem(
                        value: bus.id,
                        child: Text(_busLabel(bus),
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) => setState(() => _busId = value),
                ),
              ]);
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );

  String _busLabel(QueryDocumentSnapshot<Map<String, dynamic>> bus) {
    final data = bus.data();
    return data['plate']?.toString() ??
        data['Number plate']?.toString() ??
        data['name']?.toString() ??
        'Bus unavailable';
  }
}

class RoutesPage extends StatefulWidget {
  const RoutesPage({super.key, this.routeStream});
  final Stream<List<BusRoute>>? routeStream;

  @override
  State<RoutesPage> createState() => _RoutesPageState();
}

class _RoutesPageState extends State<RoutesPage> {
  @override
  Widget build(BuildContext context) {
    final routeStream = widget.routeStream?.map<Object>((routes) => routes) ??
        FirebaseFirestore.instance
            .collection('routes')
            .orderBy('name')
            .snapshots()
            .map<Object>((snapshot) => snapshot);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: const _RouteDialog(),
          ),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Add route'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          Text('Routes', style: Theme.of(context).textTheme.headlineSmall),
          StreamBuilder<Object>(
            stream: routeStream,
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data is List<BusRoute>) return const SizedBox.shrink();
              final records =
                  ((data as QuerySnapshot<Map<String, dynamic>>?)?.docs ??
                          const [])
                      .where((record) =>
                          record.data()['deleted'] != true &&
                          record.data()['enabled'] != false)
                      .toList();
              if (records.isEmpty) return const SizedBox.shrink();
              return Column(children: [
                for (final record in records)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: ListTile(
                      leading: const Icon(Icons.alt_route),
                      title:
                          Text(record.data()['name']?.toString() ?? record.id),
                      subtitle: Text(
                          '${(record.data()['stops'] as List?)?.length ?? 0} destinations'),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _RouteDetailsDialog(record: record),
                      ),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Edit route',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => Dialog(
                              insetPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 24),
                              child: _RouteDialog(record: record),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Delete route',
                          icon: const Icon(Icons.delete_outline),
                          color: Theme.of(context).colorScheme.error,
                          onPressed: () async {
                            if (!await confirmAction(context,
                                title: 'Delete route?',
                                message:
                                    'This route will be disabled and hidden.'))
                              return;
                            await FirebaseFirestore.instance
                                .collection('routes')
                                .doc(record.id)
                                .update({
                              'deleted': true,
                              'enabled': false,
                              'updatedAt': FieldValue.serverTimestamp(),
                            });
                          },
                        ),
                      ]),
                    ),
                  ),
              ]);
            },
          ),
        ],
      ),
    );
  }
}

class _RouteDialog extends StatefulWidget {
  const _RouteDialog({this.record});
  final QueryDocumentSnapshot<Map<String, dynamic>>? record;

  @override
  State<_RouteDialog> createState() => _RouteDialogState();
}

class _RouteDialogState extends State<_RouteDialog> {
  final _name = TextEditingController();
  final _search = TextEditingController();
  final _stops = <BusStop>[];
  List<Map<String, dynamic>> _results = const [];
  bool _searching = false;
  bool _saving = false;
  String? _busId;

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final data = widget.record?.data();
    if (data == null) return;
    _name.text = data['name']?.toString() ?? '';
    _busId = data['busId']?.toString();
    final rawStops = data['stops'] is List ? data['stops'] as List : const [];
    _stops.addAll(rawStops
        .whereType<Map>()
        .map((item) => BusStop.fromMap(Map<String, dynamic>.from(item)))
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order)));
  }

  Future<void> _searchLocation() async {
    final query = _search.text.trim();
    if (query.isEmpty) return;
    setState(() => _searching = true);
    try {
      final response = await http.get(
        Uri.https('nominatim.openstreetmap.org', '/search', {
          'q': query,
          'format': 'jsonv2',
          'limit': '5',
          'countrycodes': 'lk',
          'viewbox': '79.4,10.1,82.1,5.8',
          'bounded': '1',
        }),
        headers: {'User-Agent': 'RideGuard/1.0 (route location picker)'},
      );
      if (response.statusCode != 200) throw StateError('Map search failed.');
      final results = jsonDecode(response.body) as List;
      if (!mounted) return;
      setState(() => _results = [
            for (final result in results)
              Map<String, dynamic>.from(result as Map),
          ]);
      if (_results.isEmpty)
        snack(context, 'No Sri Lankan location found.', warn: true);
    } catch (error) {
      if (mounted)
        snackError(context, error, prefix: 'Unable to find route location');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _selectSearchResult(Map<String, dynamic> result) async {
    final location = parseSchoolSearchResult(result);
    if (location == null) return;
    setState(() => _results = const []);
    await _addPoint(location.location);
  }

  Future<List<LatLng>> _roadGeometry(List<LatLng> points) async {
    if (points.length < 2) return points;
    final coordinates =
        points.map((point) => '${point.longitude},${point.latitude}').join(';');
    final response = await http.get(Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/$coordinates?overview=full&geometries=geojson'));
    if (response.statusCode != 200) return points;
    final body = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    final routes = body['routes'];
    final geometry = routes is List && routes.isNotEmpty
        ? (routes.first as Map)['geometry']
        : null;
    final raw = geometry is Map ? geometry['coordinates'] : null;
    if (raw is! List) return points;
    return [
      for (final item in raw)
        if (item is List && item.length >= 2)
          LatLng((item[1] as num).toDouble(), (item[0] as num).toDouble()),
    ];
  }

  Future<void> _addPoint(LatLng point) async {
    final selection = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => RoutePointNameDialog(stopNumber: _stops.length + 1),
    );
    if (selection == null || !mounted) return;
    setState(() => _stops.add(BusStop(
          name: (selection['name'] as String).trim(),
          position: point,
          order: _stops.length,
          isSchool: selection['isSchool'] == true,
        )));
  }

  Future<void> _save() async {
    if (_stops.length < 2) {
      snack(context, 'Choose at least a start and an end point.', error: true);
      return;
    }
    if (_name.text.trim().isEmpty) {
      snack(context, 'Enter a route name.', error: true);
      return;
    }
    if (!await confirmAction(context,
        title: 'Save route?',
        message: 'Save this route and its destinations?')) return;
    setState(() => _saving = true);
    try {
      final points = _stops.map((stop) => stop.position).toList();
      final road = await _roadGeometry(points);
      await RouteRepository(FirebaseFirestore.instance).saveRoute(
        routeId: widget.record?.id,
        name: _name.text.trim(),
        stops: [
          for (var i = 0; i < _stops.length; i++)
            BusStop(
              name: _stops[i].name.trim(),
              position: _stops[i].position,
              order: i,
              isSchool: _stops[i].isSchool,
            ),
        ],
        geometry: road,
        busId: _busId,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      Navigator.pop(context);
      snack(context, 'Route saved');
    } catch (error) {
      if (mounted) snackError(context, error, prefix: 'Unable to save route');
    } finally {
      if (mounted && _saving) setState(() => _saving = false);
    }
  }

  Future<void> _editStop(int index) async {
    final stop = _stops[index];
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _StopEditDialog(
          number: index + 1, name: stop.name, isSchool: stop.isSchool),
    );
    if (result == null || !mounted) return;
    setState(() => _stops[index] = BusStop(
          name: (result['name'] as String).trim(),
          position: stop.position,
          order: stop.order,
          isSchool: result['isSchool'] == true,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.record == null ? 'Add route' : 'Edit route'),
      content: SizedBox(
        width: (MediaQuery.sizeOf(context).width - 32)
            .clamp(320.0, 900.0)
            .toDouble(),
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Route name'),
                ),
                const SizedBox(height: 16),
                Text('Destinations (${_stops.length})',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  _stops.isEmpty
                      ? 'No destinations yet. Search or tap the map below to add one.'
                      : 'Drag the handle to change the order. Tap a destination to rename it.',
                  style: theme.textTheme.bodySmall,
                ),
                if (_stops.isNotEmpty)
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: _stops.length,
                    onReorder: (oldIndex, newIndex) => setState(() {
                      if (newIndex > oldIndex) newIndex -= 1;
                      final item = _stops.removeAt(oldIndex);
                      _stops.insert(newIndex, item);
                    }),
                    itemBuilder: (context, i) => ListTile(
                      key: ObjectKey(_stops[i]),
                      contentPadding: EdgeInsets.zero,
                      leading:
                          CircleAvatar(radius: 14, child: Text('${i + 1}')),
                      title: Text(_stops[i].name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          _stops[i].isSchool
                              ? 'School'
                              : '${_stops[i].position.latitude.toStringAsFixed(4)}, ${_stops[i].position.longitude.toStringAsFixed(4)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      onTap: () => _editStop(i),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Rename',
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _editStop(i),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => setState(() => _stops.removeAt(i)),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ]),
                    ),
                  ),
                const SizedBox(height: 16),
                Text('Add a destination', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: 'Search Sri Lankan location',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      onPressed: _searching ? null : _searchLocation,
                      icon: _searching
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.travel_explore),
                    ),
                  ),
                  onSubmitted: (_) => _searchLocation(),
                ),
                if (_results.isNotEmpty)
                  ..._results.map((result) => ListTile(
                        leading: const Icon(Icons.place_outlined),
                        title: Text(
                            result['display_name']?.toString() ?? 'Location'),
                        onTap: () => _selectSearchResult(result),
                      )),
                const SizedBox(height: 8),
                const Text(
                    'Tap the map to add a named start, end, or destination.'),
                const SizedBox(height: 12),
                RealMap(
                  height: 320,
                  paths: _stops.length < 2
                      ? const []
                      : [
                          MapPath(_stops.map((stop) => stop.position).toList(),
                              theme.colorScheme.primary)
                        ],
                  markers: [
                    for (var i = 0; i < _stops.length; i++)
                      MapMarker(_stops[i].position, theme.colorScheme.primary,
                          Icons.location_on,
                          label: '${i + 1}. ${_stops[i].name}'),
                  ],
                  onTap: _addPoint,
                ),
              ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Save route')),
      ],
    );
  }
}

class RoutePointNameDialog extends StatefulWidget {
  const RoutePointNameDialog({super.key, required this.stopNumber});
  final int stopNumber;

  @override
  State<RoutePointNameDialog> createState() => _RoutePointNameDialogState();
}

class _RoutePointNameDialogState extends State<RoutePointNameDialog> {
  final _controller = TextEditingController();
  bool _isSchool = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Name stop ${widget.stopNumber}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Stop name'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('This location is a school'),
            value: _isSchool,
            onChanged: (value) => setState(() => _isSchool = value ?? false),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'name': _controller.text.trim(),
              'isSchool': _isSchool,
            }),
            child: const Text('Add point'),
          ),
        ],
      );
}

class _RouteDetailsDialog extends StatelessWidget {
  const _RouteDetailsDialog({required this.record});
  final QueryDocumentSnapshot<Map<String, dynamic>> record;

  @override
  Widget build(BuildContext context) {
    final data = record.data();
    final stops = (data['stops'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => BusStop.fromMap(Map<String, dynamic>.from(item)))
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final geometry = (data['geometry'] as List? ?? const [])
        .whereType<Map>()
        .where((point) => point['lat'] is num && point['lng'] is num)
        .map((point) => LatLng(
            (point['lat'] as num).toDouble(), (point['lng'] as num).toDouble()))
        .toList();
    return AlertDialog(
      title: Text(data['name']?.toString() ?? record.id),
      content: SizedBox(
        width: (MediaQuery.sizeOf(context).width - 48)
            .clamp(280.0, 680.0)
            .toDouble(),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (geometry.isNotEmpty)
              RealMap(
                height: 300,
                paths: [
                  MapPath(geometry, Theme.of(context).colorScheme.primary)
                ],
                markers: [
                  for (final stop in stops)
                    MapMarker(
                        stop.position,
                        Theme.of(context).colorScheme.primary,
                        Icons.location_on,
                        label: stop.name),
                ],
              ),
            for (var i = 0; i < stops.length; i++)
              ListTile(
                leading: CircleAvatar(radius: 14, child: Text('${i + 1}')),
                title: Text(stops[i].name),
                subtitle: Text(
                    '${stops[i].position.latitude.toStringAsFixed(4)}, ${stops[i].position.longitude.toStringAsFixed(4)}'),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}

class DriversPage extends StatelessWidget {
  const DriversPage({super.key});
  @override
  Widget build(BuildContext context) => ListPage(
        title: 'Drivers',
        collection: 'drivers',
        rows: const [],
        addLabel: 'Add driver',
        onAdd: (c) => showDialog<void>(
          context: c,
          builder: (_) => const _DriverDialog(),
        ),
      );
}

class _DriverDialog extends StatefulWidget {
  const _DriverDialog({this.record});
  final FirestoreRecord? record;

  @override
  State<_DriverDialog> createState() => _DriverDialogState();
}

class _DriverDialogState extends State<_DriverDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _nic;
  String? _busId;
  String? _routeId;
  bool _enabled = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final data = widget.record?.data ?? const <String, dynamic>{};
    _name = TextEditingController(text: data['name']?.toString() ?? '');
    _phone = TextEditingController(text: data['phone']?.toString() ?? '');
    _email =
        TextEditingController(text: data['contactEmail']?.toString() ?? '');
    _nic = TextEditingController();
    _busId = data['busId']?.toString();
    _routeId = data['routeId']?.toString();
    _enabled = data['enabled'] != false;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _nic.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final phone = canonicalPhone(_phone.text);
    final nic = normalizeNic(_nic.text);
    if (fullNameError(_name.text) != null ||
        phone == null ||
        (widget.record == null && nic == null) ||
        (widget.record != null && _nic.text.trim().isNotEmpty && nic == null)) {
      snack(context,
          nicError(_nic.text) ?? 'Enter a valid name and phone number.',
          error: true);
      return;
    }
    if (!await confirmAction(
      context,
      title: widget.record == null ? 'Create driver?' : 'Save driver edits?',
      message:
          'The driver account, bus assignment, and personal details will be updated.',
    )) {
      return;
    }
    setState(() => _saving = true);
    try {
      if (widget.record == null) {
        await callWithFreshSession(
            'createManagedUser',
            {
              'displayName': _name.text.trim(),
              'phone': phone,
              'email': _email.text.trim(),
              'role': 'driver',
              if (nic != null) 'nic': nic,
              if (_busId != null) 'busId': _busId,
              if (_routeId != null) 'routeId': _routeId,
            },
            true,
            false);
      } else {
        await callWithFreshSession('updateManagedUser', {
          'uid': widget.record!.id,
          'displayName': _name.text.trim(),
          'phone': phone,
          'email': _email.text.trim(),
          'nic': nic,
          'busId': _busId ?? '',
          'routeId': _routeId ?? '',
          'enabled': _enabled,
        });
      }
      if (_routeId != null &&
          _routeId!.isNotEmpty &&
          _busId != null &&
          _busId!.isNotEmpty) {
        await FirebaseFirestore.instance.collection('routes').doc(_routeId).set(
          {'busId': _busId, 'updatedAt': FieldValue.serverTimestamp()},
          SetOptions(merge: true),
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) snackError(context, error, prefix: 'Unable to save driver');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title:
            Text(widget.record == null ? 'Add driver' : 'Edit driver details'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name')),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration:
                    const InputDecoration(labelText: 'Telephone / login phone'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration:
                    const InputDecoration(labelText: 'Email (optional)'),
              ),
              const SizedBox(height: 12),
              TextField(
                  controller: _nic,
                  inputFormatters: [NicInputFormatter()],
                  decoration: const InputDecoration(labelText: 'NIC number')),
              const SizedBox(height: 12),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('buses')
                    .orderBy('plate')
                    .snapshots(),
                builder: (context, snapshot) {
                  final buses = snapshot.data?.docs ?? const [];
                  final selectedBusId =
                      buses.any((bus) => bus.id == _busId) ? _busId : null;
                  return DropdownButtonFormField<String>(
                    value: selectedBusId,
                    isExpanded: true,
                    decoration:
                        const InputDecoration(labelText: 'Assigned bus'),
                    items: [
                      const DropdownMenuItem(
                          value: '', child: Text('No bus assigned')),
                      for (final bus in buses)
                        DropdownMenuItem(
                          value: bus.id,
                          child: Text(bus.data()['plate']?.toString() ??
                              'Bus unavailable'),
                        ),
                    ],
                    onChanged: (value) => setState(() => _busId = value),
                  );
                },
              ),
              const SizedBox(height: 12),
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('routes')
                    .orderBy('name')
                    .snapshots(),
                builder: (context, snapshot) {
                  final routes = (snapshot.data?.docs ?? const [])
                      .where((route) => isActiveRouteData(route.data()))
                      .toList();
                  final selectedRouteId =
                      routes.any((route) => route.id == _routeId)
                          ? _routeId
                          : null;
                  return DropdownButtonFormField<String>(
                    value: selectedRouteId,
                    isExpanded: true,
                    decoration:
                        const InputDecoration(labelText: 'Assigned route'),
                    items: [
                      const DropdownMenuItem(
                          value: '', child: Text('No route assigned')),
                      for (final route in routes)
                        DropdownMenuItem(
                          value: route.id,
                          child: Text(
                              route.data()['name']?.toString() ?? route.id),
                        ),
                    ],
                    onChanged: (value) => setState(() => _routeId = value),
                  );
                },
              ),
              if (widget.record != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Account enabled'),
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving...' : 'Save')),
        ],
      );
}

class ParentsPage extends StatelessWidget {
  const ParentsPage({super.key});
  @override
  Widget build(BuildContext context) => ListPage(
        title: 'Parents',
        collection: 'parents',
        rows: const [],
        addLabel: 'Add parent',
        onAdd: (c) => simpleForm(c, 'Add parent', [
          'Full name',
          'Phone (login)',
          'NIC number',
          'Email (optional)',
        ]),
      );
}

class _ParentDialog extends StatefulWidget {
  const _ParentDialog({required this.record});
  final FirestoreRecord record;

  @override
  State<_ParentDialog> createState() => _ParentDialogState();
}

class _ParentDialogState extends State<_ParentDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  final _nic = TextEditingController();
  bool _enabled = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final data = widget.record.data;
    _name = TextEditingController(
        text: data['fullName']?.toString() ?? data['name']?.toString() ?? '');
    _phone = TextEditingController(text: data['phone']?.toString() ?? '');
    _email =
        TextEditingController(text: data['contactEmail']?.toString() ?? '');
    _enabled = data['enabled'] != false;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _nic.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final phone = canonicalPhone(_phone.text);
    final nic = normalizeNic(_nic.text);
    if (fullNameError(_name.text) != null ||
        phone == null ||
        (_nic.text.trim().isNotEmpty && nic == null)) {
      snack(context,
          nicError(_nic.text) ?? 'Enter a valid name and phone number.',
          error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await callWithFreshSession('updateManagedUser', {
        'uid': widget.record.id,
        'displayName': sanitizeText(_name.text, collapseSpaces: true),
        'phone': phone,
        'email': _email.text.trim(),
        if (nic != null) 'nic': nic,
        'enabled': _enabled,
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) snackError(context, error, prefix: 'Unable to save parent');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Edit parent'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name')),
            const SizedBox(height: 12),
            TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number')),
            const SizedBox(height: 12),
            TextField(
                controller: _nic,
                obscureText: true,
                inputFormatters: [NicInputFormatter()],
                decoration:
                    const InputDecoration(labelText: 'Change NIC / password')),
            const SizedBox(height: 12),
            TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration:
                    const InputDecoration(labelText: 'Email (optional)')),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Account enabled'),
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _saving ? null : _save, child: const Text('Save')),
        ],
      );
}

class StudentsPage extends StatefulWidget {
  const StudentsPage({super.key});
  @override
  State<StudentsPage> createState() => _StudentsPageState();
}

class _StudentsPageState extends State<StudentsPage> {
  @override
  Widget build(BuildContext context) => ListPage(
        title: 'Students',
        collection: 'students',
        rows: const [],
        addLabel: 'Add student',
        onAdd: (c) async {
          await Navigator.of(c).push(MaterialPageRoute(
              builder: (_) => const AddStudentForm(driverMode: false)));
          if (mounted) setState(() {});
        },
      );
}

class CardsPage extends StatelessWidget {
  const CardsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => const _NewCardDialog(),
          ),
          icon: const Icon(Icons.add_card),
          label: const Text('New card'),
        ),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('cards').snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                  child: const Text('Unable to load cards. Please retry.'));
            }
            final cards = (snapshot.data?.docs ?? const [])
                .where((card) => card.data()['deleted'] != true)
                .toList();
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('RFID cards',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                if (cards.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.inbox_outlined),
                    title: Text('No cards yet'),
                  ),
                for (final card in cards)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    child: ListTile(
                      leading: const Icon(Icons.credit_card),
                      title: Text(card.data()['cardNumber']?.toString() ??
                          'Unnumbered card'),
                      subtitle: Text(
                          'UID: ${card.data()['cardUid'] ?? card.id} • ${card.data()['status'] ?? 'unknown'}'),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _CardDetailsDialog(card: card),
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) async {
                          if (action == 'Disable') {
                            if (!await confirmAction(context,
                                title: 'Disable card?',
                                message:
                                    'This card will remain visible but cannot be assigned or used.')) {
                              return;
                            }
                            try {
                              await FirebaseFirestore.instance
                                  .collection('cards')
                                  .doc(card.id)
                                  .update({
                                'status': 'disabled',
                                'enabled': false,
                                'updatedAt': FieldValue.serverTimestamp(),
                              });
                              if (context.mounted) {
                                snack(context, 'Card disabled');
                              }
                            } catch (error) {
                              if (context.mounted) {
                                snackError(context, error,
                                    prefix: 'Unable to disable card');
                              }
                            }
                          } else if (action == 'Edit') {
                            final value = await showDialog<String>(
                              context: context,
                              builder: (_) => _CardNumberDialog(
                                value:
                                    card.data()['cardNumber']?.toString() ?? '',
                              ),
                            );
                            if (value != null && value.trim().isNotEmpty) {
                              if (!await confirmAction(context,
                                  title: 'Update card number?',
                                  message:
                                      'Save the new printed number for this card?')) {
                                return;
                              }
                              try {
                                await FirebaseFirestore.instance
                                    .collection('cards')
                                    .doc(card.id)
                                    .update({
                                  'cardNumber':
                                      formatRideGuardCardNumber(value),
                                  'updatedAt': FieldValue.serverTimestamp(),
                                });
                                if (context.mounted) {
                                  snack(context, 'Card updated');
                                }
                              } catch (error) {
                                if (context.mounted) {
                                  snackError(context, error,
                                      prefix: 'Unable to update card');
                                }
                              }
                            }
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'Edit', child: Text('Edit')),
                          PopupMenuItem(
                              value: 'Disable', child: Text('Disable')),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      );
}

class _NewCardDialog extends StatefulWidget {
  const _NewCardDialog();

  @override
  State<_NewCardDialog> createState() => _NewCardDialogState();
}

class _NewCardDialogState extends State<_NewCardDialog> {
  final _form = GlobalKey<FormState>();
  final _printedNumber = TextEditingController();
  final _reader = RideReaderService.shared;
  StreamSubscription<RideReaderTap>? _tapSubscription;
  StreamSubscription<String>? _readerStatusSubscription;
  StreamSubscription<RideReaderConnectionState>? _readerStateSubscription;
  List<ScanResult> _devices = const [];
  String? _pendingCode;
  String? _pendingPrintedNumber;
  String? _error;
  RideReaderFailure? _readerFailure;
  String _readerStatus = 'Connect a reader, then enter the printed number.';
  RideReaderConnectionState _readerState =
      RideReaderConnectionState.disconnected;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tapSubscription = _reader.taps.listen(_handleTap);
    _readerStatusSubscription = _reader.statuses.listen(_handleReaderStatus);
    _readerStateSubscription = _reader.connectionStates.listen((state) {
      if (mounted) setState(() => _readerState = state);
    });
  }

  Future<void> _scan() async {
    try {
      setState(() {
        _error = null;
        _readerFailure = null;
        _devices = const [];
      });
      await _reader.scan();
      if (mounted) {
        setState(() => _readerState = _reader.state);
      }
    } catch (error) {
      final failure = mapRideReaderError(error);
      if (mounted)
        setState(() {
          _readerFailure = failure;
          _error = failure.message;
        });
    }
  }

  Future<void> _connect(ScanResult result) async {
    try {
      await _reader.connect(result.device);
      if (mounted) {
        setState(() {
          _readerState = _reader.state;
          _error = null;
        });
        snack(context, 'Reader connected. Enter the printed number to begin.');
      }
    } catch (error) {
      final failure = mapRideReaderError(error);
      if (mounted)
        setState(() {
          _readerFailure = failure;
          _error = failure.message;
        });
    }
  }

  void _handleTap(RideReaderTap tap) {
    if (!mounted) return;
    _reader.acknowledge(tap.sequence).catchError((error) {
      if (mounted) {
        setState(() => _error = 'Reader acknowledgement failed. Try again.');
      }
    });
  }

  void _handleReaderStatus(String status) {
    if (!mounted) return;
    const failures = {
      'ENROLL_AUTH_FAILED': 'The card could not be authenticated.',
      'ENROLL_WRITE_FAILED':
          'The card write failed. Use a blank compatible card.',
      'ENROLL_VERIFY_FAILED':
          'Read-back verification failed. Do not use this card.',
      'ENROLL_INVALID_CODE': 'The reader rejected the registration code.',
      'ENROLL_TIMEOUT': 'No card was detected within 30 seconds.',
    };
    if (status == 'ENROLL_READY') {
      setState(
          () => _readerStatus = 'Registration armed. Tap one blank card once.');
    } else if (status == 'ENROLL_WRITING') {
      setState(() => _readerStatus = 'Card detected. Writing the code...');
    } else if (status.startsWith('ENROLL_SUCCESS:')) {
      final code = status.substring('ENROLL_SUCCESS:'.length);
      if (code == _pendingCode) _commitCard(code);
    } else if (failures.containsKey(status)) {
      setState(() {
        _error = failures[status];
        _readerStatus = 'Registration failed. Arm it again for another card.';
        _saving = false;
      });
    }
  }

  String _newCardCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(16, (_) => alphabet[random.nextInt(alphabet.length)])
        .join();
  }

  Future<void> _commitCard(String code) async {
    final printedNumber = _pendingPrintedNumber;
    if (printedNumber == null || _pendingCode != code) return;
    try {
      await FirebaseFirestore.instance.collection('cards').doc(code).set({
        'cardUid': code,
        'cardCode': code,
        'cardNumber': printedNumber,
        'status': 'available',
        'enabled': true,
        'deleted': false,
        'createdBy': FirebaseAuth.instance.currentUser?.uid,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        snack(context, 'Card written and verified successfully.');
        _printedNumber.clear();
        _pendingCode = null;
        _pendingPrintedNumber = null;
        setState(() {
          _saving = false;
          _readerStatus = 'Ready for the next blank card.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'The card was verified, but could not be saved.';
        });
      }
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_readerState != RideReaderConnectionState.connected) {
      setState(
          () => _error = 'Connect the Ride Reader before registering a card.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final printedNumber = formatRideGuardCardNumber(_printedNumber.text);
      if (!await confirmAction(context,
          title: 'Add RFID card?',
          message:
              'Prepare this card for later assignment to a student or passenger.')) {
        if (mounted) setState(() => _saving = false);
        return;
      }
      final duplicate = await FirebaseFirestore.instance
          .collection('cards')
          .where('cardNumber', isEqualTo: printedNumber)
          .limit(1)
          .get();
      if (duplicate.docs.isNotEmpty) {
        throw StateError('That printed card number is already registered.');
      }
      final code = _newCardCode();
      final duplicateCode = await FirebaseFirestore.instance
          .collection('cards')
          .where('cardUid', isEqualTo: code)
          .limit(1)
          .get();
      if (duplicateCode.docs.isNotEmpty) {
        throw StateError('A registration code collision occurred. Try again.');
      }
      _pendingCode = code;
      _pendingPrintedNumber = printedNumber;
      setState(() => _readerStatus = 'Arming registration on the reader...');
      await _reader.armCardEnrollment(code);
    } catch (error) {
      if (mounted) {
        developer.log('Unable to arm card registration',
            name: 'rideguard.card', error: error);
        setState(() {
          _saving = false;
          _pendingCode = null;
          _pendingPrintedNumber = null;
          _error = friendlyErrorMessage(error);
        });
      }
    }
  }

  @override
  void dispose() {
    _printedNumber.dispose();
    _tapSubscription?.cancel();
    _readerStatusSubscription?.cancel();
    _readerStateSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add new RFID card'),
        content: SizedBox(
          width: 460,
          child: StreamBuilder<List<ScanResult>>(
            stream: _reader.discoveredDevices,
            initialData: _devices,
            builder: (context, snapshot) {
              final devices = snapshot.data ?? const [];
              return Form(
                key: _form,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: _printedNumber,
                        maxLength: 11,
                        inputFormatters: [RideGuardCardNumberFormatter()],
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Printed card number',
                          helperText: 'Enter exactly 8 letters or digits.',
                        ),
                        validator: (value) =>
                            value != null && isRideGuardCardId(value)
                                ? null
                                : 'Enter an 8-character printed number',
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _readerState ==
                                      RideReaderConnectionState.connected
                                  ? _readerStatus
                                  : 'Connect any reader module, then scan',
                            ),
                          ),
                          SizedBox(
                            width: 112,
                            child: OutlinedButton.icon(
                              onPressed: _readerState ==
                                      RideReaderConnectionState.scanning
                                  ? null
                                  : _scan,
                              icon: const Icon(Icons.bluetooth_searching),
                              label: const Text('Scan'),
                            ),
                          ),
                        ],
                      ),
                      for (final result in devices)
                        ListTile(
                          dense: true,
                          title: Text(rideReaderDisplayName(result),
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(result.device.remoteId.str,
                              overflow: TextOverflow.ellipsis),
                          trailing: SizedBox(
                            width: 84,
                            child: TextButton(
                              onPressed: () => _connect(result),
                              child: const Text('Connect'),
                            ),
                          ),
                        ),
                      if (_readerState == RideReaderConnectionState.connected)
                        ListTile(
                          leading: const Icon(Icons.nfc),
                          title: Text(_readerStatus),
                          subtitle: const Text(
                              'Only one card is written after successful read-back verification.'),
                        ),
                      if (_error != null)
                        ListTile(
                          leading: const Icon(Icons.error_outline),
                          title: Text(_error!),
                          trailing: _readerFailure?.kind ==
                                  RideReaderFailureKind.bluetoothOff
                              ? TextButton(
                                  onPressed: FlutterBluePlus.turnOn,
                                  child: const Text('Turn on Bluetooth'),
                                )
                              : _readerFailure?.kind ==
                                      RideReaderFailureKind.permissionDenied
                                  ? TextButton(
                                      onPressed: () =>
                                          RideGuardPermissionService()
                                              .openSettings(),
                                      child: const Text('App settings'),
                                    )
                                  : _readerFailure?.kind ==
                                          RideReaderFailureKind.locationOff
                                      ? TextButton(
                                          onPressed:
                                              Geolocator.openLocationSettings,
                                          child:
                                              const Text('Location settings'),
                                        )
                                      : null,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Add card'),
          ),
        ],
      );
}

class _CardDetailsDialog extends StatelessWidget {
  const _CardDetailsDialog({required this.card});
  final QueryDocumentSnapshot<Map<String, dynamic>> card;

  @override
  Widget build(BuildContext context) {
    final data = card.data();
    final studentId = data['studentId']?.toString();
    return AlertDialog(
      title: const Text('Card details'),
      content: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: studentId == null
            ? null
            : FirebaseFirestore.instance
                .collection('students')
                .doc(studentId)
                .get(),
        builder: (context, snapshot) {
          final student = snapshot.data?.data();
          return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Card number: ${data['cardNumber'] ?? 'Not assigned'}'),
                const SizedBox(height: 8),
                Text('Card UID: ${data['cardUid'] ?? card.id}'),
                const SizedBox(height: 8),
                Text('Status: ${data['status'] ?? 'unknown'}'),
                const Divider(),
                Text(student == null
                    ? 'Student: Not assigned'
                    : 'Student: ${student['name'] ?? studentId}\nAdmission: ${student['admissionNumber'] ?? '—'}'),
              ]);
        },
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}

class _CardNumberDialog extends StatefulWidget {
  const _CardNumberDialog({required this.value});
  final String value;

  @override
  State<_CardNumberDialog> createState() => _CardNumberDialogState();
}

class _CardNumberDialogState extends State<_CardNumberDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Edit card number'),
        content: TextField(
          controller: _controller,
          maxLength: 11,
          inputFormatters: [RideGuardCardNumberFormatter()],
          decoration: const InputDecoration(labelText: 'Card number'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _controller.text),
              child: const Text('Save')),
        ],
      );
}

/// Clean, de-duplicated student details. Internal ids and flags are hidden and
/// bus / route / school ids are shown as readable names.
class _StudentDetailsDialog extends StatefulWidget {
  const _StudentDetailsDialog({
    required this.record,
    required this.onEdit,
    required this.onDelete,
  });
  final FirestoreRecord record;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_StudentDetailsDialog> createState() => _StudentDetailsDialogState();
}

class _StudentDetailsDialogState extends State<_StudentDetailsDialog> {
  late final Future<({String? bus, String? route, String? school})> _lookups =
      _loadLookups(widget.record.data);

  static String _text(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty && value != 'null') return value;
    }
    return '';
  }

  static String _capitalize(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  static LatLng? _pin(Map<String, dynamic> data, String prefix) {
    final lat = data['${prefix}Lat'];
    final lng = data['${prefix}Lng'];
    if (lat is num && lng is num) return LatLng(lat.toDouble(), lng.toDouble());
    return null;
  }

  static String _pointLabel(Map<String, dynamic> data, String prefix) {
    final name = _text(data, ['${prefix}Stop', '${prefix}Location']);
    if (name.isNotEmpty && !name.startsWith('Map:')) return name;
    return _pin(data, prefix) != null ? 'Pinned on map' : 'Not set';
  }

  Future<({String? bus, String? route, String? school})> _loadLookups(
      Map<String, dynamic> data) async {
    final cache = RideGuardCacheService.instance;
    String? bus;
    String? routeName;
    String? school;
    try {
      final busId = _text(data, ['busId']);
      if (busId.isNotEmpty) {
        final busData = (await cache.doc('buses', busId))?.data();
        bus = busData?['plate']?.toString() ?? busData?['name']?.toString();
      }
      final schoolId = _text(data, ['schoolId']);
      final routeId = _text(data, ['routeId']);
      if (routeId.isNotEmpty) {
        final routes = await cache.collection('routes');
        final routeDoc = routes.where((item) => item.id == routeId).firstOrNull;
        if (routeDoc != null) {
          final route = BusRoute.fromDocument(routeDoc);
          routeName = route.name;
          if (schoolId.startsWith('stop:')) {
            for (final stop in route.stops) {
              if ('stop:${route.id}:${stop.order}' == schoolId) {
                school = stop.name;
                break;
              }
            }
          }
        }
      }
      if (school == null &&
          schoolId.isNotEmpty &&
          !schoolId.startsWith('stop:')) {
        school =
            (await cache.doc('schools', schoolId))?.data()?['name']?.toString();
      }
    } catch (error) {
      developer.log('Student lookups failed',
          name: 'rideguard.student', error: error);
    }
    return (bus: bus, route: routeName, school: school);
  }

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _row(BuildContext context, String label, String? value) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Text(value, style: theme.textTheme.bodyLarge),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.record.data;
    final name = _text(data, ['name', 'fullName']);
    final pickupPin = _pin(data, 'pickup');
    final dropPin = _pin(data, 'drop');
    final cardNumber = _text(data, ['cardNumber']);
    return AlertDialog(
      title: Text(name.isEmpty ? 'Student' : name),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: FutureBuilder<({String? bus, String? route, String? school})>(
            future: _lookups,
            builder: (context, snapshot) {
              final lookups = snapshot.data;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _section(context, 'Student'),
                  _row(context, 'Admission number',
                      _text(data, ['admissionNumber'])),
                  _row(context, 'Grade', _text(data, ['grade'])),
                  _row(context, 'Gender', _text(data, ['gender'])),
                  _row(context, 'Status', _capitalize(_text(data, ['status']))),
                  _section(context, 'Transport'),
                  _row(context, 'Bus', lookups?.bus),
                  _row(context, 'Route', lookups?.route),
                  _row(context, 'School', lookups?.school),
                  _row(context, 'Pickup', _pointLabel(data, 'pickup')),
                  _row(context, 'Drop', _pointLabel(data, 'drop')),
                  if (pickupPin != null || dropPin != null) ...[
                    const SizedBox(height: 8),
                    RealMap(
                      height: 180,
                      initialCenter: dropPin ?? pickupPin,
                      markers: [
                        if (pickupPin != null)
                          MapMarker(pickupPin, Colors.green, Icons.location_on,
                              label: 'Pickup'),
                        if (dropPin != null)
                          MapMarker(dropPin, Colors.red, Icons.location_on,
                              label: 'Drop'),
                      ],
                    ),
                    const Text('© OpenStreetMap contributors'),
                  ],
                  _section(context, 'Parent'),
                  _row(context, 'Name', _text(data, ['parentName'])),
                  _section(context, 'Card'),
                  _row(context, 'Card number',
                      cardNumber.isEmpty ? 'No card assigned' : cardNumber),
                ],
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.onDelete,
          child: Text('Delete',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
        TextButton(onPressed: widget.onEdit, child: const Text('Edit')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Full-screen student editor. Pickup and drop each use ONE method at a time:
/// either a stop/school from the route list or a pin on the map (same method
/// as the Add Student form). Picking one replaces the other.
class _StudentEditPage extends StatefulWidget {
  const _StudentEditPage({required this.record});
  final FirestoreRecord record;

  @override
  State<_StudentEditPage> createState() => _StudentEditPageState();
}

class _StudentEditPageState extends State<_StudentEditPage> {
  static const _keep = 'keep';
  static const _map = 'map';

  late final TextEditingController _name;
  late final String? _originalRouteId =
      widget.record.data['routeId']?.toString();
  late final String? _originalBusId = widget.record.data['busId']?.toString();
  String? _grade;
  String? _status;
  String? _cardUid;
  String? _cardNumber;
  String? _routeId;
  String? _busId;
  List<Map<String, dynamic>> _cards = const [];
  List<BusRoute> _routes = const [];
  List<Map<String, dynamic>> _allSchools = const [];
  List<Map<String, dynamic>> _buses = const [];
  List<String> _stopNames = const [];
  List<Map<String, dynamic>> _schools = const [];
  Map<String, LatLng> _stopPositions = const {};
  Map<String, LatLng> _schoolPositions = const {};

  String? _pickupChoice, _pickupName;
  String? _dropChoice, _dropName;
  LatLng? _pickupPin, _dropPin;
  bool _editingDrop = false;

  String _coordinateLabel(LatLng point) =>
      'Map: ${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';

  @override
  void initState() {
    super.initState();
    final data = widget.record.data;
    _name = TextEditingController(text: data['name']?.toString() ?? '');
    _grade = data['grade']?.toString();
    _status = data['status']?.toString() ?? 'active';
    _cardUid = data['cardUid']?.toString();
    _cardNumber = data['cardNumber']?.toString();
    _routeId = _originalRouteId;
    _busId = _originalBusId;
    _pickupName = _firstText(data, ['pickupStop', 'pickupLocation']);
    _dropName = _firstText(data, ['dropStop', 'dropLocation']);
    _pickupPin = _pinOf(data, 'pickup');
    _dropPin = _pinOf(data, 'drop');
    _pickupChoice = _initialChoice(_pickupName, _pickupPin);
    _dropChoice = _initialChoice(_dropName, _dropPin);
    _loadOptions();
  }

  // A point is a "map pin" only when it was picked on the map; stops and
  // schools also store coordinates now, but they stay list selections.
  static String? _initialChoice(String? name, LatLng? pin) {
    if (name == null) return pin != null ? _map : null;
    if (pin != null && name.startsWith('Map:')) return _map;
    return _keep;
  }

  static String? _firstText(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static LatLng? _pinOf(Map<String, dynamic> data, String prefix) {
    final lat = data['${prefix}Lat'];
    final lng = data['${prefix}Lng'];
    if (lat is num && lng is num) return LatLng(lat.toDouble(), lng.toDouble());
    return null;
  }

  /// Fills the stop / school lists (and their coordinates) for a route.
  void _applyRoute(String? routeId) {
    final route = _routes.where((r) => r.id == routeId).firstOrNull;
    final stopPositions = <String, LatLng>{};
    final schools = <Map<String, dynamic>>[];
    final schoolPositions = <String, LatLng>{};
    if (route != null) {
      for (final stop in route.stops) {
        stopPositions[stop.name] = stop.position;
        if (stop.isSchool) {
          final id = 'stop:${route.id}:${stop.order}';
          schools.add({'id': id, 'name': stop.name});
          schoolPositions[id] = stop.position;
        }
      }
    }
    for (final school in _allSchools) {
      if (school['routeId']?.toString() != routeId) continue;
      final id = school['id'].toString();
      schools.add({'id': id, 'name': school['name']?.toString() ?? 'School'});
      final lat = school['lat'];
      final lng = school['lng'];
      if (lat is num && lng is num) {
        schoolPositions[id] = LatLng(lat.toDouble(), lng.toDouble());
      }
    }
    _stopNames = route?.stops.map((stop) => stop.name).toList() ?? const [];
    _stopPositions = stopPositions;
    _schools = schools;
    _schoolPositions = schoolPositions;
  }

  LatLng? _positionOf(String? choice) {
    if (choice == null) return null;
    if (choice.startsWith('stop:')) {
      return _stopPositions[choice.substring('stop:'.length)];
    }
    if (choice.startsWith('school:')) {
      return _schoolPositions[choice.substring('school:'.length)];
    }
    return null;
  }

  LatLng? get _pickupPoint => _pickupChoice == _map || _pickupChoice == _keep
      ? _pickupPin
      : _positionOf(_pickupChoice);

  LatLng? get _dropPoint => _dropChoice == _map || _dropChoice == _keep
      ? _dropPin
      : _positionOf(_dropChoice);

  Future<void> _loadOptions() async {
    try {
      final cache = RideGuardCacheService.instance;
      // Cards must be current (delta read = only changed cards are billed).
      final results = await Future.wait([
        cache.collection('cards', delta: true, forceRefresh: true),
        cache.collection('routes'),
        cache.collection('schools'),
        cache.collection('buses'),
      ]);
      final buses = <Map<String, dynamic>>[
        for (final bus in results[3])
          if (isActiveRouteData(bus.data()))
            {
              'id': bus.id,
              'plate': bus.data()['plate']?.toString() ??
                  bus.data()['Number plate']?.toString() ??
                  'Bus',
            },
      ]..sort((a, b) => a['plate'].toString().compareTo(b['plate'].toString()));
      if (!mounted) return;
      setState(() {
        _cards = [
          for (final card in results[0])
            if (card.data()['status'] == 'available' || card.id == _cardUid)
              {'id': card.id, ...card.data()},
        ];
        _routes = [
          for (final route in results[1])
            if (isActiveRouteData(route.data())) BusRoute.fromDocument(route),
        ];
        _allSchools = [
          for (final school in results[2]) {'id': school.id, ...school.data()},
        ];
        _buses = buses;
        _applyRoute(_routeId);
        // Map the saved names onto list entries so they show as selected.
        if (_pickupChoice == _keep && _stopNames.contains(_pickupName)) {
          _pickupChoice = 'stop:$_pickupName';
        }
        if (_dropChoice == _keep) {
          final school =
              _schools.where((s) => s['name'] == _dropName).firstOrNull;
          if (school != null) {
            _dropChoice = 'school:${school['id']}';
          } else if (_stopNames.contains(_dropName)) {
            _dropChoice = 'stop:$_dropName';
          }
        }
      });
    } catch (error) {
      if (mounted) snackError(context, error, prefix: 'Unable to load options');
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _onRouteChanged(String? value) {
    if (value == null || value == _routeId) return;
    final route = _routes.where((r) => r.id == value).firstOrNull;
    setState(() {
      _routeId = value;
      _applyRoute(value);
      // The new route has other stops: choose pickup and drop again.
      _pickupChoice = null;
      _pickupName = null;
      _pickupPin = null;
      _dropChoice = null;
      _dropName = null;
      _dropPin = null;
      if (route?.busId != null && route!.busId!.isNotEmpty) {
        _busId = route.busId;
      }
    });
    snack(
        context, 'Route changed: choose the pickup and drop for the new route.',
        warn: true);
  }

  void _onPickupChoice(String? value) {
    if (value == null) return;
    setState(() {
      _pickupChoice = value;
      if (value.startsWith('stop:')) {
        _pickupName = value.substring('stop:'.length);
        _pickupPin = null; // one method only: stop replaces the map pin
      }
    });
  }

  void _onDropChoice(String? value) {
    if (value == null) return;
    setState(() {
      _dropChoice = value;
      if (value.startsWith('school:')) {
        final id = value.substring('school:'.length);
        _dropName = _schools
            .where((s) => s['id'] == id)
            .firstOrNull?['name']
            ?.toString();
        _dropPin = null;
      } else if (value.startsWith('stop:')) {
        _dropName = value.substring('stop:'.length);
        _dropPin = null;
      }
    });
  }

  void _onMapTap(LatLng point) => setState(() {
        if (_editingDrop) {
          _dropPin = point;
          _dropName = _coordinateLabel(point);
          _dropChoice = _map; // map replaces the stop/school choice
        } else {
          _pickupPin = point;
          _pickupName = _coordinateLabel(point);
          _pickupChoice = _map;
        }
      });

  /// Name + coordinates of a changed point (null = leave it as it is).
  /// Stops and schools save their coordinates too, so the parent app can
  /// always draw the point.
  Map<String, dynamic>? _pointResult(
      String? choice, String? name, LatLng? pin) {
    if (choice == null || choice == _keep || name == null) return null;
    final point = choice == _map ? pin : _positionOf(choice);
    return {'name': name, 'lat': point?.latitude, 'lng': point?.longitude};
  }

  void _save() {
    final name = _name.text.trim();
    if (name.length < 2) {
      snack(context, 'Enter the student name.', error: true);
      return;
    }
    final routeChanged = _routeId != _originalRouteId;
    if (routeChanged &&
        (_pickupChoice == null ||
            _pickupChoice == _keep ||
            _dropChoice == null ||
            _dropChoice == _keep)) {
      snack(context, 'Choose the pickup and drop for the new route.',
          error: true);
      return;
    }
    Navigator.pop(context, {
      'name': name,
      'grade': _grade ?? 'Grade 1',
      'status': _status ?? 'active',
      'cardUid': _cardUid,
      'cardNumber': _cardNumber,
      'pickup': _pointResult(_pickupChoice, _pickupName, _pickupPin),
      'drop': _pointResult(_dropChoice, _dropName, _dropPin),
      'routeChanged': routeChanged,
      'routeId': _routeId,
      'busChanged': _busId != _originalBusId,
      'busId': _busId,
      'schoolId': (_dropChoice?.startsWith('school:') ?? false)
          ? _dropChoice!.substring('school:'.length)
          : null,
    });
  }

  List<DropdownMenuItem<String>> _pickupItems() => [
        if (_pickupChoice == _map)
          const DropdownMenuItem(value: _map, child: Text('Pinned on map')),
        if (_pickupChoice == _keep)
          DropdownMenuItem(
              value: _keep,
              child: Text('Current: $_pickupName',
                  overflow: TextOverflow.ellipsis)),
        for (final stop in _stopNames)
          DropdownMenuItem(
              value: 'stop:$stop',
              child: Text(stop, overflow: TextOverflow.ellipsis)),
      ];

  List<DropdownMenuItem<String>> _dropItems() => [
        if (_dropChoice == _map)
          const DropdownMenuItem(value: _map, child: Text('Pinned on map')),
        if (_dropChoice == _keep)
          DropdownMenuItem(
              value: _keep,
              child:
                  Text('Current: $_dropName', overflow: TextOverflow.ellipsis)),
        for (final school in _schools)
          DropdownMenuItem(
              value: 'school:${school['id']}',
              child: Text('School: ${school['name']}',
                  overflow: TextOverflow.ellipsis)),
        for (final stop in _stopNames)
          DropdownMenuItem(
              value: 'stop:$stop',
              child: Text(stop, overflow: TextOverflow.ellipsis)),
      ];

  @override
  Widget build(BuildContext context) {
    final pickupPoint = _pickupPoint;
    final dropPoint = _dropPoint;
    final target = _editingDrop ? dropPoint : pickupPoint;
    final routeKnown = _routeId != null && _routes.any((r) => r.id == _routeId);
    final busKnown = _busId != null && _buses.any((b) => b['id'] == _busId);
    return Scaffold(
      appBar: AppBar(title: const Text('Edit student')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Student name'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _grade,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Grade'),
            items: [
              for (var grade = 1; grade <= 13; grade++)
                DropdownMenuItem(
                    value: 'Grade $grade', child: Text('Grade $grade')),
            ],
            onChanged: (value) => setState(() => _grade = value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _cardUid,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Assigned card'),
            items: [
              const DropdownMenuItem<String>(
                  value: null, child: Text('No card')),
              for (final card in _cards)
                DropdownMenuItem(
                  value: card['id']?.toString(),
                  child: Text(card['cardNumber']?.toString() ?? 'Unknown'),
                ),
            ],
            onChanged: (value) {
              final card = _cards
                  .where((item) => item['id']?.toString() == value)
                  .firstOrNull;
              setState(() {
                _cardUid = value;
                _cardNumber = card?['cardNumber']?.toString();
              });
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _status,
            decoration: const InputDecoration(labelText: 'Status'),
            items: const [
              DropdownMenuItem(value: 'active', child: Text('Active')),
              DropdownMenuItem(
                  value: 'adult passenger', child: Text('Adult passenger')),
              DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
            ],
            onChanged: (value) => setState(() => _status = value),
          ),
          const SizedBox(height: 24),
          Text('Route and bus', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('route$_routeId${_routes.length}'),
            value: routeKnown ? _routeId : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Route',
              helperText: _routeId != _originalRouteId
                  ? 'Pickup and drop must be chosen again for the new route.'
                  : null,
            ),
            items: [
              for (final route in _routes)
                DropdownMenuItem(
                    value: route.id,
                    child: Text(route.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: _onRouteChanged,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('bus$_busId${_buses.length}'),
            value: busKnown ? _busId : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Bus number'),
            items: [
              for (final bus in _buses)
                DropdownMenuItem(
                    value: bus['id'].toString(),
                    child: Text(bus['plate'].toString(),
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (value) => setState(() => _busId = value),
          ),
          const SizedBox(height: 24),
          Text('Pickup and drop',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'For each point choose a route stop from the list OR tap the map. '
            'The last choice replaces the other.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('pickup$_pickupChoice${_stopNames.length}$_routeId'),
            isExpanded: true,
            value: _pickupChoice,
            decoration: const InputDecoration(labelText: 'Pickup stop'),
            items: _pickupItems(),
            onChanged: _onPickupChoice,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('drop$_dropChoice${_stopNames.length}$_routeId'),
            isExpanded: true,
            value: _dropChoice,
            decoration: const InputDecoration(labelText: 'Drop stop'),
            items: _dropItems(),
            onChanged: _onDropChoice,
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Pickup map')),
              ButtonSegment(value: true, label: Text('Drop map')),
            ],
            selected: {_editingDrop},
            onSelectionChanged: (value) =>
                setState(() => _editingDrop = value.first),
          ),
          const SizedBox(height: 8),
          RealMap(
            key: ValueKey('map$_editingDrop$_routeId'),
            height: 260,
            initialCenter: target ?? dropPoint ?? pickupPoint,
            markers: [
              if (pickupPoint != null)
                MapMarker(pickupPoint, Colors.green, Icons.location_on,
                    label: 'Pickup'),
              if (dropPoint != null)
                MapMarker(dropPoint, Colors.red, Icons.location_on,
                    label: 'Drop'),
            ],
            onTap: _onMapTap,
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(height: 8),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
        ]),
      ),
    );
  }
}

class _InfoRow {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;
}

class _InfoData {
  const _InfoData({
    required this.title,
    required this.rows,
    this.mapPoint,
    this.mapLabel,
  });
  final String title;
  final List<_InfoRow> rows;
  final LatLng? mapPoint;
  final String? mapLabel;
}

bool _isLiveRecord(Map<String, dynamic> data) =>
    data['deleted'] != true &&
    data['enabled'] != false &&
    data['disabled'] != true;

String? _formatDateTime(dynamic value) {
  DateTime? date;
  if (value is Timestamp) {
    date = value.toDate();
  } else if (value is num && value > 0) {
    date = DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  if (date == null) return null;
  final local = date.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final suffix = local.hour >= 12 ? 'PM' : 'AM';
  return '${local.day} ${months[local.month - 1]} ${local.year}, $hour:$minute $suffix';
}

Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _cachedDocs(
    String name) async {
  try {
    return (await RideGuardCacheService.instance.collection(name)).toList();
  } catch (_) {
    return const [];
  }
}

/// Readable summary of a bus, parent or device (no raw fields or IDs).
Future<_InfoData> _loadInfo(String collection, FirestoreRecord record) async {
  final data = record.data;
  String text(List<String> keys) {
    for (final key in keys) {
      final value = data[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return '';
  }

  final rows = <_InfoRow>[];
  void add(String label, String? value) {
    if (value != null && value.trim().isNotEmpty) {
      rows.add(_InfoRow(label, value.trim()));
    }
  }

  final status = _isLiveRecord(data) ? 'Active' : 'Disabled';

  if (collection == 'buses') {
    final plate = text(['plate', 'Number plate', 'name']);
    final capacity = data['capacity'] ?? data['Capacity'];
    add('Number plate', plate);
    if (capacity != null && '$capacity'.trim().isNotEmpty) {
      add('Capacity', '$capacity seats');
    }
    add('Status', status);
    final routes = [
      for (final route in await _cachedDocs('routes'))
        if (route.data()['busId']?.toString() == record.id &&
            isActiveRouteData(route.data()))
          route.data()['name']?.toString() ?? '',
    ].where((name) => name.isNotEmpty).toList();
    add('Route', routes.join(', '));
    final devices = [
      for (final device in await _cachedDocs('devices'))
        if (device.data()['busId']?.toString() == record.id &&
            isActiveRouteData(device.data()))
          device.data()['deviceId']?.toString() ?? '',
    ].where((name) => name.isNotEmpty).toList();
    add('Reader device', devices.join(', '));
    final students = (await _cachedDocs('students')).where((student) =>
        student.data()['busId']?.toString() == record.id &&
        student.data()['deleted'] != true);
    add('Students', students.isEmpty ? 'None assigned' : '${students.length}');
    add('Last GPS update',
        _formatDateTime(data['gpsFixAt'] ?? data['updatedAt']));
    final speed = data['speed'];
    if (speed is num && data['gpsFixAt'] != null) {
      add('Last speed', '${(speed * 3.6).round()} km/h');
    }
    final lat = data['lat'];
    final lng = data['lng'];
    return _InfoData(
      title: plate.isEmpty ? 'Bus' : plate,
      rows: rows,
      mapPoint: lat is num && lng is num
          ? LatLng(lat.toDouble(), lng.toDouble())
          : null,
      mapLabel: plate,
    );
  }

  if (collection == 'parents') {
    final name = text(['fullName', 'name']);
    add('Phone', text(['phone']));
    add('Email', text(['email']));
    add('NIC', text(['nic']));
    add('Status', status);
    final children = [
      for (final student in await _cachedDocs('students'))
        if (student.data()['deleted'] != true &&
            (student.data()['parentId']?.toString() == record.id ||
                (student.data()['parentIds'] is List &&
                    (student.data()['parentIds'] as List)
                        .map((id) => id.toString())
                        .contains(record.id))))
          [
            student.data()['name']?.toString() ?? 'Student',
            student.data()['grade']?.toString() ?? '',
          ].where((part) => part.isNotEmpty).join(' - '),
    ];
    add('Children', children.isEmpty ? 'None linked' : children.join('\n'));
    add('Added on', _formatDateTime(data['createdAt']));
    final by = text(['createdBy']);
    if (by.isNotEmpty) {
      String? creator;
      try {
        final user = await RideGuardCacheService.instance.doc('users', by);
        final userData = user?.data();
        creator = (userData?['fullName'] ??
                userData?['name'] ??
                userData?['displayName'])
            ?.toString();
      } catch (_) {}
      add('Added by', creator ?? 'Administrator');
    }
    return _InfoData(title: name.isEmpty ? 'Parent' : name, rows: rows);
  }

  // devices
  final code = text(['deviceId', 'name']);
  add('Device code', code);
  var busLabel = text(['busPlate']);
  final busId = text(['busId']);
  if (busLabel.isEmpty && busId.isNotEmpty) {
    try {
      final bus = await RideGuardCacheService.instance.doc('buses', busId);
      busLabel = bus?.data()?['plate']?.toString() ?? '';
    } catch (_) {}
  }
  add('Bus', busLabel.isEmpty ? 'Not assigned' : busLabel);
  add('Status', status);
  add('Added on', _formatDateTime(data['createdAt']));
  return _InfoData(title: code.isEmpty ? 'Device' : code, rows: rows);
}

class _InfoDetailsDialog extends StatelessWidget {
  const _InfoDetailsDialog({
    required this.loader,
    required this.onEdit,
    required this.onDelete,
  });
  final Future<_InfoData> loader;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<_InfoData>(
      future: loader,
      builder: (context, snapshot) {
        final info = snapshot.data;
        return AlertDialog(
          title: Text(info?.title ?? 'Details'),
          content: SizedBox(
            width: 420,
            child: info == null
                ? SizedBox(
                    height: 80,
                    child: Center(
                      child: snapshot.hasError
                          ? const Text('Unable to load details.')
                          : const CircularProgressIndicator(),
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final row in info.rows)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(row.label,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                            color: theme
                                                .colorScheme.onSurfaceVariant)),
                                const SizedBox(height: 2),
                                Text(row.value),
                              ],
                            ),
                          ),
                        if (info.mapPoint != null) ...[
                          const SizedBox(height: 4),
                          Text('Last known location',
                              style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                          const SizedBox(height: 6),
                          RealMap(
                            height: 180,
                            initialCenter: info.mapPoint,
                            markers: [
                              MapMarker(info.mapPoint!, Colors.green,
                                  Icons.directions_bus,
                                  label: info.mapLabel ?? 'Bus'),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: onDelete,
              child: Text('Delete',
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
            TextButton(onPressed: onEdit, child: const Text('Edit')),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

class _BusEditDialog extends StatefulWidget {
  const _BusEditDialog({required this.record});
  final FirestoreRecord record;

  @override
  State<_BusEditDialog> createState() => _BusEditDialogState();
}

class _BusEditDialogState extends State<_BusEditDialog> {
  late final TextEditingController _plate;
  late final TextEditingController _capacity;

  @override
  void initState() {
    super.initState();
    final data = widget.record.data;
    _plate = TextEditingController(
        text: (data['plate'] ?? data['Number plate'] ?? '').toString());
    _capacity = TextEditingController(
        text: (data['capacity'] ?? data['Capacity'] ?? '').toString());
  }

  @override
  void dispose() {
    _plate.dispose();
    _capacity.dispose();
    super.dispose();
  }

  void _save() {
    final plate = _plate.text.trim().toUpperCase();
    if (plate.length < 3) {
      snack(context, 'Enter the bus number plate.', error: true);
      return;
    }
    final capacityText = _capacity.text.trim();
    final capacity = int.tryParse(capacityText);
    if (capacityText.isNotEmpty && (capacity == null || capacity <= 0)) {
      snack(context, 'Capacity must be a positive number.', error: true);
      return;
    }
    Navigator.pop(context, {'plate': plate, 'capacity': capacity});
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
            'Edit bus ${_plate.text.trim().isEmpty ? '' : _plate.text.trim()}'
                .trim()),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: _plate,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Number plate'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _capacity,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Capacity (seats)'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
        ],
      );
}

class _DeviceEditDialog extends StatefulWidget {
  const _DeviceEditDialog({required this.record});
  final FirestoreRecord record;

  @override
  State<_DeviceEditDialog> createState() => _DeviceEditDialogState();
}

class _DeviceEditDialogState extends State<_DeviceEditDialog> {
  late final TextEditingController _code;
  String? _busId;
  List<Map<String, String>> _buses = const [];

  @override
  void initState() {
    super.initState();
    final data = widget.record.data;
    _code = TextEditingController(text: data['deviceId']?.toString() ?? '');
    _busId = data['busId']?.toString();
    _loadBuses();
  }

  Future<void> _loadBuses() async {
    final docs = await _cachedDocs('buses');
    final buses = [
      for (final bus in docs)
        if (isActiveRouteData(bus.data()))
          {
            'id': bus.id,
            'plate': bus.data()['plate']?.toString() ??
                bus.data()['Number plate']?.toString() ??
                'Bus',
          },
    ]..sort((a, b) => a['plate']!.compareTo(b['plate']!));
    if (mounted) setState(() => _buses = buses);
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _save() {
    final code = _code.text.trim();
    if (code.isEmpty || _busId == null) {
      snack(context, 'Enter a device code and select a bus.', error: true);
      return;
    }
    final plate =
        _buses.where((bus) => bus['id'] == _busId).firstOrNull?['plate'];
    Navigator.pop(context, {
      'deviceId': code,
      'busId': _busId,
      'busPlate': plate,
    });
  }

  @override
  Widget build(BuildContext context) {
    final known = _busId != null && _buses.any((bus) => bus['id'] == _busId);
    return AlertDialog(
      title: Text('Edit device ${widget.record.data['deviceId'] ?? ''}'.trim()),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _code,
            decoration: const InputDecoration(labelText: 'Device code'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('bus$_busId${_buses.length}'),
            isExpanded: true,
            value: known ? _busId : null,
            decoration: const InputDecoration(labelText: 'Bus number'),
            items: [
              for (final bus in _buses)
                DropdownMenuItem(
                    value: bus['id'],
                    child:
                        Text(bus['plate']!, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (value) => setState(() => _busId = value),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _StopEditDialog extends StatefulWidget {
  const _StopEditDialog({
    required this.number,
    required this.name,
    required this.isSchool,
  });
  final int number;
  final String name;
  final bool isSchool;

  @override
  State<_StopEditDialog> createState() => _StopEditDialogState();
}

class _StopEditDialogState extends State<_StopEditDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.name);
  late bool _isSchool = widget.isSchool;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Destination ${widget.number}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Destination name'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('This location is a school'),
            value: _isSchool,
            onChanged: (value) => setState(() => _isSchool = value ?? false),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final name = _controller.text.trim();
              if (name.isEmpty) {
                snack(context, 'Enter a destination name.', error: true);
                return;
              }
              Navigator.pop(context, {'name': name, 'isSchool': _isSchool});
            },
            child: const Text('Save'),
          ),
        ],
      );
}

class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  Widget _card(BuildContext c, String title, Widget child) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: Theme.of(c)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            child,
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final end = DateTime.now();
    final start = DateTime(end.year, end.month, end.day);
    final report = FirebaseFunctions.instance
        .httpsCallable('getAttendanceReport')
        .call<Map<String, dynamic>>({
      'startMillis': start.millisecondsSinceEpoch,
      'endMillis': end.millisecondsSinceEpoch,
    });
    return FutureBuilder<HttpsCallableResult<Map<String, dynamic>>>(
      future: report,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
              child: const Text('Unable to load report. Please retry.'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final counts = Map<String, dynamic>.from(
          snapshot.data!.data['counts'] as Map? ?? const {},
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Reports', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            _card(
              context,
              'Daily attendance events',
              counts.isEmpty
                  ? const Text('No attendance events were recorded today.')
                  : DataTable(
                      columns: const [
                        DataColumn(label: Text('Student')),
                        DataColumn(label: Text('Tap events')),
                      ],
                      rows: [
                        for (final entry in counts.entries)
                          DataRow(cells: [
                            DataCell(Text(entry.key)),
                            DataCell(Text('${entry.value}')),
                          ]),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class AuditPage extends StatelessWidget {
  const AuditPage({super.key});
  @override
  Widget build(BuildContext context) => const ListPage(
        title: 'Audit log',
        collection: 'auditLogs',
        rows: [],
      );
}
