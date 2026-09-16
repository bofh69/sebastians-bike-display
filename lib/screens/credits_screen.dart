import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_constants.dart';

class CreditsScreen extends StatefulWidget {
  const CreditsScreen({super.key});

  @override
  State<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends State<CreditsScreen> {
  late Future<_SbomDocument> _sbomFuture;
  AssetBundle? _assetBundle;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final assetBundle = DefaultAssetBundle.of(context);
    if (identical(_assetBundle, assetBundle)) {
      return;
    }
    _assetBundle = assetBundle;
    _sbomFuture = _loadSbom(assetBundle);
  }

  Future<_SbomDocument> _loadSbom(AssetBundle bundle) async {
    final rawJson = await bundle.loadString('assets/generated/sbom.json');
    return _SbomDocument.fromJson(
      jsonDecode(rawJson) as Map<String, dynamic>,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Credits')),
      body: FutureBuilder<_SbomDocument>(
        future: _sbomFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Unable to load dependency credits.',
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final sbom = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kAppDisplayName,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This page is generated from the bundled SBOM and lists the libraries that power the app.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      if (sbom.rootComponent.description != null &&
                          sbom.rootComponent.description!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(sbom.rootComponent.description!),
                      ],
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ...sbom.rootComponent.links.map(
                            (link) => OutlinedButton.icon(
                              onPressed: () => _openLink(link.uri),
                              icon: const Icon(Icons.code),
                              label: Text(link.label),
                            ),
                          ),
                          Tooltip(
                            message: 'Open the bundled licenses page',
                            child: OutlinedButton.icon(
                              onPressed: () {
                                showLicensePage(
                                  context: context,
                                  applicationName: kAppDisplayName,
                                  applicationVersion:
                                      sbom.rootComponent.version,
                                );
                              },
                              icon: const Icon(Icons.gavel),
                              label: const Text('Licenses'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Dependencies (${sbom.components.length})',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              ...sbom.components.map(
                (component) => _DependencyCard(
                  component: component,
                  onOpenLink: _openLink,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openLink(Uri uri) async {
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) {
        return;
      }
    } catch (_) {
      // Handled by the snackbar below.
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open ${uri.toString()}')),
    );
  }
}

class _DependencyCard extends StatelessWidget {
  const _DependencyCard({required this.component, required this.onOpenLink});

  final _SbomComponent component;
  final ValueChanged<Uri> onOpenLink;

  @override
  Widget build(BuildContext context) {
    final directLabel = component.isDirectDependency
        ? 'Direct dependency'
        : 'Transitive dependency';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              component.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              component.version,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Text(
              directLabel,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (component.description != null &&
                component.description!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(component.description!),
            ],
            if (component.links.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: component.links.map((link) {
                  return OutlinedButton(
                    onPressed: () => onOpenLink(link.uri),
                    child: Text(link.label),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SbomDocument {
  const _SbomDocument({required this.rootComponent, required this.components});

  final _SbomComponent rootComponent;
  final List<_SbomComponent> components;

  factory _SbomDocument.fromJson(Map<String, dynamic> json) {
    final metadata = json['metadata'] as Map<String, dynamic>? ?? const {};
    final rootComponent = _SbomComponent.fromJson(
      metadata['component'] as Map<String, dynamic>? ?? const {},
    );
    final components = (json['components'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .map(_SbomComponent.fromJson)
        .toList(growable: false);
    return _SbomDocument(rootComponent: rootComponent, components: components);
  }
}

class _SbomComponent {
  const _SbomComponent({
    required this.name,
    required this.version,
    required this.isDirectDependency,
    required this.links,
    this.description,
  });

  final String name;
  final String version;
  final String? description;
  final bool isDirectDependency;
  final List<_SbomLink> links;

  factory _SbomComponent.fromJson(Map<String, dynamic> json) {
    final properties = (json['properties'] is List
            ? json['properties'] as List<dynamic>
            : const <dynamic>[])
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry));
    final links = (json['externalReferences'] is List
            ? json['externalReferences'] as List<dynamic>
            : const <dynamic>[])
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .map(_SbomLink.tryFromJson)
        .whereType<_SbomLink>()
        .toList(growable: false);
    final isDirectDependency = properties.any(
      (property) =>
          property['name'] == 'pub:relationship' &&
          property['value'] == 'direct',
    );
    return _SbomComponent(
      name: json['name'] as String? ?? 'Unknown package',
      version: json['version'] as String? ?? '',
      description: json['description'] as String?,
      isDirectDependency: isDirectDependency,
      links: links,
    );
  }
}

class _SbomLink {
  const _SbomLink({required this.label, required this.uri});

  final String label;
  final Uri uri;

  static _SbomLink? tryFromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? 'link';
    final url = json['url'] as String?;
    final uri = url == null ? null : Uri.tryParse(url);
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        (scheme != 'http' && scheme != 'https')) {
      return null;
    }
    return _SbomLink(label: _labelForType(type), uri: uri);
  }

  static String _labelForType(String type) {
    switch (type) {
      case 'vcs':
        return 'Source';
      case 'documentation':
        return 'Docs';
      case 'issue-tracker':
        return 'Issues';
      case 'website':
      default:
        return 'Website';
    }
  }
}
