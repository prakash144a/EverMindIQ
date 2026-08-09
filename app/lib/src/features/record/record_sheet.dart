import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../data/providers.dart';

/// Bottom sheet to record a moment. Defaults to now; the date chip lets the user back-date it.
class RecordSheet extends ConsumerStatefulWidget {
  const RecordSheet({super.key});

  @override
  ConsumerState<RecordSheet> createState() => _RecordSheetState();
}

enum _Phase { idle, recording, saving }

class _RecordSheetState extends ConsumerState<RecordSheet> {
  final _recorder = AudioRecorder();
  _Phase _phase = _Phase.idle;
  DateTime _eventDate = DateTime.now();
  DateTime? _startedAt;
  String? _error;

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Microphone permission denied.');
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voiceiq_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() {
      _phase = _Phase.recording;
      _startedAt = DateTime.now();
    });
  }

  Future<void> _stopAndSave() async {
    final path = await _recorder.stop();
    if (path == null) {
      setState(() => _phase = _Phase.idle);
      return;
    }
    setState(() => _phase = _Phase.saving);
    try {
      final bytes = await File(path).readAsBytes();
      final duration = _startedAt == null
          ? 0.0
          : DateTime.now().difference(_startedAt!).inMilliseconds / 1000.0;
      await ref.read(apiClientProvider).uploadAndCreate(
            audioBytes: bytes,
            contentType: 'audio/m4a',
            durationSec: duration,
            eventDate: _isToday(_eventDate) ? null : _eventDate,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _phase = _Phase.idle;
        _error = 'Could not save: $e';
      });
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _eventDate,
      firstDate: DateTime(1950),
      lastDate: DateTime.now(),
      helpText: 'When did this happen?',
    );
    if (picked != null) setState(() => _eventDate = picked);
  }

  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 8,
        bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _phase == _Phase.recording ? 'Recording…' : 'Capture a moment',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          ActionChip(
            avatar: const Icon(Icons.event, size: 18),
            label: Text(_isToday(_eventDate)
                ? 'Today'
                : DateFormat.yMMMd().format(_eventDate)),
            onPressed: _phase == _Phase.idle ? _pickDate : null,
          ),
          const SizedBox(height: 24),
          _buildControl(context),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _buildControl(BuildContext context) {
    switch (_phase) {
      case _Phase.saving:
        return const Padding(
          padding: EdgeInsets.all(16),
          child: Column(children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Saving & indexing your memory…'),
          ]),
        );
      case _Phase.recording:
        return Column(
          children: [
            FilledButton.icon(
              onPressed: _stopAndSave,
              icon: const Icon(Icons.stop),
              label: const Text('Stop & Save'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                minimumSize: const Size(220, 56),
              ),
            ),
          ],
        );
      case _Phase.idle:
        return FilledButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.mic),
          label: const Text('Start Recording'),
          style: FilledButton.styleFrom(minimumSize: const Size(220, 56)),
        );
    }
  }
}
