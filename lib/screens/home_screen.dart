import 'package:flutter/material.dart';

import '../models/bike_data.dart';
import '../widgets/metric_tile.dart';
import '../widgets/power_bar.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Upper bound of the power bar; update from FTP * ~1.5 in a future sprint.
  static const double _maxPowerDisplay = 400.0;

  bool _isRunning = false;
  final BikeData _data = BikeData();

  String _formatDuration(Duration? d) {
    if (d == null) return 'N/A';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatBalance() {
    if (_data.leftBalance == null || _data.rightBalance == null) return 'N/A';
    return '${_data.leftBalance!.toStringAsFixed(0)}/${_data.rightBalance!.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Simple Bike Display'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.pushNamed(context, '/config'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.0,
              children: [
                MetricTile(
                  title: 'Power (3s)',
                  value: _data.power3s?.toStringAsFixed(0) ?? 'N/A',
                  unit: 'W',
                ),
                MetricTile(
                  title: 'Cadence',
                  value: _data.cadence?.toStringAsFixed(0) ?? 'N/A',
                  unit: 'rpm',
                ),
                MetricTile(
                  title: 'Heart Rate',
                  value: _data.heartRate?.toStringAsFixed(0) ?? 'N/A',
                  unit: 'bpm',
                ),
                MetricTile(
                  title: 'Distance',
                  value: _data.distance?.toStringAsFixed(2) ?? 'N/A',
                  unit: 'km',
                ),
                MetricTile(
                  title: 'Duration',
                  value: _formatDuration(_data.duration),
                  unit: '',
                ),
                MetricTile(
                  title: 'Speed',
                  value: _data.speed?.toStringAsFixed(1) ?? 'N/A',
                  unit: 'km/h',
                ),
                MetricTile(
                  title: 'L/R Balance',
                  value: _formatBalance(),
                  unit: '%',
                ),
                MetricTile(
                  title: 'Avg Speed',
                  value: _data.avgSpeed?.toStringAsFixed(1) ?? 'N/A',
                  unit: 'km/h',
                ),
                MetricTile(
                  title: 'Power (20 min)',
                  value: _data.power20min?.toStringAsFixed(0) ?? 'N/A',
                  unit: 'W',
                ),
              ],
            ),
            const SizedBox(height: 16),
            PowerBar(power: _data.power3s, maxPower: _maxPowerDisplay),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isRunning = !_isRunning;
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isRunning ? Colors.red : Colors.green,
                ),
                child: Text(
                  _isRunning ? 'End' : 'Start',
                  style: const TextStyle(fontSize: 20, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
