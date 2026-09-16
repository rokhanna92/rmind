import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Wraps the platform speech recognizer behind a callback API.
///
/// The plugin exposes one long lived recognizer with listeners registered at
/// initialize time, which does not survive a screen being rebuilt. This class
/// owns that single recognizer and re-points the callbacks at whoever called
/// [start] last, so the UI can come and go without re-initializing.
class SpeechService {
  /// Reminders are one or two sentences, so a long ceiling plus a short pause
  /// means the session almost always ends because the user stopped talking.
  static const Duration _listenFor = Duration(seconds: 30);
  static const Duration _pauseFor = Duration(seconds: 3);
  static const String _localeId = 'en_US';

  final SpeechToText _speech = SpeechToText();

  bool _available = false;
  bool _listening = false;
  void Function(String message)? _onError;

  /// True once [init] has confirmed the device actually has a recognizer.
  bool get isAvailable => _available;

  /// Tracked here rather than delegated to the plugin because the plugin only
  /// flips its own flag once the platform reports back, which leaves a window
  /// where a second tap would start a second session.
  bool get isListening => _listening;

  Future<bool> init() async {
    if (_available) {
      return true;
    }
    try {
      _available = await _speech.initialize(
        onError: _handleError,
        onStatus: _handleStatus,
      );
    } on PlatformException {
      _available = false;
    } on MissingPluginException {
      _available = false;
    }
    return _available;
  }

  Future<void> start({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(String message) onError,
  }) async {
    if (!_available) {
      onError('Speech recognition is not available on this device.');
      return;
    }
    if (_listening) {
      return;
    }

    _onError = onError;
    _listening = true;
    try {
      await _speech.listen(
        onResult: (result) {
          if (result.finalResult) {
            _listening = false;
            onFinal(result.recognizedWords);
          } else {
            onPartial(result.recognizedWords);
          }
        },
        listenOptions: SpeechListenOptions(
          localeId: _localeId,
          listenFor: _listenFor,
          pauseFor: _pauseFor,
          partialResults: true,
          cancelOnError: true,
        ),
      );
    } on ListenFailedException catch (e) {
      _listening = false;
      _onError = null;
      onError(e.message ?? 'Could not start listening.');
    } on PlatformException catch (e) {
      // Currently unreachable: listen() wraps channel failures into
      // ListenFailedException. Kept deliberately, because this path cannot be
      // unit tested and the failure mode if the plugin ever stops wrapping is
      // the sheet sitting on "Listening" forever with no way out.
      _listening = false;
      _onError = null;
      onError(e.message ?? 'Could not start listening.');
    }
  }

  /// Ends the session and lets the recognizer deliver its final result.
  Future<void> stop() async {
    if (!_available) {
      return;
    }
    _listening = false;
    _onError = null;
    await _speech.stop();
  }

  /// Ends the session and throws away whatever was recognized.
  Future<void> cancel() async {
    if (!_available) {
      return;
    }
    _listening = false;
    _onError = null;
    await _speech.cancel();
  }

  void _handleStatus(String status) {
    if (status == SpeechToText.doneStatus ||
        status == SpeechToText.notListeningStatus) {
      _listening = false;
    }
  }

  void _handleError(SpeechRecognitionError error) {
    _listening = false;
    _onError?.call(_describe(error));
  }

  /// The plugin passes through raw Android error codes, which are useless in
  /// a dialog, so the ones a user can actually act on get their own wording.
  String _describe(SpeechRecognitionError error) {
    switch (error.errorMsg) {
      case 'error_no_match':
      case 'error_speech_timeout':
        return 'I did not catch that, try again.';
      case 'error_permission':
        return 'Microphone access is needed to record a reminder.';
      case 'error_network':
      case 'error_network_timeout':
        return 'Speech recognition needs a network connection right now.';
      case 'error_busy':
        return 'The recognizer is busy, try again in a moment.';
      case 'error_language_not_supported':
      case 'error_language_unavailable':
        return 'English speech recognition is not installed on this device.';
      default:
        return 'Speech recognition failed - ${error.errorMsg}.';
    }
  }
}
