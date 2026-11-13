import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/account_provider.dart';
import '../services/db_account_service.dart';

/// "Ticket hinzufügen": load a ticket someone else bought for you (or one
/// booked without an account) by its order number and the traveller's surname
/// — the same lookup as DB Navigator's function of that name.
///
/// Like in Navigator, the ticket is stored on this device only. DB does not
/// attach it to the signed-in account, which is why adding it in Navigator
/// never made it show up here.
Future<void> showAddTicketDialog(BuildContext context) async {
  final count = await showDialog<int>(
    context: context,
    builder: (_) => const _AddTicketDialog(),
  );
  if (count == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        count == 1 ? 'Ticket hinzugefügt' : '$count Tickets hinzugefügt',
      ),
    ),
  );
}

class _AddTicketDialog extends ConsumerStatefulWidget {
  const _AddTicketDialog();

  @override
  ConsumerState<_AddTicketDialog> createState() => _AddTicketDialogState();
}

class _AddTicketDialogState extends ConsumerState<_AddTicketDialog> {
  final _nr = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _nr.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _valid =>
      _nr.text.replaceAll(RegExp(r'\s'), '').length >= 6 &&
      _name.text.trim().isNotEmpty;

  Future<void> _submit() async {
    if (!_valid || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final count = await ref
          .read(manualOrdersProvider.notifier)
          .add(_nr.text, _name.text);
      if (mounted) Navigator.of(context).pop(count);
    } on DbManualOrderException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Ticket konnte nicht geladen werden: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Ticket hinzufügen'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Für Tickets, die jemand anderes für dich gebucht hat. Die '
              'Auftragsnummer steht auf dem Ticket und in der '
              'Buchungsbestätigung.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nr,
              enabled: !_busy,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z ]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Auftragsnummer',
                hintText: 'z. B. 992533686225',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              enabled: !_busy,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.familyName],
              decoration: const InputDecoration(
                labelText: 'Nachname des Reisenden',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            Text(
              'Das Ticket wird nur auf diesem Gerät gespeichert, nicht in '
              'deinem DB-Konto.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _valid && !_busy ? _submit : null,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Hinzufügen'),
        ),
      ],
    );
  }
}

/// Asks, then removes an added ticket from this device. Returns true when it
/// was removed.
Future<bool> confirmRemoveManualTicket(
  BuildContext context,
  WidgetRef ref,
  String auftragsnummer,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Ticket entfernen?'),
      content: Text(
        'Auftrag $auftragsnummer wird von diesem Gerät entfernt. Das Ticket '
        'selbst bleibt gültig, du kannst es jederzeit wieder hinzufügen.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Entfernen'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await ref.read(manualOrdersProvider.notifier).remove(auftragsnummer);
  return true;
}
