import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../auth/console_links.dart';
import '../shared/external_url_launcher.dart';

class HomeOpenConsoleButton extends StatelessWidget {
  const HomeOpenConsoleButton({
    super.key,
    this.buttonKey,
    this.tooltip = '打开控制台',
  });

  final Key? buttonKey;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return FTooltip(
      tipBuilder: (context, controller) => Text(tooltip),
      child: FButton(
        key: buttonKey,
        variant: .ghost,
        size: .sm,
        onPress: () => unawaited(
          launchExternalUrl(consoleHomeUri(), scope: 'home.console'),
        ),
        mainAxisSize: MainAxisSize.min,
        child: const Icon(Icons.open_in_new, size: 16),
      ),
    );
  }
}
