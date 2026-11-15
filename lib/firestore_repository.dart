import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'auth_repository.dart';

final firestoreRepositoryProvider = Provider<FirestoreRepository>((ref) {
  return FirestoreRepository(FirebaseFirestore.instance);
});

final schoolsProvider = StreamProvider<List<FirestoreRecord>>((ref) {
  return ref.watch(firestoreRepositoryProvider).watch('schools');
});
final busesProvider = StreamProvider<List<FirestoreRecord>>((ref) {
  return ref.watch(firestoreRepositoryProvider).watch('buses');
});
final devicesProvider = StreamProvider<List<FirestoreRecord>>((ref) {
  return ref.watch(firestoreRepositoryProvider).watch('devices');
});
final parentsProvider = StreamProvider<List<FirestoreRecord>>((ref) {
  return ref.watch(firestoreRepositoryProvider).watch('parents');
});
final studentsProvider = StreamProvider<List<FirestoreRecord>>((ref) {
  return ref.watch(firestoreRepositoryProvider).watch('students');
});
final cardsProvider = StreamProvider<List<FirestoreRecord>>((ref) {
  return ref.watch(firestoreRepositoryProvider).watch('cards');
});
final notificationsProvider = StreamProvider<List<FirestoreRecord>>((ref) {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  final access = ref.watch(accessProvider).valueOrNull;
  if (uid == null || access == null || !access.hasRole('parent')) {
    return Stream.value(const []);
  }
  return ref.watch(firestoreRepositoryProvider).watch(
        'notifications',
        query: (collection) => collection
            .where('parentId', isEqualTo: uid)
            .orderBy('createdAt', descending: true),
      );
});

class FirestoreRecord {
  const FirestoreRecord(this.id, this.data);
  final String id;
  final Map<String, dynamic> data;

  String text(String key, [String fallback = '']) =>
      data[key]?.toString() ?? fallback;
  String? nullableText(String key) => data[key]?.toString();
}

bool isNotificationUnread(FirestoreRecord notification, String? uid) {
  if (uid == null || uid.isEmpty) return false;
  final readBy = notification.data['readBy'];
  return !(readBy is Map && readBy[uid] != null);
}

String recordName(String collection, FirestoreRecord record) {
  final fields = switch (collection) {
    'buses' => ['plate', 'name'],
    'devices' => ['name', 'deviceCode', 'deviceId'],
    'drivers' => ['fullName', 'name', 'displayName'],
    'parents' => ['fullName', 'name'],
    'students' => ['fullName', 'name'],
    'cards' => ['name', 'cardId', 'uid'],
    _ => ['fullName', 'name'],
  };
  for (final field in fields) {
    final value = record.nullableText(field)?.trim();
    if (value != null && value.isNotEmpty) return value;
  }
  final entity = collection.endsWith('s')
      ? collection.substring(0, collection.length - 1)
      : collection;
  return 'Unnamed $entity';
}

class FirestoreRepository {
  FirestoreRepository(this._firestore);
  final FirebaseFirestore _firestore;

  Stream<List<FirestoreRecord>> watch(
    String collectionName, {
    Query<Map<String, dynamic>> Function(
            CollectionReference<Map<String, dynamic>> collection)?
        query,
  }) {
    final collection = _firestore.collection(collectionName);
    final source = query == null ? collection : query(collection);
    return source.snapshots().map(
          (snapshot) => [
            for (final document in snapshot.docs)
              if (document.data()['deleted'] != true &&
                  document.data()['enabled'] != false)
                FirestoreRecord(document.id, document.data()),
          ],
        );
  }

  Future<String> create(
    String collectionName,
    Map<String, dynamic> data,
  ) async {
    final reference = await _firestore.collection(collectionName).add({
      ...data,
      'enabled': data['enabled'] ?? true,
      'deleted': data['deleted'] ?? false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return reference.id;
  }

  Future<void> update(
    String collectionName,
    String id,
    Map<String, dynamic> data,
  ) {
    return _firestore.collection(collectionName).doc(id).update({
      ...data,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> delete(String collectionName, String id) {
    return _firestore.collection(collectionName).doc(id).update({
      'deleted': true,
      'enabled': false,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }
}
