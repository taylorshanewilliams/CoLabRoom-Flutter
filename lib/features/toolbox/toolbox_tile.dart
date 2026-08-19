import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/bloom_tap.dart';

/// A tile for Toolbox categories and cheat sheets — deliberately styled
/// like [RoomTile]/[SongTile] (same tap/drag/tile-grid feel as everywhere
/// else) but with an orange accent instead of cyan and a small "Reference"
/// tag, so it reads as reference material rather than a real collaboration
/// space with members in it.
class ToolboxTile extends StatelessWidget {
  const ToolboxTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.badge = 'REFERENCE',
    super.key,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final String badge;

  @override
  Widget build(BuildContext context) {
    return BloomTap(
      onTap: onTap,
      semanticLabel: title,
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: <Color>[
                        AppColors.orange.withValues(alpha: 0.48),
                        AppColors.orange.withValues(alpha: 0.22),
                        AppColors.orange.withValues(alpha: 0.03),
                      ],
                    ),
                  ),
                  child: Icon(icon, color: AppColors.orange, size: 21),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.orange.withValues(alpha: 0.32)),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(
                      color: AppColors.orange,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
