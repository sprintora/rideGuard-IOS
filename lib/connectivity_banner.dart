import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

class RideGuardConnectivityBanner extends StatefulWidget {
  const RideGuardConnectivityBanner({super.key, required this.child});

  final Widget child;

  @override
  State<RideGuardConnectivityBanner> createState() =>
      _RideGuardConnectivityBannerState();
}

class _RideGuardConnectivityBannerState
    extends State<RideGuardConnectivityBanner> {
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _offline = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _subscription = Connectivity().onConnectivityChanged.listen(_update);
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _checking = true);
    final results = await Connectivity().checkConnectivity();
    if (!mounted) return;
    _update(results);
  }

  void _update(List<ConnectivityResult> results) {
    if (!mounted) return;
    setState(() {
      _offline = results.isEmpty ||
          results.every((result) => result == ConnectivityResult.none);
      _checking = false;
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_offline && !_checking)
          MaterialBanner(
            leading: const Icon(Icons.cloud_off),
            content: const Text('No internet connection. Showing saved data'),
            actions: [
              TextButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        Expanded(child: widget.child),
      ],
    );
  }
}
