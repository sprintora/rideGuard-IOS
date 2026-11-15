import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'auth.dart';
import 'auth_repository.dart';
import 'app_models.dart';
import 'shell.dart';
import 'firebase_options.dart';
import 'widgets.dart';
import 'ui_theme.dart';
import 'cache_service.dart';
import 'core/update_service.dart';
import 'ride_reader_queue.dart';
import 'pilot_features.dart';
import 'foreground_trip_service.dart';
import 'notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    developer.log(
      'Unhandled Flutter error',
      name: 'rideguard.global',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    developer.log(
      'Unhandled platform error',
      name: 'rideguard.global',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };
  ErrorWidget.builder = (details) => const Material(
        child: Center(
          child: Text(
              'RideGuard could not display this screen. Please try again.'),
        ),
      );
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await NotificationService.initialize();
  if (Platform.isAndroid) await initializeForegroundTripService();
  await RideGuardCacheService(FirebaseFirestore.instance).initialize();
  await loadThemeMode();
  runZonedGuarded(
    () => runApp(const ProviderScope(child: RideGuardUi())),
    (error, stackTrace) {
      developer.log(
        'Unhandled application error',
        name: 'rideguard.global',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}

class RideGuardUi extends StatelessWidget {
  const RideGuardUi({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (_, mode, __) => MaterialApp(
        title: 'RideGuard',
        debugShowCheckedModeBanner: false,
        theme: RideTheme.light(),
        darkTheme: RideTheme.darkTheme(),
        themeMode: mode,
        home: ExitConfirmation(
          child: PilotFeatures.enableApkUpdates && Platform.isAndroid
              ? const UpdatePrompt(child: AuthStateGate())
              : const AuthStateGate(),
        ),
      ),
    );
  }
}

class ExitConfirmation extends StatefulWidget {
  const ExitConfirmation({super.key, required this.child});

  final Widget child;

  @override
  State<ExitConfirmation> createState() => _ExitConfirmationState();
}

class _ExitConfirmationState extends State<ExitConfirmation> {
  bool _isShowing = false;

  Future<void> _confirmExit() async {
    if (_isShowing || !mounted) return;
    _isShowing = true;
    try {
      final shouldExit = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Exit RideGuard?'),
          content: const Text('Are you sure you want to exit the app?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Exit'),
            ),
          ],
        ),
      );
      if (shouldExit == true) {
        await SystemNavigator.pop();
      }
    } finally {
      _isShowing = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _confirmExit();
        },
        child: widget.child,
      );
}

class UpdatePrompt extends StatefulWidget {
  const UpdatePrompt({super.key, required this.child});
  final Widget child;

  @override
  State<UpdatePrompt> createState() => _UpdatePromptState();
}

class _UpdatePromptState extends State<UpdatePrompt>
    with WidgetsBindingObserver {
  final _service = UpdateService();
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (_checking || !mounted) return;
    _checking = true;
    try {
      final manifest = await _service.check();
      if (!mounted || manifest == null) return;
      final pending = await RideReaderQueue().pendingCount();
      if (Trip.I.active || pending > 0) return;
      await _showUpdate(manifest);
    } finally {
      _checking = false;
    }
  }

  Future<void> _showUpdate(UpdateManifest manifest) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: !manifest.forced,
      builder: (dialogContext) => _UpdateDialog(
        manifest: manifest,
        service: _service,
        onDismiss: manifest.forced
            ? null
            : () async {
                await _service.dismiss(manifest);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({
    required this.manifest,
    required this.service,
    required this.onDismiss,
  });
  final UpdateManifest manifest;
  final UpdateService service;
  final VoidCallback? onDismiss;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await widget.service.download(widget.manifest);
      await widget.service.install(file);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.manifest.forced
            ? 'Required RideGuard update'
            : 'RideGuard update available'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Version ${widget.manifest.versionName}'),
              Text(
                  'Download ${(widget.manifest.apkSizeBytes / 1048576).toStringAsFixed(1)} MB'),
              if (widget.manifest.message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(widget.manifest.message),
              ],
              if (widget.manifest.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final note in widget.manifest.releaseNotes)
                  Text('• $note'),
              ],
              if (_busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('Downloading and verifying update...'),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: Colors.red.shade700)),
              ],
            ],
          ),
        ),
        actions: [
          if (widget.onDismiss != null)
            TextButton(
              onPressed: _busy ? null : widget.onDismiss,
              child: const Text('Later'),
            ),
          FilledButton(
            onPressed: _busy ? null : _install,
            child: Text(_busy ? 'Working...' : 'Install update'),
          ),
        ],
      );
}

class AuthStateGate extends ConsumerWidget {
  const AuthStateGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Stream<User?> authChanges;
    try {
      authChanges = FirebaseAuth.instance.authStateChanges();
    } on FirebaseException {
      return const LoginScreen();
    }
    return StreamBuilder<User?>(
      stream: authChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        final user = snapshot.data;
        if (user == null) return const LoginScreen();
        return FutureBuilder<UserAccess>(
          future: _loadFreshAccess(ref, user),
          builder: (context, accessSnapshot) {
            final access = accessSnapshot.data;
            if (accessSnapshot.hasError) {
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Unable to load your account. Check your connection and try again.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () async {
                            await FirebaseAuth.instance.signOut();
                          },
                          child: const Text('Back to login'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            if (access == null) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            final role = access.hasRole('admin')
                ? Role.admin
                : access.hasRole('driver')
                    ? Role.driver
                    : Role.parent;
            // The iOS build is the driver portal only.
            if (Platform.isIOS && role != Role.driver) {
              return const _DriverOnlyScreen();
            }
            return AppShell(role: role);
          },
        );
      },
    );
  }

  Future<UserAccess> _loadFreshAccess(WidgetRef ref, User user) async {
    await user.getIdToken(true);
    final access = await ref.read(authRepositoryProvider).loadAccess(user);
    await RideGuardCacheService(FirebaseFirestore.instance).warmForUser(
      uid: access.uid,
      roles: access.roles,
    );
    return access;
  }
}

class _DriverOnlyScreen extends StatelessWidget {
  const _DriverOnlyScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.directions_bus, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'The RideGuard iOS app is for drivers only. '
                  'Please use the Android app for this account.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => FirebaseAuth.instance.signOut(),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      );
}
