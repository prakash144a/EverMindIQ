import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One thing that went wrong, kept so the user can attach it to a report.
@immutable
class AppError {
  const AppError({
    required this.at,
    required this.source,
    required this.message,
    this.details = '',
  });

  final DateTime at;

  /// Where it came from — a provider name, 'flutter', or 'uncaught'.
  final String source;
  final String message;

  /// Stack trace or other context. Can be long; trimmed before sending.
  final String details;

  /// The form the backend stores and a human reads in a report.
  String toReport() {
    final buffer = StringBuffer()
      ..writeln('[${at.toIso8601String()}] $source')
      ..writeln(message);
    if (details.isNotEmpty) buffer.writeln(details);
    return buffer.toString().trimRight();
  }
}

/// Ring buffer of recent errors.
///
/// A plain singleton rather than a provider: the global `FlutterError.onError`
/// and `PlatformDispatcher.onError` hooks run outside any `ProviderContainer`,
/// and they are exactly the handlers that catch the crashes worth reporting.
class ErrorLog extends ChangeNotifier {
  ErrorLog._();

  static final ErrorLog instance = ErrorLog._();

  static const _maxEntries = 20;

  /// Repeat of the same failure within this window is treated as one entry —
  /// otherwise a polling provider that keeps failing floods out everything else.
  static const _dedupeWindow = Duration(seconds: 30);

  final List<AppError> _entries = [];

  /// Newest first.
  List<AppError> get entries => List.unmodifiable(_entries.reversed);

  AppError? get latest => _entries.isEmpty ? null : _entries.last;

  bool get isEmpty => _entries.isEmpty;

  void add({required String source, required String message, String details = ''}) {
    final now = DateTime.now();
    final previous = latest;
    if (previous != null &&
        previous.source == source &&
        previous.message == message &&
        now.difference(previous.at) < _dedupeWindow) {
      return;
    }
    _entries.add(AppError(at: now, source: source, message: message, details: details));
    if (_entries.length > _maxEntries) _entries.removeAt(0);
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

/// Records every failed provider — which is how the user-visible
/// "Could not load recordings: …" errors reach the report screen.
class ErrorLoggingObserver extends ProviderObserver {
  @override
  void providerDidFail(
    ProviderBase<Object?> provider,
    Object error,
    StackTrace stackTrace,
    ProviderContainer container,
  ) {
    ErrorLog.instance.add(
      source: provider.name ?? provider.runtimeType.toString(),
      message: '$error',
      details: '$stackTrace',
    );
  }
}
