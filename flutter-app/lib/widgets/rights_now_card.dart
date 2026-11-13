import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/disruption_rights.dart';
import '../core/passenger_rights.dart';
import '../models/journey.dart';
import '../providers/account_provider.dart';
import '../providers/live_trip_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';

/// "Was darf ich jetzt?" on a Reiseplan whose train is cancelled or ≥20 min
/// late: may I take the ICE, another route, a taxi — answered for the rider's
/// ticket (from the booked order, else the Deutschland-Ticket setting), with
/// the bahn.de rule linked. Renders nothing while the trip runs normally.
class RightsNowCard extends ConsumerWidget {
  final Journey journey;

  /// `auftragsnummer/kundenwunschId` when this Reiseplan is a booked ticket.
  final String? ticketKey;

  const RightsNowCard({super.key, required this.journey, this.ticketKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = withLiveTimes(
      journey,
      ref.watch(liveTripTrackerProvider.select((s) => s.trips)),
    );
    final cancelled = live.legs.any((l) => !l.isWalking && l.cancelled);
    final delay = PassengerRights.delayMinutesOf(live);
    if (!cancelled && delay < 20) return const SizedBox.shrink();

    final angebot = ticketKey == null
        ? null
        : ref.watch(ticketProvider(ticketKey!)).asData?.value.angebotsname;
    final ticket = DisruptionRights.ticketFrom(
      angebotsname: angebot,
      hasDeutschlandTicket: ref.watch(
        settingsProvider.select((s) => s.hasDeutschlandTicket),
      ),
    );
    final answers = DisruptionRights.answers(
      ticket: ticket,
      delayMinutes: delay,
      cancelled: cancelled,
      plannedArrival: live.legs.lastOrNull?.plannedArrival,
    );
    if (answers.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        margin: EdgeInsets.zero,
        child: ExpansionTile(
          initiallyExpanded: cancelled,
          leading: const Icon(Icons.gavel, color: AppColors.warning),
          title: const Text('Was darf ich jetzt?'),
          subtitle: Text(
            cancelled ? 'Ein Zug fällt aus' : '+$delay Min am Ziel erwartet',
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final a in answers)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 22,
                      child: Icon(
                        a.allowed ? Icons.check_circle : Icons.block,
                        size: 18,
                        color: a.allowed ? AppColors.onTime : AppColors.delay,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            a.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              height: 1.4,
                            ),
                          ),
                          Text(a.text, style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse(DisruptionRights.generalUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Regeln auf bahn.de'),
                ),
                if (ticket == RightsTicket.deutschlandTicket ||
                    ticket == RightsTicket.unbekannt)
                  TextButton(
                    onPressed: () => launchUrl(
                      Uri.parse(DisruptionRights.dticketUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: const Text('Deutschlandticket'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
