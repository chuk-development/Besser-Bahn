import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Hosts an OAuth login inside the app.
///
/// The provider's redirect (`dbnav://…`, `besserbahn://…`) never reaches the
/// system: [NavigationDelegate.onNavigationRequest] catches it while the page
/// is still loading and pops this screen with the callback URL. That is what
/// keeps DB's logins out of the "which app should continue?" dialog — those
/// schemes are also registered by DB Navigator and the BahnBonus app, and
/// Android cannot tell who is meant (#35).
class OAuthWebViewScreen extends StatefulWidget {
  const OAuthWebViewScreen({
    super.key,
    required this.authUrl,
    required this.callbackUrlScheme,
    this.title = 'Anmeldung',
  });

  final String authUrl;
  final String callbackUrlScheme;
  final String title;

  @override
  State<OAuthWebViewScreen> createState() => _OAuthWebViewScreenState();
}

class _OAuthWebViewScreenState extends State<OAuthWebViewScreen> {
  late final WebViewController _controller;
  var _progress = 0.0;
  String? _host;

  /// Set as soon as a redirect is intercepted, so the "user cancelled" pop in
  /// [dispose] does not fire for a login that actually succeeded.
  var _finished = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            if (Uri.tryParse(request.url)?.scheme == widget.callbackUrlScheme) {
              _finish(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress / 100);
          },
          onPageStarted: (url) {
            // Shown next to the title so the user can see whose page is asking
            // for the password — the assurance a browser's address bar gives.
            if (mounted) setState(() => _host = Uri.tryParse(url)?.host);
          },
          // A redirect to a custom scheme surfaces as a load error on some
          // WebView versions instead of a navigation request.
          onWebResourceError: (error) {
            final url = error.url;
            if (url != null &&
                Uri.tryParse(url)?.scheme == widget.callbackUrlScheme) {
              _finish(url);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.authUrl));
  }

  void _finish(String callbackUrl) {
    if (_finished || !mounted) return;
    _finished = true;
    Navigator.of(context).pop(callbackUrl);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back / swipe-back means "I don't want to log in" — pop with null, which
      // the caller turns into a cancellation.
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title),
              if (_host != null)
                Text(
                  _host!,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          bottom: _progress >= 1
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(value: _progress),
                ),
        ),
        body: WebViewWidget(controller: _controller),
      ),
    );
  }
}
