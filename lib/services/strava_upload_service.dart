import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String stravaCallbackScheme = 'sebastiansbikedisplay';
const String stravaCallbackHost = 'sebastiansbikedisplay';

String buildStravaAccountLabel({
  String? firstName,
  String? lastName,
  String? username,
  String? athleteId,
}) {
  final fullName = [firstName, lastName]
      .map((part) => part?.trim() ?? '')
      .where((part) => part.isNotEmpty)
      .join(' ');
  if (fullName.isNotEmpty) return fullName;
  final trimmedUsername = username?.trim();
  if (trimmedUsername != null && trimmedUsername.isNotEmpty) {
    return trimmedUsername;
  }
  final trimmedAthleteId = athleteId?.trim();
  if (trimmedAthleteId != null && trimmedAthleteId.isNotEmpty) {
    return 'Athlete $trimmedAthleteId';
  }
  return 'Unknown athlete';
}

bool shouldResetStravaAuthentication({
  required String previousClientId,
  required String nextClientId,
  required String previousClientSecret,
  required String nextClientSecret,
}) {
  return previousClientId.trim() != nextClientId.trim() ||
      previousClientSecret != nextClientSecret;
}

class StravaUploadState {
  final bool initialized;
  final bool isBusy;
  final bool autoUploadEnabled;
  final String clientId;
  final String clientSecret;
  final String? athleteId;
  final String? athleteName;
  final String? username;
  final String? errorMessage;

  const StravaUploadState({
    required this.initialized,
    required this.isBusy,
    required this.autoUploadEnabled,
    required this.clientId,
    required this.clientSecret,
    required this.athleteId,
    required this.athleteName,
    required this.username,
    required this.errorMessage,
  });

  const StravaUploadState.initial()
    : initialized = false,
      isBusy = false,
      autoUploadEnabled = false,
      clientId = '',
      clientSecret = '',
      athleteId = null,
      athleteName = null,
      username = null,
      errorMessage = null;

  bool get hasCredentials => clientId.trim().isNotEmpty && clientSecret.isNotEmpty;
  bool get isAuthenticated => athleteId != null && athleteId!.isNotEmpty;

  String get accountLabel {
    final trimmedAthleteName = athleteName?.trim();
    if (trimmedAthleteName != null && trimmedAthleteName.isNotEmpty) {
      return trimmedAthleteName;
    }
    return buildStravaAccountLabel(username: username, athleteId: athleteId);
  }

