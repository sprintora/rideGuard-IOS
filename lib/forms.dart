import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:latlong2/latlong.dart';

import 'app_models.dart';
import 'widgets.dart';
import 'route_repository.dart';
import 'ride_reader_service.dart';
import 'core/input_rules.dart';
import 'auth_repository.dart';
import 'cache_service.dart';

String normalizeRideGuardCardNumber(String value) =>
    value.replaceAll('-', '').trim().toUpperCase();

String formatRideGuardCardNumber(String value) {
  final normalized = normalizeRideGuardCardNumber(value);
  if (normalized.length != 8) return normalized;
  return [
    normalized.substring(0, 2),
    normalized.substring(2, 4),
    normalized.substring(4, 6),
    normalized.substring(6, 8),
  ].join('-');
}

bool isRideGuardCardId(String value) =>
    RegExp(r'^[A-Z0-9]{8}$').hasMatch(normalizeRideGuardCardNumber(value));

class RideGuardCardNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalized = normalizeRideGuardCardNumber(newValue.text);
    final limited =
        normalized.length > 8 ? normalized.substring(0, 8) : normalized;
    final formatted = formatRideGuardCardNumber(limited);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class _NewParentDialog extends StatefulWidget {
  const _NewParentDialog();

  @override
  State<_NewParentDialog> createState() => _NewParentDialogState();
}

class _NewParentDialogState extends State<_NewParentDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _nic = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _nic.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add new parent'),
        content: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                  controller: _name,
                  decoration:
                      const InputDecoration(labelText: 'Parent full name'),
                  validator: (v) => v == null ? 'Required' : fullNameError(v)),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone (login)'),
                  validator: (v) =>
                      v == null ? 'Enter a valid phone' : phoneError(v)),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration:
                      const InputDecoration(labelText: 'Email (optional)'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? null : emailError(v)),
              const SizedBox(height: 12),
              TextFormField(
                  controller: _nic,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [NicInputFormatter()],
                  decoration: const InputDecoration(labelText: 'NIC number'),
                  validator: (v) => v == null ? nicError('') : nicError(v)),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (!_form.currentState!.validate()) return;
              Navigator.pop(context, {
                'name': _name.text.trim(),
                'phone': _phone.text.trim(),
                'email': _email.text.trim(),
                'nic': _nic.text.trim(),
              });
            },
            child: const Text('Create account'),
          ),
        ],
      );
}

/// One Add Student form shared by Admin and Driver.
class AddStudentForm extends StatefulWidget {
  const AddStudentForm({super.key, required this.driverMode});
  final bool driverMode;

  @override
  State<AddStudentForm> createState() => _AddStudentFormState();
}

