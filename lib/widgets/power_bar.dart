import 'package:flutter/material.dart';

class PowerBar extends StatelessWidget {
  final double? power;
  final double ftp;

  const PowerBar({
    super.key,
    required this.power,
    required this.ftp,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final zoneColors = brightness == Brightness.dark
        ? const [
            Color(0xFF5A5A5A),
            Color(0xFF4A6FA5),
            Color(0xFF7DA5D8),
            Color(0xFF4CAF50),
            Color(0xFFFFC857),
            Color(0xFFFF9F43),
            Color(0xFFE74C3C),
          ]
        : const [
            Color(0xFF808080),
            Color(0xFF2E5DAB),
            Color(0xFF82B1FF),
            Color(0xFF2E7D32),
            Color(0xFFFBC02D),
            Color(0xFFFB8C00),
            Color(0xFFC62828),
          ];
    const zoneFlex = [55, 20, 15, 15, 15, 30, 50];
    final powerFraction =
        power == null || ftp <= 0 ? 0.0 : (power! / (ftp * 2.0)).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Power Zone (${power == null || ftp <= 0 ? 'N/A' : '${((power! / ftp) * 100).round()}% FTP'})',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(10)),
                  child: Row(
                    children: List.generate(zoneColors.length, (i) {
                      return Expanded(
                        flex: zoneFlex[i],
                        child: Container(height: 20, color: zoneColors[i]),
                      );
                    }),
                  ),
                ),
                Positioned(
                  left: (powerFraction * width - 14).clamp(0.0, width - 28),
                  top: -4,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.onSurface,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.surface,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
