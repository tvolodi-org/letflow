/// Screens of the 30-day PWA sign-in (REQ-810): the offer, the PIN setup and
/// the PIN lock screen. All strings come from the ARB catalogue (`session.*`);
/// no message ever contains a PIN or a token.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/i18n.dart';
import 'navigation_bootstrap.dart';

/// "Stay signed in for 30 days?" Returns true when the user accepts.
Future<bool> showKeepSignedInOffer(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      key: const Key('keep-signed-in-offer'),
      title: Text(tr('session.offer.title')),
      content: Text(tr('session.offer.body')),
      actions: [
        TextButton(
          key: const Key('keep-signed-in-decline'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(tr('session.offer.decline')),
        ),
        ElevatedButton(
          key: const Key('keep-signed-in-accept'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(tr('session.offer.accept')),
        ),
      ],
    ),
  );
  return accepted ?? false;
}

class _PinField extends StatelessWidget {
  const _PinField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.enabled = true,
    this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      enabled: enabled,
      obscureText: true,
      keyboardType: TextInputType.number,
      maxLength: 6,
      autofillHints: const <String>[],
      enableSuggestions: false,
      autocorrect: false,
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9]'))],
      decoration: InputDecoration(labelText: label, counterText: ''),
      onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
    );
  }
}

/// Two PIN fields; stores nothing unless the PIN is valid and both match.
class PinSetupScreen extends ConsumerStatefulWidget {
  const PinSetupScreen({super.key});

  @override
  ConsumerState<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends ConsumerState<PinSetupScreen> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final outcome = await ref
        .read(bootstrapControllerProvider)
        .enrollWithPin(_pin.text, _confirm.text);
    if (!mounted) return;
    switch (outcome) {
      case EnrollOutcome.enrolled:
        Navigator.of(context).pop(true);
      case EnrollOutcome.invalidPin:
        setState(() {
          _busy = false;
          _error = tr('session.pin.invalid');
        });
      case EnrollOutcome.mismatch:
        setState(() {
          _busy = false;
          _error = tr('session.pin.mismatch');
        });
      case EnrollOutcome.failed:
        setState(() {
          _busy = false;
          _error = tr('session.pin.failed');
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('pin-setup-screen'),
      appBar: AppBar(title: Text(tr('session.pin.setupTitle'))),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr('session.pin.setupHint')),
                _PinField(
                  fieldKey: const Key('pin-setup-field'),
                  controller: _pin,
                  label: tr('session.pin.label'),
                  enabled: !_busy,
                ),
                _PinField(
                  fieldKey: const Key('pin-confirm-field'),
                  controller: _confirm,
                  label: tr('session.pin.confirmLabel'),
                  enabled: !_busy,
                  onSubmitted: _save,
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      key: const Key('pin-setup-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                ElevatedButton(
                  key: const Key('pin-setup-save'),
                  onPressed: _busy ? null : _save,
                  child: Text(
                    _busy ? tr('session.pin.working') : tr('session.pin.save'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The lock screen: shown while the controller is in `locked`.
class PinUnlockScreen extends ConsumerStatefulWidget {
  const PinUnlockScreen({super.key});

  @override
  ConsumerState<PinUnlockScreen> createState() => _PinUnlockScreenState();
}

class _PinUnlockScreenState extends ConsumerState<PinUnlockScreen> {
  final _pin = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final c = ref.read(bootstrapControllerProvider);
    setState(() => _busy = true);
    final retry = c.state.unlockNotice == UnlockNotice.noConnection;
    if (retry) {
      await c.retryUnlockRefresh();
    } else {
      await c.submitPin(_pin.text);
    }
    if (!mounted) return;
    _pin.clear();
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(bootstrapControllerProvider);
    final notice = unlockNoticeText(c.state);
    final retry = c.state.unlockNotice == UnlockNotice.noConnection;
    return Scaffold(
      key: const Key('pin-unlock-screen'),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr('session.unlock.title')),
                if (!retry)
                  _PinField(
                    fieldKey: const Key('pin-unlock-field'),
                    controller: _pin,
                    label: tr('session.pin.label'),
                    enabled: !_busy,
                    onSubmitted: _submit,
                  ),
                if (notice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      notice,
                      key: const Key('pin-unlock-notice'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                ElevatedButton(
                  key: const Key('pin-unlock-submit'),
                  onPressed: _busy ? null : _submit,
                  child: Text(
                    _busy
                        ? tr('session.pin.working')
                        : retry
                        ? tr('session.unlock.retry')
                        : tr('session.unlock.submit'),
                  ),
                ),
                TextButton(
                  key: const Key('pin-unlock-sign-in-again'),
                  onPressed: _busy ? null : c.signInAgain,
                  child: Text(tr('session.unlock.signInAgain')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
