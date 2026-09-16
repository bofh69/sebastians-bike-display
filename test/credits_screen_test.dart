import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_bike_display/screens/credits_screen.dart';

void main() {
  testWidgets('Credits screen renders dependency details from the SBOM', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: _ImmediateAssetBundle(_validSbomJson),
        child: const MaterialApp(home: CreditsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('example_dependency'), findsOneWidget);
    expect(find.text('1.2.3'), findsOneWidget);
    expect(find.text('Direct dependency'), findsOneWidget);
    expect(find.text('Website'), findsNWidgets(2));
    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Issues'), findsOneWidget);
    expect(find.text('Licenses'), findsOneWidget);
  });

  testWidgets('Credits screen shows an error when a link cannot open', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: _ImmediateAssetBundle(_validSbomJson),
        child: const MaterialApp(home: CreditsScreen()),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('Website').first);
    await tester.pump();

    expect(
      find.text(
        'Could not open https://github.com/bofh69/sebastians-bike-display',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Credits screen shows a loader while SBOM is loading', (
    WidgetTester tester,
  ) async {
    final bundle = _DeferredAssetBundle();

    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: bundle,
        child: const MaterialApp(home: CreditsScreen()),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    bundle.complete(_validSbomJson);
    await tester.pumpAndSettle();

    expect(find.text('Dependencies (1)'), findsOneWidget);
  });

  testWidgets('Credits screen shows an error when the SBOM cannot load', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: _FailingAssetBundle(),
        child: const MaterialApp(home: CreditsScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Unable to load dependency credits.'), findsOneWidget);
  });
}

class _DeferredAssetBundle extends CachingAssetBundle {
  final Completer<String> _completer = Completer<String>();

  void complete(String value) {
    _completer.complete(value);
  }

  @override
  Future<ByteData> load(String key) {
    throw UnimplementedError();
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    return _completer.future;
  }
}

class _ImmediateAssetBundle extends CachingAssetBundle {
  _ImmediateAssetBundle(this.value);

  final String value;

  @override
  Future<ByteData> load(String key) {
    throw UnimplementedError();
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    return Future<String>.value(value);
  }
}

class _FailingAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) {
    throw UnimplementedError();
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    return Future<String>.error(StateError('boom'));
  }
}

const String _validSbomJson = '''
{
  "metadata": {
    "component": {
      "name": "simple_bike_display",
      "version": "1.0.0+1",
      "description": "A bike computer app",
      "externalReferences": [
        {"type": "website", "url": "https://github.com/bofh69/sebastians-bike-display"}
      ]
    }
  },
  "components": [
    {
      "name": "example_dependency",
      "version": "1.2.3",
      "description": "Example dependency",
      "properties": [
        {"name": "pub:relationship", "value": "direct"}
      ],
      "externalReferences": [
        {"type": "website", "url": "https://pub.dev/packages/example_dependency"},
        {"type": "vcs", "url": "https://github.com/example/dependency"},
        {"type": "issue-tracker", "url": "https://github.com/example/dependency/issues"},
        {"type": "website", "url": "not a valid url"}
      ]
    }
  ]
}
''';