  StravaUploadState copyWith({
    bool? initialized,
    bool? isBusy,
    bool? autoUploadEnabled,
    String? clientId,
    String? clientSecret,
    String? athleteId,
    String? athleteName,
    String? username,
    String? errorMessage,
    bool clearAthlete = false,
    bool clearError = false,
  }) {
    return StravaUploadState(
      initialized: initialized ?? this.initialized,
      isBusy: isBusy ?? this.isBusy,
      autoUploadEnabled: autoUploadEnabled ?? this.autoUploadEnabled,
      clientId: clientId ?? this.clientId,
      clientSecret: clientSecret ?? this.clientSecret,
      athleteId: clearAthlete ? null : athleteId ?? this.athleteId,
      athleteName: clearAthlete ? null : athleteName ?? this.athleteName,
      username: clearAthlete ? null : username ?? this.username,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class StravaUploadResult {
  final bool attempted;
  final bool succeeded;
  final String? message;
  final int? activityId;

  const StravaUploadResult({
    required this.attempted,
    required this.succeeded,
    required this.message,
    required this.activityId,
  });

  const StravaUploadResult.skipped()
    : attempted = false,
      succeeded = false,
      message = null,
      activityId = null;
}

class StravaUploadService {
  StravaUploadService._();

  static final StravaUploadService instance = StravaUploadService._();

  static const _clientIdKey = 'strava_client_id';
  static const _autoUploadKey = 'strava_auto_upload';
  static const _athleteIdKey = 'strava_athlete_id';
  static const _athleteNameKey = 'strava_athlete_name';
  static const _usernameKey = 'strava_username';
  static const _clientSecretKey = 'strava_client_secret';
  static const _accessTokenKey = 'strava_access_token';
  static const _refreshTokenKey = 'strava_refresh_token';
  static const _expiresAtKey = 'strava_expires_at';
  static const _oauthBaseUrl = 'https://www.strava.com';
  static const _apiBaseUrl = 'https://api-v3.strava.com';
  static const _secureStorage = FlutterSecureStorage();

  final ValueNotifier<StravaUploadState> state = ValueNotifier(
    const StravaUploadState.initial(),
  );

  Future<void>? _initializeFuture;

  Future<void> initialize() async {
    _initializeFuture ??= _loadState();
    await _initializeFuture;
  }

  Future<void> saveConfiguration({
    required String clientId,
    required String clientSecret,
    required bool autoUploadEnabled,
  }) async {
    await initialize();
    final previous = state.value;
    final nextClientId = clientId.trim();
    final resetAuthentication = shouldResetStravaAuthentication(
      previousClientId: previous.clientId,
      nextClientId: nextClientId,
      previousClientSecret: previous.clientSecret,
      nextClientSecret: clientSecret,
    );
    _setState(state.value.copyWith(isBusy: true, clearError: true));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_clientIdKey, nextClientId);
      await prefs.setBool(_autoUploadKey, autoUploadEnabled);
      await _secureStorage.write(key: _clientSecretKey, value: clientSecret);
      if (resetAuthentication) {
        await _clearAuthentication(preserveCredentials: true);
      }
      _setState(
        state.value.copyWith(
          isBusy: false,
          clientId: nextClientId,
          clientSecret: clientSecret,
          autoUploadEnabled: autoUploadEnabled,
          clearAthlete: resetAuthentication,
          clearError: true,
        ),
      );
    } catch (error) {
      _setState(
        state.value.copyWith(
          isBusy: false,
          errorMessage: 'Failed to save Strava settings: $error',
        ),
      );
      rethrow;
    }
  }

  Future<void> authenticate() async {
    await initialize();
    final current = state.value;
    if (!current.hasCredentials) {
      throw StateError('Set the Strava client ID and client secret first.');
    }
    _setState(current.copyWith(isBusy: true, clearError: true));
    try {
      final codeVerifier = _createRandomToken();
      final codeChallenge = _codeChallengeForVerifier(codeVerifier);
      final callbackUri = Uri(
        scheme: stravaCallbackScheme,
        host: stravaCallbackHost,
      );
      final authUri = Uri.parse(
        '$_oauthBaseUrl/oauth/mobile/authorize',
      ).replace(
        queryParameters: <String, String>{
          'client_id': current.clientId,
          'redirect_uri': callbackUri.toString(),
          'response_type': 'code',
          'approval_prompt': 'auto',
          'scope': 'activity:write,activity:read',
          'code_challenge': codeChallenge,
          'code_challenge_method': 'S256',
        },
      );

      final result = await FlutterWebAuth2.authenticate(
        url: authUri.toString(),
        callbackUrlScheme: stravaCallbackScheme,
      );
      final resultUri = Uri.parse(result);
      final error = resultUri.queryParameters['error'];
      if (error != null && error.isNotEmpty) {
        throw StateError('Strava authorization failed: $error');
      }
      final code = resultUri.queryParameters['code'];
      if (code == null || code.isEmpty) {
        throw StateError('Strava did not return an authorization code.');
      }
      await _exchangeAuthorizationCode(code, codeVerifier);
      _setState(state.value.copyWith(isBusy: false, clearError: true));
    } catch (error) {
      _setState(
        state.value.copyWith(
          isBusy: false,
          errorMessage: 'Failed to connect Strava: $error',
        ),
      );
      rethrow;
    }
  }

  Future<void> disconnect() async {
    await initialize();
    _setState(state.value.copyWith(isBusy: true, clearError: true));
    try {
      await _clearAuthentication(preserveCredentials: true);
      _setState(state.value.copyWith(isBusy: false, clearAthlete: true));
    } catch (error) {
      _setState(
        state.value.copyWith(
          isBusy: false,
          errorMessage: 'Failed to disconnect Strava: $error',
        ),
      );
      rethrow;
    }
  }

  Future<StravaUploadResult> uploadFinishedRide({
    required String fileName,
    required Uint8List fileBytes,
    DateTime? startedAt,
  }) async {
    await initialize();
    final current = state.value;
    if (!current.autoUploadEnabled || !current.isAuthenticated) {
      return const StravaUploadResult.skipped();
    }

    try {
      final accessToken = await _ensureValidAccessToken();
      if (accessToken == null) {
        return const StravaUploadResult(
          attempted: true,
          succeeded: false,
          message: 'Strava upload skipped: reconnect your account.',
          activityId: null,
        );
      }

      final authorizationHeader = ['Bearer', accessToken].join(' ');
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_apiBaseUrl/uploads'),
      )
        ..headers['Authorization'] = authorizationHeader
        ..fields['data_type'] = 'fit'
        ..fields['external_id'] = fileName
        ..fields['name'] = startedAt == null
            ? 'Simple Bike Display ride'
            : 'Ride ${startedAt.toLocal().toIso8601String()}'
        ..files.add(
          http.MultipartFile.fromBytes(
            'file',
            fileBytes,
            filename: fileName,
          ),
        );

      final response = await request.send();
      final body = await response.stream.bytesToString();
      final payload = body.isEmpty ? <String, dynamic>{} : jsonDecode(body) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = _extractUploadError(payload) ??
            'Strava upload failed with HTTP ${response.statusCode}.';
        return StravaUploadResult(
          attempted: true,
          succeeded: false,
          message: message,
          activityId: null,
        );
      }

      final error = _extractUploadError(payload);
      if (error != null) {
        return StravaUploadResult(
          attempted: true,
          succeeded: false,
          message: error,
          activityId: null,
        );
      }

      final activityId = _parseInt(payload['activity_id']);
      if (activityId != null) {
        return StravaUploadResult(
          attempted: true,
          succeeded: true,
          message: 'Strava upload finished for ${current.accountLabel}.',
          activityId: activityId,
        );
      }

      return StravaUploadResult(
        attempted: true,
        succeeded: true,
        message:
            'Strava accepted the upload for ${current.accountLabel} and is processing it.',
        activityId: null,
      );
    } catch (error) {
      return StravaUploadResult(
        attempted: true,
        succeeded: false,
        message: 'Strava upload failed: $error',
        activityId: null,
      );
    }
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final clientSecret = await _secureStorage.read(key: _clientSecretKey) ?? '';
    final currentState = StravaUploadState(
      initialized: true,
      isBusy: false,
      autoUploadEnabled: prefs.getBool(_autoUploadKey) ?? false,
      clientId: prefs.getString(_clientIdKey) ?? '',
      clientSecret: clientSecret,
      athleteId: prefs.getString(_athleteIdKey),
      athleteName: prefs.getString(_athleteNameKey),
      username: prefs.getString(_usernameKey),
      errorMessage: null,
    );
    _setState(currentState);
  }

  Future<void> _exchangeAuthorizationCode(
    String code,
    String codeVerifier,
  ) async {
    final current = state.value;
    final response = await http.post(
      Uri.parse('$_oauthBaseUrl/oauth/token'),
      body: <String, String>{
        'client_id': current.clientId,
        'client_secret': current.clientSecret,
        'code': code,
        'grant_type': 'authorization_code',
        'code_verifier': codeVerifier,
      },
    );
    await _handleTokenResponse(response);
  }

  Future<String?> _ensureValidAccessToken() async {
    final accessToken = await _secureStorage.read(key: _accessTokenKey);
    final refreshToken = await _secureStorage.read(key: _refreshTokenKey);
    final expiresAt = _parseInt(await _secureStorage.read(key: _expiresAtKey));

    if (accessToken == null || refreshToken == null || expiresAt == null) {
      return null;
    }

    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (expiresAt > nowSeconds + 60) {
      return accessToken;
    }

    final current = state.value;
    if (!current.hasCredentials) {
      return null;
    }

    final response = await http.post(
      Uri.parse('$_oauthBaseUrl/oauth/token'),
      body: <String, String>{
        'client_id': current.clientId,
        'client_secret': current.clientSecret,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
    );
    await _handleTokenResponse(response);
    return _secureStorage.read(key: _accessTokenKey);
  }

  Future<void> _handleTokenResponse(http.Response response) async {
    final payload = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = payload['message']?.toString() ??
          payload['errors']?.toString() ??
          'HTTP ${response.statusCode}';
      throw StateError(message);
    }
    await _persistAuthenticationPayload(payload);
  }

  Future<void> _persistAuthenticationPayload(Map<String, dynamic> payload) async {
    final accessToken = payload['access_token']?.toString();
    final refreshToken = payload['refresh_token']?.toString();
    final expiresAt = _parseInt(payload['expires_at']);
    final athlete = payload['athlete'];
    if (accessToken == null ||
        accessToken.isEmpty ||
        refreshToken == null ||
        refreshToken.isEmpty ||
        expiresAt == null ||
        athlete is! Map<String, dynamic>) {
      throw StateError('Strava returned an incomplete authentication response.');
    }

    final athleteId = athlete['id']?.toString();
    final athleteName = buildStravaAccountLabel(
      firstName: athlete['firstname']?.toString(),
      lastName: athlete['lastname']?.toString(),
      username: athlete['username']?.toString(),
      athleteId: athleteId,
    );
    final prefs = await SharedPreferences.getInstance();
    await Future.wait<dynamic>(<Future<dynamic>>[
      _secureStorage.write(key: _accessTokenKey, value: accessToken),
      _secureStorage.write(key: _refreshTokenKey, value: refreshToken),
      _secureStorage.write(key: _expiresAtKey, value: expiresAt.toString()),
      prefs.setString(_athleteIdKey, athleteId ?? ''),
      prefs.setString(_athleteNameKey, athleteName),
      prefs.setString(_usernameKey, athlete['username']?.toString() ?? ''),
    ]);
    _setState(
      state.value.copyWith(
        athleteId: athleteId,
        athleteName: athleteName,
        username: athlete['username']?.toString(),
        clearError: true,
      ),
    );
  }

  Future<void> _clearAuthentication({required bool preserveCredentials}) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait<dynamic>(<Future<dynamic>>[
      _secureStorage.delete(key: _accessTokenKey),
      _secureStorage.delete(key: _refreshTokenKey),
      _secureStorage.delete(key: _expiresAtKey),
      if (!preserveCredentials) _secureStorage.delete(key: _clientSecretKey),
      prefs.remove(_athleteIdKey),
      prefs.remove(_athleteNameKey),
      prefs.remove(_usernameKey),
      if (!preserveCredentials) prefs.remove(_clientIdKey),
      if (!preserveCredentials) prefs.remove(_autoUploadKey),
    ]);
  }

  String _createRandomToken([int length = 48]) {
    final random = Random.secure();
    final bytes = List<int>.generate(length, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _codeChallengeForVerifier(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  String? _extractUploadError(Map<String, dynamic> payload) {
    final error = payload['error'];
    if (error is String && error.isNotEmpty) return error;
    final message = payload['message'];
    if (message is String && message.isNotEmpty) return message;
    return null;
  }

  int? _parseInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  void _setState(StravaUploadState nextState) {
    if (state.value == nextState) return;
    state.value = nextState;
  }
}
