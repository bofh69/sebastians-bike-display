import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _ftpController = TextEditingController();
  String? _hrDeviceName;
  String? _powerDeviceName;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ftpController.text = (prefs.getInt('ftp') ?? 200).toString();
      _hrDeviceName = prefs.getString('hr_device');
      _powerDeviceName = prefs.getString('power_device');
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('ftp', int.tryParse(_ftpController.text) ?? 200);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
    }
  }

  @override
  void dispose() {
    _ftpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuration'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Performance', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _ftpController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'FTP (Functional Threshold Power)',
                suffixText: 'W',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            Text('BLE Devices', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.favorite),
              title: const Text('Heart Rate Monitor'),
              subtitle: Text(_hrDeviceName ?? 'Not paired'),
              trailing: TextButton(
                onPressed: _pairHrDevice,
                child: const Text('Pair'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.speed),
              title: const Text('Cadence / Power Sensor'),
              subtitle: Text(_powerDeviceName ?? 'Not paired'),
              trailing: TextButton(
                onPressed: _pairPowerDevice,
                child: const Text('Pair'),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _savePrefs,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pairHrDevice() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('BLE scanning not yet implemented')),
    );
  }

  Future<void> _pairPowerDevice() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('BLE scanning not yet implemented')),
    );
  }
}