class _AddStudentFormState extends State<AddStudentForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _adm = TextEditingController();
  final _emergency = TextEditingController();
  final _notes = TextEditingController();
  final _parentCtrl = TextEditingController();
  final _cardUid = TextEditingController();
  final _cardNumber = TextEditingController();
  String? _parent, _parentId, _grade, _gender, _route, _school, _pickup, _drop;
  String? _pickupChoice, _dropChoice;
  String? _selectedCardId;
  String? _bus;
  String _status = 'Active';
  DateTime? _dob;
  LatLng? _pickupLocation;
  LatLng? _dropLocation;
  bool _selectingDropLocation = true;
  final List<String> _parents = [];
  final Map<String, String> _parentIds = {};
  List<Map<String, dynamic>> _availableCards = const [];
  List<Map<String, dynamic>> _schools = const [];
  List<BusRoute> _routes = const [];
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _buses = const [];

  String _mapSelection(LatLng point) =>
      'map:${point.latitude.toStringAsFixed(6)},${point.longitude.toStringAsFixed(6)}';

  String _coordinateLabel(LatLng point) =>
      'Map: ${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';

  @override
  void initState() {
    super.initState();
    _loadParents();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    // Served from the shared cache: no repeat reads while the data is fresh.
    final cache = RideGuardCacheService.instance;
    final results = await Future.wait([
      cache.collection('routes'),
      cache.collection('buses'),
      cache.collection('cards', delta: true, forceRefresh: true),
      cache.collection('schools'),
    ]);
    final routes = results[0];
    final buses = results[1];
    final cards = results[2];
    final schools = results[3];
    final uid = FirebaseAuth.instance.currentUser?.uid;
    String? assignedBus;
    if (widget.driverMode && uid != null) {
      final user = await cache.doc('users', uid);
      assignedBus = user?.data()?['busId']?.toString();
    }
    if (!mounted) return;
    setState(() {
      _routes = routes
          .where((route) => isActiveRouteData(route.data()))
          .map(BusRoute.fromDocument)
          .toList();
      _buses = buses;
      _availableCards = cards
          .where((card) =>
              card.data()['status'] == 'available' &&
              card.data()['deleted'] != true &&
              card.data()['enabled'] != false)
          .map((card) => {'id': card.id, ...card.data()})
          .toList();
      _schools =
          schools.map((school) => {'id': school.id, ...school.data()}).toList();
      _bus = assignedBus ?? (_buses.isNotEmpty ? _buses.first.id : null);
    });
  }

  Future<void> _loadParents() async {
    final parents = await RideGuardCacheService.instance.collection('parents');
    if (!mounted) return;
    setState(() {
      _parents
        ..clear()
        ..addAll([
          for (final document in parents)
            document.data()['fullName']?.toString() ??
                document.data()['name']?.toString() ??
                'Unnamed parent',
        ]);
      for (final document in parents) {
        _parentIds[document.data()['fullName']?.toString() ??
            document.data()['name']?.toString() ??
            'Unnamed parent'] = document.id;
      }
    });
  }

  List<String> get _stops {
    BusRoute? route;
    for (final item in _routes) {
      if (item.id == _route) {
        route = item;
        break;
      }
    }
    return route?.stops.map((stop) => stop.name).toList() ?? const [];
  }

  List<Map<String, dynamic>> get _routeSchools {
    final existing = _schools
        .where((school) => school['routeId']?.toString() == _route)
        .toList();
    final route = _routes.where((item) => item.id == _route).firstOrNull;
    if (route == null) return existing;
    return [
      ...existing,
      for (final stop in route.stops)
        if (stop.isSchool)
          {
            'id': 'stop:${route.id}:${stop.order}',
            'name': stop.name,
            'lat': stop.position.latitude,
            'lng': stop.position.longitude,
          },
    ];
  }

  String get _selectedBusLabel {
    for (final bus in _buses) {
      if (bus.id == _bus) {
        return bus.data()['plate']?.toString() ?? 'Bus unavailable';
      }
    }
    return _bus ?? 'No bus assigned';
  }

  Future<void> _newParent() async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _NewParentDialog(),
    );
    if (values != null && mounted) {
      try {
        final result = await callWithFreshSession('createParentAccount', {
          'fullName': sanitizeText(values['name']!, collapseSpaces: true),
          'phone': canonicalPhone(values['phone']!) ?? values['phone'],
          'nic': normalizeNic(values['nic']!) ?? values['nic']!.trim(),
          if (values['email']!.trim().isNotEmpty)
            'email': values['email']!.trim(),
        });
        final parentId = (result.data as Map?)?['uid']?.toString();
        RideGuardCacheService.instance.invalidate('parents');
        if (!mounted) return;
        setState(() {
          _parents.add(values['name']!);
          _parent = values['name']!;
          _parentId = parentId;
          if (parentId != null) _parentIds[values['name']!] = parentId;
          _parentCtrl.text = values['name']!;
        });
        snack(
            context,
            parentId == null
                ? 'Parent account created.'
                : 'Parent account created.');
      } on FirebaseFunctionsException catch (error) {
        if (mounted)
          snackError(context, error, prefix: 'Unable to create parent');
      }
    }
  }

  Future<void> _save() async {
    try {
      await _saveInternal();
    } catch (error) {
      if (mounted) snackError(context, error, prefix: 'Unable to save student');
    }
  }

  Future<void> _saveInternal() async {
    if (!_form.currentState!.validate()) return;
    if (_parent == null) {
      snack(context, 'Select or add a parent first.', error: true);
      return;
    }
    if (_bus == null || _route == null || _school == null) {
      snack(context, 'Select an assigned bus, route, and school first.',
          error: true);
      return;
    }
    if (_cardUid.text.trim().isEmpty || !isRideGuardCardId(_cardNumber.text)) {
      snack(context, 'Assign an available card before saving the student.',
          error: true);
      return;
    }
    if (_pickupChoice == null || _dropChoice == null) {
      snack(context, 'Choose both pickup and drop points.', error: true);
      return;
    }
    final s = Student(_name.text.trim(), _adm.text.trim(), _grade ?? '',
        _pickup ?? '', '', _parent!,
        drop: _drop ?? '');
    final duplicate = await FirebaseFirestore.instance
        .collection('students')
        .where('admissionNumber', isEqualTo: s.admission)
        .limit(1)
        .get();
    if (duplicate.docs.isNotEmpty) {
      if (mounted)
        snack(context, 'Admission number already exists.', error: true);
      return;
    }
    if (!await confirmAction(context,
        title: 'Create student?',
        message: 'Save ${s.name} and generate a key card number?')) {
      return;
    }
    final studentRef = FirebaseFirestore.instance.collection('students').doc();
    final parentId = _parentId;
    if (parentId == null || parentId.isEmpty) {
      snack(context, 'Select or add a parent first.', error: true);
      return;
    }
    await studentRef.set({
      'name': s.name,
      'admissionNumber': s.admission,
      'grade': s.grade,
      'gender': _gender,
      'pickupStop': s.stop,
      'dropStop': s.drop,
      'parentName': s.parent,
      'parentId': parentId,
      'parentIds': [parentId],
      'busId': _bus,
      'routeId': _route,
      'schoolId': _school,
      'status': _status.toLowerCase(),
      'cardStatus': 'assigned',
      'cardUid': _cardUid.text.trim(),
      'cardNumber': formatRideGuardCardNumber(_cardNumber.text),
      'pickupLocation': _pickup,
      'dropLocation': _drop,
      if (_pickupLocation != null) ...{
        'pickupLat': _pickupLocation!.latitude,
        'pickupLng': _pickupLocation!.longitude,
      },
      if (_dropLocation != null) ...{
        'dropLat': _dropLocation!.latitude,
        'dropLng': _dropLocation!.longitude,
      },
      'createdBy': FirebaseAuth.instance.currentUser?.uid,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'enabled': true,
      'deleted': false,
    });
    if (!widget.driverMode) {
      await Future.wait([
        FirebaseFirestore.instance.collection('routes').doc(_route!).set({
          'parentIds': FieldValue.arrayUnion([parentId]),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)),
        FirebaseFirestore.instance.collection('buses').doc(_bus!).set({
          'parentIds': FieldValue.arrayUnion([parentId]),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true)),
      ]);
    }
    if (_selectedCardId != null) {
      await FirebaseFirestore.instance
          .collection('cards')
          .doc(_selectedCardId)
          .set({
        'studentId': studentRef.id,
        'busId': _bus,
        'status': 'active',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
    final cache = RideGuardCacheService.instance;
    cache.invalidate('cards');
    if (!widget.driverMode) {
      cache.invalidate('routes');
      cache.invalidate('buses');
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _name.dispose();
    _adm.dispose();
    _emergency.dispose();
    _notes.dispose();
    _parentCtrl.dispose();
    _cardUid.dispose();
    _cardNumber.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title:
              Text(widget.driverMode ? 'Add student (driver)' : 'Add student')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('Parent', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Autocomplete<String>(
              optionsBuilder: (v) => _parents
                  .where((p) => p.toLowerCase().contains(v.text.toLowerCase())),
              onSelected: (v) => setState(() {
                _parent = v;
                _parentId = _parentIds[v];
              }),
              fieldViewBuilder: (ctx, ctrl, focus, _) => TextField(
                controller: ctrl,
                focusNode: focus,
                decoration: InputDecoration(
                  labelText: 'Select parent (search)',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _parent != null
                      ? const Icon(Icons.check_circle, color: Colors.green)
                      : null,
                ),
                onChanged: (_) {
                  _parent = null;
                  _parentId = null;
                },
              ),
            ),
            if (_parent != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text('Selected parent: $_parent')),
                ]),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
                onPressed: _newParent,
                icon: const Icon(Icons.person_add),
                label: const Text('Add new parent')),
            const SizedBox(height: 24),
            Text('Student', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: (v) =>
                    (v == null || v.trim().length < 2) ? 'Required' : null),
            const SizedBox(height: 12),
            TextFormField(
              controller: _adm,
              decoration: const InputDecoration(labelText: 'Admission number'),
              validator: (v) {
                final t = (v ?? '').trim();
                if (t.isEmpty) return 'Required';
                return null;
              },
            ),
            const SizedBox(height: 12),
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _cardNumber.text),
              optionsBuilder: (value) => _availableCards
                  .map((card) => card['cardNumber']?.toString() ?? '')
                  .where((number) =>
                      number.toLowerCase().contains(value.text.toLowerCase())),
              onSelected: (value) => setState(() {
                final card = _availableCards.firstWhere(
                    (item) =>
                        formatRideGuardCardNumber(
                            item['cardNumber']?.toString() ?? '') ==
                        formatRideGuardCardNumber(value),
                    orElse: () => const {});
                _selectedCardId = card['id']?.toString();
                _cardNumber.text = value;
                _cardUid.text = card['cardUid']?.toString() ?? '';
              }),
              fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  maxLength: 11,
                  inputFormatters: [RideGuardCardNumberFormatter()],
                  onChanged: (value) {
                    _cardNumber.text = value;
                    _cardUid.clear();
                  },
                  decoration: const InputDecoration(
                    labelText: 'Printed card number (8 characters)',
                    helperText:
                        'Search and select an available printed card number.',
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Grade and class'),
              items: [
                for (final g in [
                  'Grade 1',
                  'Grade 2',
                  'Grade 3',
                  'Grade 4',
                  'Grade 5',
                  'Grade 6',
                  'Grade 7',
                  'Grade 8',
                  'Grade 9',
                  'Grade 10',
                  'Grade 11',
                  'Grade 12',
                  'Grade 13',
                ])
                  DropdownMenuItem(value: g, child: Text(g))
              ],
              onChanged: (v) => _grade = v,
              validator: (v) => v == null ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final d = await showDatePicker(
                    context: context,
                    initialDate: DateTime(2016),
                    firstDate: DateTime(2005),
                    lastDate: DateTime.now());
                if (d != null) setState(() => _dob = d);
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                    labelText: 'Date of birth',
                    suffixIcon: Icon(Icons.calendar_today)),
                child: Text(_dob == null
                    ? 'Select date'
                    : '${_dob!.day}/${_dob!.month}/${_dob!.year}'),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Gender'),
              items: [
                for (final g in ['Female', 'Male'])
                  DropdownMenuItem(value: g, child: Text(g))
              ],
              onChanged: (v) => _gender = v,
              validator: (v) => v == null ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            widget.driverMode
                ? InputDecorator(
                    decoration: const InputDecoration(labelText: 'Bus'),
                    child: Text(_selectedBusLabel))
                : DropdownButtonFormField<String>(
                    value: _bus,
                    decoration: const InputDecoration(labelText: 'Bus'),
                    items: [
                      for (final b in _buses)
                        DropdownMenuItem(
                            value: b.id,
                            child: Text(b.data()['plate']?.toString() ??
                                'Bus unavailable'))
                    ],
                    onChanged: (v) => _bus = v ?? _bus,
                    validator: (v) => v == null ? 'Required' : null,
                  ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Route'),
              items: [
                for (final r in _routes)
                  DropdownMenuItem(
                      value: r.id,
                      child: Text(r.name, overflow: TextOverflow.ellipsis))
              ],
              onChanged: (v) => setState(() {
                _route = v;
                _school = null;
                _pickup = null;
                _pickupChoice = null;
                _pickupLocation = null;
                _drop = null;
                _dropChoice = null;
                _dropLocation = null;
              }),
              validator: (v) => v == null ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              value: _school,
              decoration: const InputDecoration(labelText: 'School'),
              items: [
                for (final school in _routeSchools)
                  DropdownMenuItem(
                    value: school['id']?.toString(),
                    child: Text(school['name']?.toString() ?? 'School',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _route == null
                  ? null
                  : (value) => setState(() => _school = value),
              validator: (value) =>
                  value == null ? 'Select a route first' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('pickup$_route'),
              isExpanded: true,
              value: _pickupChoice,
              decoration: const InputDecoration(
                  labelText: 'Pickup stop',
                  helperText: 'Stops come from the selected route'),
              items: [
                if (_pickupLocation != null &&
                    _pickupChoice?.startsWith('map:') == true)
                  DropdownMenuItem(
                    value: _pickupChoice,
                    child: Text(_pickup!, overflow: TextOverflow.ellipsis),
                  ),
                for (final s in _stops)
                  DropdownMenuItem(
                      value: 'stop:$s',
                      child: Text(s, overflow: TextOverflow.ellipsis))
              ],
              onChanged: (v) => setState(() {
                if (v == null) return;
                if (v.startsWith('stop:')) {
                  _pickupChoice = v;
                  _pickup = v.substring('stop:'.length);
                  _pickupLocation = null;
                }
              }),
              validator: (v) => v == null ? 'Choose a pickup location' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('drop$_route'),
              isExpanded: true,
              value: _dropChoice,
              decoration: const InputDecoration(labelText: 'Drop stop'),
              items: [
                if (_dropLocation != null &&
                    _dropChoice?.startsWith('map:') == true)
                  DropdownMenuItem(
                    value: _dropChoice,
                    child: Text(_drop!, overflow: TextOverflow.ellipsis),
                  ),
                for (final school in _routeSchools)
                  DropdownMenuItem(
                    value: 'school:${school['id']}',
                    child: Text('School: ${school['name'] ?? 'School'}',
                        overflow: TextOverflow.ellipsis),
                  ),
                for (final s in _stops)
                  DropdownMenuItem(
                      value: 'stop:$s',
                      child: Text(s, overflow: TextOverflow.ellipsis))
              ],
              onChanged: (v) {
                if (v == null) return;
                _dropChoice = v;
                if (v.startsWith('school:')) {
                  final id = v.substring('school:'.length);
                  final school = _routeSchools
                      .where((item) => item['id']?.toString() == id)
                      .firstOrNull;
                  _drop = school?['name']?.toString();
                  _dropLocation = null;
                } else {
                  _drop = v.substring('stop:'.length);
                  _dropLocation = null;
                }
                setState(() {});
              },
              validator: (v) => v == null ? 'Choose a drop location' : null,
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Pickup map')),
                ButtonSegment(value: true, label: Text('Drop map')),
              ],
              selected: {_selectingDropLocation},
              onSelectionChanged: (value) =>
                  setState(() => _selectingDropLocation = value.first),
            ),
            const SizedBox(height: 8),
            RealMap(
              height: 220,
              initialCenter:
                  _selectingDropLocation ? _dropLocation : _pickupLocation,
              markers: [
                if ((_selectingDropLocation
                        ? _dropLocation
                        : _pickupLocation) !=
                    null)
                  MapMarker(
                    (_selectingDropLocation
                        ? _dropLocation!
                        : _pickupLocation!),
                    Colors.red,
                    Icons.location_on,
                    label: _selectingDropLocation ? 'Drop' : 'Pickup',
                  ),
              ],
              onTap: (point) => setState(() {
                if (_selectingDropLocation) {
                  _dropLocation = point;
                  _drop = _coordinateLabel(point);
                  _dropChoice = _mapSelection(point);
                } else {
                  _pickupLocation = point;
                  _pickup = _coordinateLabel(point);
                  _pickupChoice = _mapSelection(point);
                }
              }),
            ),
            const SizedBox(height: 12),
            TextFormField(
                controller: _emergency,
                keyboardType: TextInputType.phone,
                decoration:
                    const InputDecoration(labelText: 'Emergency contact'),
                validator: (_) => null),
            const SizedBox(height: 12),
            TextFormField(
                controller: _notes,
                maxLines: 2,
                decoration:
                    const InputDecoration(labelText: 'Notes (optional)')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: [
                for (final s in ['Active', 'Adult passenger', 'Inactive'])
                  DropdownMenuItem(value: s, child: Text(s))
              ],
              onChanged: (v) => _status = v ?? _status,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Save student')),
          ]),
        ),
      ),
    );
  }
}

