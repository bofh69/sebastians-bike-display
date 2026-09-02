import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/heart_rate_sensor_service.dart';
import '../services/power_cadence_sensor_service.dart';

class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _ftpController = TextEditingController();
  final HeartRateSensorService _heartRateSensorService =
      HeartRateSensorService.instance;
  final PowerCadenceSensorService _powerCadenceSensorService =
      PowerCadenceSensorService.instance;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    unawaited(
      _heartRateSensorService.initialize().then((_) {
        return _heartRateSensorService.refreshBatteryLevel();
      }),
    );
    unawaited(
      _powerCadenceSensorService.initialize().then((_) {
        return _powerCadenceSensorService.refreshBatteryLevel();
      }),
    );
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _ftpController.text = (prefs.getInt('ftp') ?? 200).toString();
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
            ValueListenableBuilder<HeartRateSensorState>(
              valueListenable: _heartRateSensorService.state,
              builder: (context, hrState, _) {
                return ListTile(
                  leading: const Icon(Icons.favorite),
                  title: const Text('Heart Rate Monitor'),
                  subtitle: Text(_buildHeartRateSubtitle(hrState)),
                  isThreeLine: hrState.deviceName != null,
                  trailing: TextButton(
                    onPressed: _pairHrDevice,
                    child: Text(hrState.deviceName == null ? 'Pair' : 'Change'),
                  ),
                );
              },
            ),
            ValueListenableBuilder<PowerCadenceSensorState>(
              valueListenable: _powerCadenceSensorService.state,
              builder: (context, powerState, _) {
                return ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('Cadence / Power Sensor'),
                  subtitle: Text(_buildPowerCadenceSubtitle(powerState)),
                  isThreeLine: powerState.deviceName != null,
                  trailing: TextButton(
                    onPressed: _pairPowerDevice,
                    child: Text(powerState.deviceName == null ? 'Pair' : 'Change'),
                  ),
                );
              },
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
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Scanning for heart rate monitors...')),
          ],
        ),
      ),
    );

    final devices = await _heartRateSensorService.scanForDevices();
    if (navigator.canPop()) {
      navigator.pop();
    }
    if (!mounted) return;

    final errorMessage = _heartRateSensorService.state.value.errorMessage;
    if (errorMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage)));
      return;
    }

    if (devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No heart rate monitors found.')),
      );
      return;
    }

    final selectedDevice = await showDialog<HeartRateDiscoveredDevice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select heart rate monitor'),
        children: [
          for (final device in devices)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(device),
              child: Text(device.name),
            ),
        ],
      ),
    );
    if (selectedDevice == null || !mounted) return;

    await _heartRateSensorService.pairDevice(selectedDevice);
    if (!mounted) return;
    final updatedState = _heartRateSensorService.state.value;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          updatedState.errorMessage ??
              'Paired with ${selectedDevice.name}. Connecting to sensor...',
        ),
      ),
    );
  }

  Future<void> _pairPowerDevice() async {
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Scanning for cadence/power sensors...')),
          ],
        ),
      ),
    );

    final devices = await _powerCadenceSensorService.scanForDevices();
    if (navigator.canPop()) {
      navigator.pop();
    }
    if (!mounted) return;

    final errorMessage = _powerCadenceSensorService.state.value.errorMessage;
    if (errorMessage != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage)));
      return;
    }

    if (devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No cadence/power sensors found.')),
      );
      return;
    }

    final selectedDevice = await showDialog<PowerCadenceDiscoveredDevice>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select cadence/power sensor'),
        children: [
          for (final device in devices)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(device),
              child: Text(device.name),
            ),
        ],
      ),
    );
    if (selectedDevice == null || !mounted) return;

    await _powerCadenceSensorService.pairDevice(selectedDevice);
    if (!mounted) return;
    final updatedState = _powerCadenceSensorService.state.value;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          updatedState.errorMessage ??
              'Paired with ${selectedDevice.name}. Connecting to sensor...',
        ),
      ),
    );
  }

  String _buildHeartRateSubtitle(HeartRateSensorState state) {
    if (state.deviceName == null) {
      return 'Not paired';
    }

    final batteryText =
        state.batteryLevel == null ? 'Battery: Unknown' : 'Battery: ${state.batteryLevel}%';
    final status = state.isConnected
        ? 'Connected'
        : state.isConnecting
        ? 'Connecting…'
        : 'Disconnected';

    return '${state.deviceName}\n$status\n$batteryText';
  }

  String _buildPowerCadenceSubtitle(PowerCadenceSensorState state) {
    if (state.deviceName == null) {
      return 'Not paired';
    }

    final batteryText =
        state.batteryLevel == null ? 'Battery: Unknown' : 'Battery: ${state.batteryLevel}%';
    final status = state.isConnected
        ? 'Connected'
        : state.isConnecting
        ? 'Connecting…'
        : 'Disconnected';

    return '${state.deviceName}\n$status\n$batteryText';
  }
}
