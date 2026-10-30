import 'package:flutter/material.dart';

/// Browse and edit the cookie jar (issue #12).
Future<void> showCookieManager(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Cookies'),
    content: const Text('The cookie manager is not available in this build.'),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  ),
);