class _IssueCardDialog extends StatefulWidget {
  const _IssueCardDialog({
    required this.student,
    required this.studentId,
    required this.busId,
  });
  final Student student;
  final String studentId;
  final String busId;

  @override
  State<_IssueCardDialog> createState() => _IssueCardDialogState();
}

class _IssueCardDialogState extends State<_IssueCardDialog> {
  int step = 0;
  final _printedNumber = TextEditingController();
  final _reader = RideReaderService();
  StreamSubscription<List<ScanResult>>? _deviceSubscription;
  StreamSubscription<String>? _statusSubscription;
  StreamSubscription<RideReaderConnectionState>? _stateSubscription;
  List<ScanResult> _devices = const [];
  RideReaderConnectionState _readerState =
      RideReaderConnectionState.disconnected;
  String? _pendingCode;
  String? _cardUid;
  String? _error;
  String _status = 'Connect the Ride Reader to begin.';

  @override
  void initState() {
    super.initState();
    _deviceSubscription = _reader.discoveredDevices.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    _statusSubscription = _reader.statuses.listen((status) {
      if (!mounted) return;
      if (status.startsWith('ENROLL_SUCCESS:')) {
        final code = status.substring('ENROLL_SUCCESS:'.length);
        if (code == _pendingCode) _commitCard(code);
      } else if (status == 'ENROLL_READY') {
        setState(() => _status = 'Tap one blank card once.');
      } else if (status == 'ENROLL_WRITING') {
        setState(() => _status = 'Writing and verifying the card...');
      } else if (status.contains('FAILED') || status == 'ENROLL_TIMEOUT') {
        setState(() {
          _error = 'The card could not be written. Try another card.';
          _status = 'Arm registration again to retry.';
          step = 1;
        });
      }
    });
    _stateSubscription = _reader.connectionStates.listen((state) {
      if (mounted) setState(() => _readerState = state);
    });
  }

