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
const String defaultStravaClientId = '276719';
const String requiredStravaOauthScope =
    'read,activity:write,activity:read_all,profile:read_all';
const String defaultStravaProxyBaseUrl = String.fromEnvironment(
  'STRAVA_PROXY_BASE_URL',
  defaultValue: 'https://sbc.diegeekdie.com/api/',
);

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
}) {
  return previousClientId.trim() != nextClientId.trim();
}

String buildStravaRideNameForMidpoint(DateTime midpointLocalTime) {
  final hour = midpointLocalTime.hour;
  if (hour >= 6 && hour < 11) return 'Morning ride';
  if (hour >= 11 && hour < 14) return 'Lunch ride';
  if (hour >= 14 && hour < 18) return 'Afternoon ride';
  if (hour >= 18 && hour < 22) return 'Evening ride';
  return 'Night ride';
}

Map<String, String> buildStravaUploadFields({
  required String fileName,
  required DateTime midpointLocalTime,
  String? selectedGearId,
  bool clearGear = false,
}) {
  final fields = <String, String>{
    'data_type': 'fit',
    'external_id': fileName,
    'name': buildStravaRideNameForMidpoint(midpointLocalTime),
  };
  if (clearGear) {
    fields['gear_id'] = 'none';
  } else if (selectedGearId != null && selectedGearId.isNotEmpty) {
    fields['gear_id'] = selectedGearId;
  }
  return fields;
}

({
  String? accessToken,
  String? refreshToken,
  int? expiresAt,
  Map<String, dynamic>? athlete,
})
parseStravaAuthenticationPayload(Map<String, dynamic> payload) {
  final athletePayload = payload['athlete'];
  return (
    accessToken: payload['access_token']?.toString(),
    refreshToken: payload['refresh_token']?.toString(),
    expiresAt: int.tryParse(payload['expires_at']?.toString() ?? ''),
    athlete: athletePayload is Map<String, dynamic>
        ? athletePayload
        : athletePayload is Map
        ? Map<String, dynamic>.from(athletePayload)
        : null,
  );
}

class StravaUploadState {
  final bool initialized;
  final bool isBusy;
  final bool autoUploadEnabled;
  final String clientId;
  final String? athleteId;
  final String? athleteName;
  final String? username;
  final String? errorMessage;

