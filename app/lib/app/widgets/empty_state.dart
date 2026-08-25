import 'package:flutter/material.dart';

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
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: ShiruTokens.emptyMinHeight),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: ShiruTokens.emptyGlyphSize,
              color: ShiruTokens.emptyGlyphColor,
            ),
            const SizedBox(height: ShiruTokens.space3),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: ShiruTokens.fontFamily,
                fontSize: ShiruTokens.fontScale16,
                fontWeight: FontWeight.w600,
                color: ShiruTokens.textLight,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: ShiruTokens.space1),
              Text(
                detail!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: ShiruTokens.fontFamily,
                  fontSize: ShiruTokens.fontScale14,
                  color: ShiruTokens.textMuted,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: ShiruTokens.space4),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