  @override
  void dispose() {
    _printedNumber.dispose();
    _deviceSubscription?.cancel();
    _statusSubscription?.cancel();
    _stateSubscription?.cancel();
    _reader.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    try {
      setState(() {
        _error = null;
        _status = 'Looking for a Ride Reader...';
      });
      await _reader.scan();
      if (mounted) {
        setState(() {
          _status = 'Select the connected Ride Reader.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = rideReaderUserMessage(error));
    }
  }

  Future<void> _connect(ScanResult result) async {
    try {
      setState(() {
        _error = null;
        _status = 'Connecting to the Ride Reader...';
      });
      await _reader.connect(result.device);
      if (mounted) {
        setState(() {
          step = 1;
          _status = 'Enter the printed card number, then arm registration.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = rideReaderUserMessage(error));
    }
  }

  Future<void> _arm() async {
    final printedNumber = formatRideGuardCardNumber(_printedNumber.text);
    if (!isRideGuardCardId(printedNumber)) {
      setState(() => _error =
          'Printed card number must contain exactly 8 letters or digits.');
      return;
    }
    if (_readerState != RideReaderConnectionState.connected) {
      setState(() => _error = 'Connect the Ride Reader before writing a card.');
      return;
    }
    final alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    final code =
        List.generate(16, (_) => alphabet[random.nextInt(alphabet.length)])
            .join();
    try {
      setState(() {
        _error = null;
        _pendingCode = code;
        _status = 'Arming card registration...';
      });
      await _reader.armCardEnrollment(code);
    } catch (error) {
      if (mounted) setState(() => _error = rideReaderUserMessage(error));
    }
  }

  Future<void> _commitCard(String code) async {
    final printedNumber = formatRideGuardCardNumber(_printedNumber.text);
    try {
      await FirebaseFirestore.instance.collection('cards').doc(code).set({
        'cardUid': code,
        'cardNumber': printedNumber,
        'studentId': widget.studentId,
        'busId': widget.busId,
        'status': 'active',
        'issuedBy': FirebaseAuth.instance.currentUser?.uid,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      await FirebaseFirestore.instance
          .collection('students')
          .doc(widget.studentId)
          .update({
        'cardUid': code,
        'cardNumber': printedNumber,
        'cardStatus': 'active',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      RideGuardCacheService.instance.invalidate('cards');
      if (mounted) {
        setState(() {
          _cardUid = code;
          _pendingCode = null;
          step = 2;
          _status = 'Card written and verified successfully.';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = friendlyErrorMessage(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Issue RFID card'),
      content: switch (step) {
        0 => SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_status),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: Colors.red.shade700)),
              ],
              const SizedBox(height: 12),
              if (_devices.isEmpty)
                FilledButton.tonal(
                  onPressed: _scan,
                  child: const Text('Find Ride Reader'),
                )
              else
                for (final device in _devices)
                  ListTile(
                    title: Text(rideReaderDisplayName(device)),
                    trailing: FilledButton(
                      onPressed: () => _connect(device),
                      child: const Text('Connect'),
                    ),
                  ),
            ]),
          ),
        1 => Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_status),
            const SizedBox(height: 12),
            TextField(
              controller: _printedNumber,
              maxLength: 11,
              inputFormatters: [RideGuardCardNumberFormatter()],
              decoration: const InputDecoration(
                labelText: 'Printed card number',
                hintText: 'Enter the number printed on the card',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Colors.red.shade700)),
            ],
          ]),
        _ => Text('Card ${_cardUid ?? 'unknown'} is now linked to '
            '${widget.student.name}.'),
      },
      actions: [
        if (step < 2)
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
        if (step == 1)
          FilledButton(
            onPressed: _pendingCode == null ? _arm : null,
            child: const Text('Write on card'),
          ),
        if (step == 2)
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done')),
      ],
    );
  }
}
