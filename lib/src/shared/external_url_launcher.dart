import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logging/app_logger.dart';

Future<bool> launchExternalUrl(Uri uri, {String scope = 'url.launcher'}) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on MissingPluginException catch (error, stack) {
    AppLogger.instance.warn(
      scope,
      'External URL launcher is unavailable on this platform',
      context: {'error': error.toString(), 'stack': stack.toString()},
    );
    return false;
  } catch (error, stack) {
    AppLogger.instance.warn(
      scope,
      'Failed to open external URL',
      context: {'error': error.toString(), 'stack': stack.toString()},
    );
    return false;
  }
}
