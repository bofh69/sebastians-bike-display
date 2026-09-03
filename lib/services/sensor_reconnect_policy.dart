bool shouldRetrySavedSensorConnection({
  required String? deviceId,
  required bool isConnected,
  required bool isConnecting,
  required bool isScanning,
}) {
  return deviceId != null &&
      deviceId.isNotEmpty &&
      !isConnected &&
      !isConnecting &&
      !isScanning;
}
