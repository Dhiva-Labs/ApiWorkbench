import 'package:flutter/material.dart';

import '../theme.dart';

/// Dialogs on screens narrower than this fill the screen.
const phoneBreakpoint = 600.0;

/// Smallest tap target on touch platforms.
const minTouchTarget = 44.0;

/// Touch-first platforms (phones and tablets) need tap targets of at least
/// [minTouchTarget]; desktop keeps its compact sizes.
bool isTouch(BuildContext context) => switch (Theme.of(context).platform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => true,
  _ => false,
};

bool isPhoneWidth(BuildContext context) =>
    MediaQuery.sizeOf(context).width < phoneBreakpoint;

/// A dialog that fills the screen on phones, with an app bar holding the
/// close button, [headerActions] and the [primary] action, and a body that
/// shrinks above the keyboard. Elsewhere it is a regular [AlertDialog] of
/// [width] (and [height], for content that scrolls itself).
class AdaptiveDialog extends StatelessWidget {
  const AdaptiveDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.primary,
    this.headerActions = const [],
    this.width = 560,
    this.height,
    this.contentPadding = const EdgeInsets.fromLTRB(24, 16, 24, 0),
  });

  final Widget title;

  /// Scrolls itself, or fits in [height] on desktop and in the remaining
  /// screen height on phones.
  final Widget content;

  /// Buttons under the content (desktop).
  final List<Widget> actions;

  /// Phones: the main action, shown in the app bar (Save, Import…). Without
  /// one, the close button is the way out, which suits dialogs whose edits
  /// apply immediately.
  final Widget? primary;

  /// Extra buttons next to the title, such as Delete.
  final List<Widget> headerActions;

  final double width;
  final double? height;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    if (isPhoneWidth(context)) {
      return Dialog.fullscreen(
        backgroundColor: Palette.surface,
        child: Scaffold(
          backgroundColor: Palette.surface,
          appBar: AppBar(
            leading: const CloseButton(),
            titleSpacing: 0,
            title: DefaultTextStyle.merge(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              child: title,
            ),
            actions: [
              ...headerActions,
              if (primary != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 12),
                  child: Center(child: primary),
                ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: content,
            ),
          ),
        ),
      );
    }
    return AlertDialog(
      title: headerActions.isEmpty
          ? title
          : Row(
              children: [
                Expanded(child: title),
                ...headerActions,
              ],
            ),
      contentPadding: contentPadding,
      content: SizedBox(width: width, height: height, child: content),
      actions: actions,
    );
  }
}

/// Owns a dialog's text controllers and disposes them when the dialog is
/// really gone. `await showDialog(...)` returns as soon as the dialog is
/// popped, while it is still animating out and can still rebuild its text
/// fields, so disposing right after the await uses disposed controllers.
class ControllerScope extends StatefulWidget {
  const ControllerScope({
    super.key,
    required this.controllers,
    required this.child,
  });

  final List<TextEditingController> controllers;
  final Widget child;

  @override
  State<ControllerScope> createState() => _ControllerScopeState();
}

class _ControllerScopeState extends State<ControllerScope> {
  @override
  void dispose() {
    for (final c in widget.controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
