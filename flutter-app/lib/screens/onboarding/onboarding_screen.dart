import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../providers/onboarding_provider.dart';
import '../../services/notification_service.dart';
import '../../theme/app_colors.dart';

/// First-launch onboarding: a handful of short intro slides orienting the user
/// to the main tabs, followed by sequential permission rationale screens
/// (notifications, then location). Each permission screen shows *why* before
/// triggering the OS dialog, and the user can decline — nothing here hard-blocks
/// the app. A final "Los geht's" marks onboarding seen and enters the app.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  // Intro slides + the two permission rationale steps + the final step.
  late final List<_Step> _steps = [
    const _Step.intro(
      icon: Icons.directions_railway,
      title: 'Willkommen bei Besser Bahn',
      body:
          'Deine schnellere, übersichtlichere Begleitung für Fahrten mit der '
          'Bahn — Verbindungen, Bahnhöfe und deine Reisen an einem Ort.',
    ),
    const _Step.intro(
      icon: Icons.info_outline,
      title: 'Inoffizielle App',
      body:
          'Besser Bahn ist eine inoffizielle, unabhängige App und steht in '
          'keiner Verbindung zur Deutschen Bahn AG. Alle Marken- und '
          'Namensrechte gehören ihren jeweiligen Eigentümern.\n\n'
          'Die Nutzung erfolgt auf eigenes Risiko. Für Preise, Verbindungen, '
          'Verspätungen oder etwaige Schäden — etwa Geldverlust oder gesperrte '
          'Konten — wird keine Haftung übernommen. Buchungen schließt du '
          'direkt bei der Deutschen Bahn ab.',
    ),
    const _Step.intro(
      icon: Icons.search,
      title: 'Suche',
      body:
          'Finde Verbindungen, vergleiche Preise und sieh dir jede Reise im '
          'Detail an.',
    ),
    const _Step.intro(
      icon: Icons.bookmark,
      title: 'Reisen',
      body:
          'Gespeicherte Fahrten, Live-Begleitung und deine persönliche '
          'Reisestatistik.',
    ),
    const _Step.intro(
      icon: Icons.train,
      title: 'Bahnhof',
      body:
          'Zuglauf, Abfahrten und die detaillierte Bahnhofskarte mit deinem '
          'Gleis.',
    ),
    const _Step.intro(
      icon: Icons.people_alt,
      title: 'Träwelling',
      body:
          'Optional: Check dich in deinen Zug ein und teile deine Fahrten mit '
          'Freund:innen.',
    ),
    _Step.permission(
      icon: Icons.notifications_active,
      title: 'Benachrichtigungen',
      body:
          'Für den Ankunfts-Wecker, Abfahrts-Erinnerungen und Hinweise zu '
          'Verspätungen und Anschlüssen. Du kannst das später jederzeit ändern.',
      cta: 'Benachrichtigungen erlauben',
      request: NotificationService.requestPermissions,
    ),
    _Step.permission(
      icon: Icons.my_location,
      title: 'Standort',
      body:
          'Zeigt dir auf der Bahnhofskarte, wo du bist und in welche Richtung '
          'dein Gleis liegt — und macht die Live-Begleitung deiner Reise '
          'genauer.',
      cta: 'Standort erlauben',
      request: _requestLocation,
    ),
    const _Step.finale(
      icon: Icons.check_circle,
      title: 'Alles bereit',
      body:
          'Du kannst loslegen. Einstellungen und Berechtigungen findest du '
          'jederzeit im Menü.',
    ),
  ];

  static Future<void> _requestLocation() async {
    // geolocator drives the OS dialog; permanent denials just resolve — the app
    // degrades gracefully (the map prompts again when "Mein Standort" is used).
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
  }

  bool get _isLast => _page == _steps.length - 1;

  void _next() {
    if (_isLast) {
      _finish();
    } else {
      _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _finish() async {
    await ref.read(onboardingSeenProvider.notifier).complete();
    if (mounted) context.go('/search');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = _steps[_page];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Top bar: progress dots + a "Skip" that jumps to the final step so
            // the user still lands on the explicit "Los geht's" enter button.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
              child: Row(
                children: [
                  _Dots(count: _steps.length, active: _page),
                  const Spacer(),
                  if (!_isLast)
                    TextButton(
                      onPressed: () => _controller.animateToPage(
                        _steps.length - 1,
                        duration: const Duration(milliseconds: 320),
                        curve: Curves.easeOutCubic,
                      ),
                      child: const Text('Überspringen'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _steps.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) => _StepView(step: _steps[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                children: [
                  // Permission steps get a request button; tapping it (granted
                  // or declined) advances. The label otherwise just moves on.
                  if (step.request != null)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.dbRed,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () async {
                          await step.request!();
                          _next();
                        },
                        icon: Icon(step.icon),
                        label: Text(step.cta ?? 'Erlauben'),
                      ),
                    )
                  else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.dbRed,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: _next,
                        child: Text(
                          _isLast ? "Los geht's" : 'Weiter',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  // On permission steps, let the user skip without granting.
                  if (step.request != null)
                    TextButton(
                      onPressed: _next,
                      child: const Text('Nicht jetzt'),
                    )
                  // On the final step, the enter button doubles as acceptance of
                  // the inofficial-use / no-liability terms shown earlier.
                  else if (_isLast)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Mit „Los geht\'s" bestätigst du, dass Besser Bahn eine '
                        'inoffizielle App ohne Verbindung zur Deutschen Bahn ist '
                        'und die Nutzung auf eigenes Risiko erfolgt.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One onboarding step: an intro slide, a permission rationale, or the finale.
class _Step {
  final IconData icon;
  final String title;
  final String body;

  /// Permission steps only: the CTA label and the request to fire on tap.
  final String? cta;
  final Future<void> Function()? request;

  const _Step.intro({
    required this.icon,
    required this.title,
    required this.body,
  }) : cta = null,
       request = null;

  const _Step.permission({
    required this.icon,
    required this.title,
    required this.body,
    required this.cta,
    required this.request,
  });

  const _Step.finale({
    required this.icon,
    required this.title,
    required this.body,
  }) : cta = null,
       request = null;
}

class _StepView extends StatelessWidget {
  final _Step step;
  const _StepView({required this.step});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: AppColors.dbRed.withAlpha(20),
              shape: BoxShape.circle,
            ),
            child: Icon(step.icon, size: 56, color: AppColors.dbRed),
          ),
          const SizedBox(height: 32),
          Text(
            step.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            step.body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Page-progress dots in DB red.
class _Dots extends StatelessWidget {
  final int count;
  final int active;
  const _Dots({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(count, (i) {
        final on = i == active;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.only(right: 6),
          width: on ? 20 : 7,
          height: 7,
          decoration: BoxDecoration(
            color: on
                ? AppColors.dbRed
                : Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}
