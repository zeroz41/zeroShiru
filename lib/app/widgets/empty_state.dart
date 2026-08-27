import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/tokens.dart';

/// Calm "nothing here" state: 4.8rem glyph at white .28, min-height 24rem.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon = Icons.inbox_rounded,
    required this.message,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: ZeroTokens.emptyMinHeight),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: ZeroTokens.emptyGlyphSize,
              color: colors.emptyGlyph,
            ),
            const SizedBox(height: ZeroTokens.space3),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: ZeroTokens.fontFamily,
                fontSize: ZeroTokens.fontScale16,
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: ZeroTokens.space1),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: ZeroTokens.fontFamily,
                  fontSize: ZeroTokens.fontScale14,
                  color: colors.textMuted,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: ZeroTokens.space4),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