  const StravaUploadState({
    required this.initialized,
    required this.isBusy,
    required this.autoUploadEnabled,
    required this.clientId,
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
      athleteId = null,
      athleteName = null,
      username = null,
      errorMessage = null;

  bool get hasCredentials => clientId.trim().isNotEmpty;
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

class StravaBikeOption {
  final String gearId;
  final String name;
  final bool isDefault;

  const StravaBikeOption({
    required this.gearId,
    required this.name,
    required this.isDefault,
  });
}

List<StravaBikeOption> parseStravaBikeOptions(Map<String, dynamic> payload) {
  final defaultBikeId = payload['default_bike']?.toString();
  final bikesPayload = payload['bikes'];
  if (bikesPayload is! List) return const <StravaBikeOption>[];
  final options = <StravaBikeOption>[];
  for (final bike in bikesPayload) {
    if (bike is! Map) continue;
    final bikeMap = Map<String, dynamic>.from(bike);
    final id = bikeMap['id']?.toString();
    if (id == null || id.isEmpty) continue;
    final rawName = bikeMap['name']?.toString().trim();
    final name = rawName != null && rawName.isNotEmpty ? rawName : 'Bike $id';
    options.add(
      StravaBikeOption(
        gearId: id,
        name: name,
        isDefault: id == defaultBikeId,
      ),
    );
  }
  options.sort((a, b) {
    if (a.isDefault != b.isDefault) {
      return a.isDefault ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return options;
}

class StravaUploadService {
  StravaUploadService._();

  static final StravaUploadService instance = StravaUploadService._();

  static const _clientIdKey = 'strava_client_id';
  static const _autoUploadKey = 'strava_auto_upload';
  static const _athleteIdKey = 'strava_athlete_id';
  static const _athleteNameKey = 'strava_athlete_name';
  static const _usernameKey = 'strava_username';
  static const _accessTokenKey = 'strava_access_token';
  static const _refreshTokenKey = 'strava_refresh_token';
  static const _expiresAtKey = 'strava_expires_at';
  static const _oauthScopeKey = 'strava_oauth_scope';
  static const _oauthBaseUrl = 'https://www.strava.com';
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
    required bool autoUploadEnabled,
  }) async {
    await initialize();
    final previous = state.value;
    const nextClientId = defaultStravaClientId;
    final savedScope = (await SharedPreferences.getInstance()).getString(
          _oauthScopeKey,
        ) ??
        '';
    final scopeChanged = savedScope != requiredStravaOauthScope;
    final resetAuthentication = shouldResetStravaAuthentication(
      previousClientId: previous.clientId,
      nextClientId: nextClientId,
    ) || scopeChanged;
    _setState(state.value.copyWith(isBusy: true, clearError: true));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_clientIdKey, nextClientId);
      await prefs.setBool(_autoUploadKey, autoUploadEnabled);
      await prefs.setString(_oauthScopeKey, requiredStravaOauthScope);
      if (resetAuthentication) {
        await _clearAuthentication();
      }
      _setState(
        state.value.copyWith(
          isBusy: false,
          clientId: nextClientId,
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
      throw StateError(
        'Strava client ID is missing.',
      );
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
          'scope': requiredStravaOauthScope,
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
      await _exchangeAuthorizationCode(code, codeVerifier, callbackUri);
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
      await _clearAuthentication();
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
    DateTime? midpointAt,
    String? selectedGearId,
    bool clearGear = false,
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

      final uploadFields = buildStravaUploadFields(
        fileName: fileName,
        midpointLocalTime: (midpointAt ?? DateTime.now()).toLocal(),
        selectedGearId: selectedGearId,
        clearGear: clearGear,
      );
      final response = await http.post(
        _stravaProxyUri('strava/upload'),
        headers: const <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'access_token': accessToken,
          'file_name': fileName,
          'file_base64': base64Encode(fileBytes),
          ...uploadFields,
        }),
      );
      final payload = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body) as Map<String, dynamic>;
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

  Future<List<StravaBikeOption>> listAthleteBikes() async {
    try {
      await initialize();
      final accessToken = await _ensureValidAccessToken();
      if (accessToken == null) return const <StravaBikeOption>[];
      final response = await http.post(
        _stravaProxyUri('strava/athlete'),
        headers: const <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, dynamic>{'access_token': accessToken}),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const <StravaBikeOption>[];
      }
      final payload = response.body.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      return parseStravaBikeOptions(payload);
    } catch (_) {
      return const <StravaBikeOption>[];
    }
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedScope = prefs.getString(_oauthScopeKey) ?? '';
    if (savedScope != requiredStravaOauthScope) {
      await _clearAuthentication();
      await prefs.setString(_oauthScopeKey, requiredStravaOauthScope);
    }
    final currentState = StravaUploadState(
      initialized: true,
      isBusy: false,
      autoUploadEnabled: prefs.getBool(_autoUploadKey) ?? false,
      clientId: defaultStravaClientId,
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
    Uri redirectUri,
  ) async {
    final response = await http.post(
      _stravaProxyUri('strava/oauth/token'),
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'code': code,
        'code_verifier': codeVerifier,
        'redirect_uri': redirectUri.toString(),
      }),
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

    try {
      final response = await http.post(
        _stravaProxyUri('strava/oauth/refresh'),
        headers: const <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<String, String>{'refresh_token': refreshToken}),
      );
      if (response.statusCode == 400 || response.statusCode == 401) {
        await _clearAuthentication();
        _setState(state.value.copyWith(clearAthlete: true, clearError: true));
        return null;
      }
      await _handleTokenResponse(response);
      return _secureStorage.read(key: _accessTokenKey);
    } catch (_) {
      return null;
    }
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
    final parsedPayload = parseStravaAuthenticationPayload(payload);
    final accessToken = parsedPayload.accessToken;
    final refreshToken = parsedPayload.refreshToken;
    final expiresAt = parsedPayload.expiresAt;
    final athlete = parsedPayload.athlete;
    if (accessToken == null ||
        accessToken.isEmpty ||
        refreshToken == null ||
        refreshToken.isEmpty ||
        expiresAt == null) {
      throw StateError('Strava returned an incomplete authentication response.');
    }

    final prefs = await SharedPreferences.getInstance();
    final writes = <Future<dynamic>>[
      _secureStorage.write(key: _accessTokenKey, value: accessToken),
      _secureStorage.write(key: _refreshTokenKey, value: refreshToken),
      _secureStorage.write(key: _expiresAtKey, value: expiresAt.toString()),
    ];
    StravaUploadState nextState = state.value.copyWith(clearError: true);
    if (athlete != null) {
      final athleteId = athlete['id']?.toString();
      final username = athlete['username']?.toString();
      final athleteName = buildStravaAccountLabel(
        firstName: athlete['firstname']?.toString(),
        lastName: athlete['lastname']?.toString(),
        username: username,
        athleteId: athleteId,
      );
      writes.addAll(<Future<dynamic>>[
        prefs.setString(_athleteIdKey, athleteId ?? ''),
        prefs.setString(_athleteNameKey, athleteName),
        prefs.setString(_usernameKey, username ?? ''),
      ]);
      nextState = nextState.copyWith(
        athleteId: athleteId,
        athleteName: athleteName,
        username: username,
      );
    } else {
      final persistedAthleteId = prefs.getString(_athleteIdKey);
      final persistedAthleteName = prefs.getString(_athleteNameKey);
      final persistedUsername = prefs.getString(_usernameKey);
      nextState = nextState.copyWith(
        athleteId: persistedAthleteId,
        athleteName: persistedAthleteName,
        username: persistedUsername,
      );
    }
    await Future.wait<dynamic>(writes);
    _setState(nextState);
  }

  Future<void> _clearAuthentication() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait<dynamic>(<Future<dynamic>>[
      _secureStorage.delete(key: _accessTokenKey),
      _secureStorage.delete(key: _refreshTokenKey),
      _secureStorage.delete(key: _expiresAtKey),
      prefs.remove(_athleteIdKey),
      prefs.remove(_athleteNameKey),
      prefs.remove(_usernameKey),
    ]);
  }

  Uri _stravaProxyUri(String path) {
    var base = defaultStravaProxyBaseUrl.trim();
    if (!base.endsWith('/')) {
      base = '$base/';
    }
    final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
    return Uri.parse(base).resolve(normalizedPath);
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
