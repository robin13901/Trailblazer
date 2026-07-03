import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Stub — real implementation added in Plan 03.
/// Riverpod provider so `lib/app.dart` can `ref.watch(appRouterProvider)`.
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(
          body: Center(child: Text('Auto-Explore')),
        ),
      ),
    ],
  );
});
