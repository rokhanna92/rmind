import 'package:flutter/material.dart';

import '../services/api_key_store.dart';
import 'design.dart';

/// Where the user pastes their Gemini key.
///
/// The key is checked against the live API before it is stored, so the screen
/// that accepted it is the screen that tells the user it was wrong. A key saved
/// unchecked would fail later, mid sentence, as an error the user has no way to
/// connect back to what they typed here.
class ApiKeyPage extends StatefulWidget {
  const ApiKeyPage({super.key, required this.store, this.isFirstRun = false});

  final ApiKeyStore store;

  /// True when the app cannot work yet. The page then refuses to be dismissed
  /// until a key is stored, because there is nothing behind it to go back to.
  final bool isFirstRun;

  @override
  State<ApiKeyPage> createState() => _ApiKeyPageState();
}

class _ApiKeyPageState extends State<ApiKeyPage> {
  final TextEditingController _controller = TextEditingController();

  bool _loading = true;
  bool _obscured = true;
  bool _checking = false;
  bool _stored = false;
  ApiKeyCheck? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final key = await widget.store.read();
    if (!mounted) return;
    setState(() {
      if (key != null) _controller.text = key;
      _stored = key != null;
      _loading = false;
    });
  }

  Future<void> _checkAndSave() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _checking = true;
      _result = null;
    });

    var check = await verifyApiKey(key);
    if (check.ok) {
      await widget.store.write(key);
      // The store swallows a dead keystore and reports "no key", so the write
      // proves nothing. Read it back: telling the user the key is saved when
      // it is not drops them into an app that cannot work and gives them
      // nothing to act on.
      if (await widget.store.read() == null) check = _notStored;
    }
    if (!mounted) return;

    setState(() {
      _checking = false;
      _result = check;
      if (check.ok) _stored = true;
    });

    // On first run there is a screen waiting behind this one, and moving on is
    // the feedback. The result row below is for the settings visit, where the
    // user stays put and wants to read it.
    if (check.ok && widget.isFirstRun) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _confirmRemove() async {
    final removed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove key?', style: RM.sheetTitle),
        content: Text(
          'Voice parsing stops working until you enter a key again.',
          style: RM.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: RM.button.copyWith(fontSize: 14, color: RM.inkMid),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Remove',
              style: RM.button.copyWith(fontSize: 14, color: RM.alarm),
            ),
          ),
        ],
      ),
    );

    if (removed != true) return;
    await widget.store.clear();
    // Same reason as saving: a failed delete is silent, and a key the user
    // thinks is gone would still be in the keystore.
    final stillStored = await widget.store.read() != null;
    if (!mounted) return;
    setState(() {
      if (!stillStored) _controller.clear();
      _stored = stillStored;
      _result = stillStored ? _notRemoved : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.isFirstRun && !_stored;

    return PopScope(
      canPop: !locked,
      child: Scaffold(
        backgroundColor: RM.bg,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: !widget.isFirstRun,
          iconTheme: const IconThemeData(color: RM.ink),
          title: Text(
            'Gemini key',
            style: RM.screenTitle.copyWith(fontSize: 22),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: RM.accentLight))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'RMIND sends what you say to Google Gemini to turn it into '
                    'a reminder. Without a key that step cannot run, so voice '
                    'capture does nothing. Get a free key from Google AI '
                    'Studio, at aistudio.google.com, then paste it here. It is '
                    'stored on this phone only and never leaves it except to '
                    'talk to Gemini.',
                    style: RM.body,
                  ),
                  const SizedBox(height: 20),
                  _KeyField(
                    controller: _controller,
                    obscured: _obscured,
                    enabled: !_checking,
                    onToggleObscured: () =>
                        setState(() => _obscured = !_obscured),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _checkAndSave(),
                  ),
                  const SizedBox(height: 20),
                  _SaveButton(
                    checking: _checking,
                    enabled: !_checking && _controller.text.trim().isNotEmpty,
                    onPressed: _checkAndSave,
                  ),
                  if (_result != null) ...[
                    const SizedBox(height: 16),
                    _ResultRow(result: _result!),
                  ],
                  if (_stored) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _checking ? null : _confirmRemove,
                      style: TextButton.styleFrom(foregroundColor: RM.alarm),
                      child: Text(
                        'Remove key',
                        style: RM.button.copyWith(
                          fontSize: 14,
                          color: _checking ? RM.inkSoft : RM.alarm,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// Shown when the key itself is fine but the phone would not keep it.
const ApiKeyCheck _notStored = ApiKeyCheck(
  ok: false,
  message: 'The key works, but this phone would not store it. Try again, and '
      'if it keeps failing, restart the phone.',
);

const ApiKeyCheck _notRemoved = ApiKeyCheck(
  ok: false,
  message: 'The key could not be removed, it is still stored. Try again.',
);

class _KeyField extends StatelessWidget {
  const _KeyField({
    required this.controller,
    required this.obscured,
    required this.enabled,
    required this.onToggleObscured,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool obscured;
  final bool enabled;
  final VoidCallback onToggleObscured;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: RM.surface,
        borderRadius: BorderRadius.circular(RM.rRow),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('API key', style: RM.label),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  obscureText: obscured,
                  // A pasted key must survive intact: no autocorrect rewriting
                  // it, no capitalisation, no newline splitting it in two.
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.none,
                  maxLines: 1,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  style: RM.rowTitle.copyWith(
                    color: enabled ? RM.ink : RM.inkSoft,
                  ),
                  cursorColor: RM.accentLight,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: 'Paste your key',
                    hintStyle: RM.rowTitle.copyWith(color: RM.inkSoft),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: enabled ? onToggleObscured : null,
                iconSize: 22,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  obscured ? Icons.visibility_off : Icons.visibility,
                  color: enabled ? RM.inkSoft : RM.line,
                ),
                tooltip: obscured ? 'Show key' : 'Hide key',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({
    required this.checking,
    required this.enabled,
    required this.onPressed,
  });

  final bool checking;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: FilledButton(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          backgroundColor: RM.accent,
          disabledBackgroundColor: RM.field,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
        child: checking
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: RM.inkSoft,
                ),
              )
            : Text(
                'Check and save',
                style: enabled
                    ? RM.button
                    : RM.button.copyWith(color: RM.inkSoft),
              ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result});

  final ApiKeyCheck result;

  @override
  Widget build(BuildContext context) {
    final colour = result.ok ? RM.accentLight : RM.alarm;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          result.ok ? Icons.check_circle : Icons.error_outline,
          size: 20,
          color: colour,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(result.message, style: RM.body.copyWith(color: colour)),
        ),
      ],
    );
  }
}
