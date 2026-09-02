import 'package:flutter/material.dart';

class PowerBar extends StatelessWidget {
  final double? power;
  final double maxPower;

  const PowerBar({
    super.key,
    required this.power,
    required this.maxPower,
  });

  @override
  Widget build(BuildContext context) {
    final double fraction =
        power == null ? 0.0 : (power! / maxPower).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Power Zone', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  height: 20,
                  decoration: const BoxDecoration(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    gradient: LinearGradient(
                      colors: [
                        Color(0xFF808080),
                        Color(0xFF00008B),
                        Color(0xFF6495ED),
                        Color(0xFF00AA00),
                        Color(0xFFFFFF00),
                        Color(0xFFFF8C00),
                        Color(0xFFFF0000),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: (fraction * width - 10).clamp(0.0, width - 20),
                  top: -4,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
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
