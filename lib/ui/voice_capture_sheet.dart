import 'package:flutter/material.dart';

import '../services/speech_service.dart';
import 'design.dart';

/// Listens through [speech] and resolves with the final transcript, or null if
/// the user cancelled or nothing was heard.
Future<String?> showVoiceCapture(BuildContext context, SpeechService speech) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: RM.sheet,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(RM.rSheet)),
    ),
    builder: (context) => _VoiceCaptureSheet(speech: speech),
  );
}

/// One full expansion of a mic ring.
const Duration _ringCycle = Duration(milliseconds: 1800);

/// The second ring starts 0.6s into the cycle so the two never overlap.
const double _ringPhase = 600 / 1800;

class _VoiceCaptureSheet extends StatefulWidget {
  const _VoiceCaptureSheet({required this.speech});

  final SpeechService speech;

  @override
  State<_VoiceCaptureSheet> createState() => _VoiceCaptureSheetState();
}

class _VoiceCaptureSheetState extends State<_VoiceCaptureSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  String _text = '';
  String? _error;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: _ringCycle);
    _begin();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  /// The rings are decoration, so they yield to the platform's reduce motion
  /// setting, and there is nothing to drive once the mic is replaced by the
  /// error icon.
  void _syncPulse() {
    final wanted = !MediaQuery.disableAnimationsOf(context) && _error == null;
    if (wanted && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!wanted && _pulse.isAnimating) {
      _pulse.stop();
    }
  }

  Future<void> _begin() async {
    await widget.speech.start(
      onPartial: (text) {
        if (!mounted || _closed) return;
        setState(() => _text = text);
      },
      onFinal: (text) {
        if (!mounted || _closed) return;
        setState(() => _text = text);
        _finish(text);
      },
      onError: (message) {
        if (!mounted || _closed) return;
        setState(() => _error = message);
        _syncPulse();
      },
    );
  }

  /// Guarded because the recogniser can deliver a final result at the same
  /// moment the user taps Done, and popping twice tears down the wrong route.
  void _finish(String text) {
    if (_closed) return;
    _closed = true;
    final trimmed = text.trim();
    Navigator.of(context).pop(trimmed.isEmpty ? null : trimmed);
  }

  Future<void> _stopAndUse() async {
    await widget.speech.stop();
    if (!mounted) return;
    _finish(_text);
  }

  Future<void> _cancel() async {
    await widget.speech.cancel();
    if (!mounted) return;
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    final hasError = error != null;
    final canFinish = !hasError && _text.trim().isNotEmpty;
    final hint = RM.body.copyWith(fontSize: 13, color: RM.inkSoft);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: RM.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: hasError
                ? const SizedBox(
                    height: 120,
                    child: Center(
                      child: Icon(Icons.mic_off, size: 56, color: RM.alarm),
                    ),
                  )
                : _MicPulse(pulse: _pulse),
          ),
          const SizedBox(height: 24),
          // A long transcript is the one thing here that can grow without a
          // ceiling, so it gives way first and scrolls rather than pushing the
          // buttons off the bottom of the sheet.
          Flexible(
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: double.infinity,
                  minHeight: 96,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      hasError
                          ? 'Could not listen'
                          : _text.isEmpty
                              ? 'Say what you need to remember'
                              : _text,
                      textAlign: TextAlign.center,
                      style: hasError || _text.isNotEmpty
                          ? RM.transcript
                          : RM.transcript.copyWith(color: RM.inkSoft),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      hasError
                          ? error
                          // Deliberately no number. The pause length lives in
                          // SpeechService and a figure quoted here would go
                          // stale the moment it is tuned.
                          : 'Listening · take your time, or tap Done',
                      textAlign: TextAlign.center,
                      style: hasError ? hint.copyWith(color: RM.alarm) : hint,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: _cancel,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      foregroundColor: RM.inkMid,
                      textStyle: RM.chip.copyWith(fontSize: 15),
                      side: const BorderSide(color: RM.line),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(26)),
                      ),
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: canFinish ? _stopAndUse : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: RM.accentLight,
                      foregroundColor: RM.onAccentDeep,
                      // Nothing to save yet reads as a spent button rather
                      // than a live one that ignores taps.
                      disabledBackgroundColor: RM.field,
                      disabledForegroundColor: RM.inkSoft,
                      textStyle: RM.button.copyWith(fontSize: 15),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(26)),
                      ),
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Done'),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The mic core with two rings expanding out of it.
class _MicPulse extends StatelessWidget {
  const _MicPulse({required this.pulse});

  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      height: 120,
      child: Stack(
        alignment: Alignment.center,
        // The rings grow past the box on their way out, where they are already
        // almost fully faded.
        clipBehavior: Clip.none,
        children: [
          _PulseRing(pulse: pulse, phase: 0),
          _PulseRing(pulse: pulse, phase: _ringPhase),
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: RM.accent,
            ),
            child: const Icon(Icons.mic, size: 44, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _PulseRing extends StatelessWidget {
  const _PulseRing({required this.pulse, required this.phase});

  final Animation<double> pulse;

  /// Where in the cycle this ring starts, as a fraction of it.
  final double phase;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final t = (pulse.value + phase) % 1;
        return Opacity(
          opacity: 0.5 * (1 - t),
          child: Transform.scale(scale: 1 + 0.9 * t, child: child),
        );
      },
      child: Container(
        width: 96,
        height: 96,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: RM.accent,
        ),
      ),
    );
  }
}
