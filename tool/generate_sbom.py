#!/usr/bin/env python3
import json
import hashlib
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from pathlib import Path

import yaml

REPO_URL = 'https://github.com/bofh69/sebastians-bike-display'
PUB_HOST = 'https://pub.dev'
LOCK_FILE = 'pubspec.lock'
PUBSPEC_FILE = 'pubspec.yaml'
PACKAGE_CONFIG_FILE = '.dart_tool/package_config.json'
OUTPUT_FILE = 'assets/generated/sbom.json'
CACHE_DIR = '.dart_tool/sbom-cache'
TIMEOUT_SECONDS = 30

SDK_COMPONENTS = {
    'flutter': {
        'description': 'Flutter SDK',
        'links': [
            {'type': 'website', 'url': 'https://flutter.dev'},
            {'type': 'vcs', 'url': 'https://github.com/flutter/flutter'},
        ],
        'component_type': 'framework',
        'dependencies': [],
    },
    'flutter_web_plugins': {
        'description': 'Flutter web plugin support',
        'links': [
            {'type': 'website', 'url': 'https://flutter.dev'},
            {'type': 'vcs', 'url': 'https://github.com/flutter/flutter'},
        ],
        'component_type': 'framework',
        'dependencies': ['flutter'],
    },
    'sky_engine': {
        'description': 'Flutter engine Dart UI bindings',
        'links': [
            {'type': 'website', 'url': 'https://flutter.dev'},
            {'type': 'vcs', 'url': 'https://github.com/flutter/flutter'},
        ],
        'component_type': 'framework',
        'dependencies': ['flutter'],
    },
}
def parse_pubspec_file(path: Path, *, require_identity: bool) -> dict[str, object]:
    document = yaml.safe_load(path.read_text(encoding='utf-8')) or {}
    if not isinstance(document, dict):
        raise ValueError(f'Unexpected YAML document in {path}')

    dependencies = document.get('dependencies') or {}
    dependency_names = [
        name
        for name in (
            list(dependencies.keys())
            if isinstance(dependencies, dict)
            else dependencies
        )
        if isinstance(name, str)
    ]

    name = document.get('name')
    version = document.get('version')

    if require_identity and (not isinstance(name, str) or not isinstance(version, str)):
        raise ValueError(f'Failed to parse package name/version from {path}')

    return {
        'name': name,
        'description': document.get('description') or '',
        'version': version,
        'dependencies': dependency_names,
        'homepage': document.get('homepage'),
        'repository': document.get('repository'),
        'documentation': document.get('documentation'),
        'issue_tracker': document.get('issue_tracker'),
    }


def parse_pubspec_lock(path: Path) -> dict[str, dict[str, object]]:
    document = yaml.safe_load(path.read_text(encoding='utf-8')) or {}
    packages = document.get('packages') or {}
    if not isinstance(packages, dict):
        raise ValueError(f'Unexpected lockfile structure in {path}')

    parsed_packages: dict[str, dict[str, object]] = {}
    for name, package_data in packages.items():
        if not isinstance(name, str) or not isinstance(package_data, dict):
            continue
        parsed_packages[name] = {
            'source': str(package_data.get('source', 'unknown')),
            'version': str(package_data.get('version', '')),
            'dependency': str(package_data.get('dependency', '')),
            'description': package_data.get('description'),
        }
    return parsed_packages


def fetch_json(url: str) -> dict[str, object]:
    request = urllib.request.Request(
        url,
        headers={
            'User-Agent': 'sebastians-bike-display-sbom-generator/1.0',
            'Accept': 'application/json',
        },
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def fetch_package_version(
    repo_root: Path,
    package_name: str,
    version: str,
) -> dict[str, object]:
    cache_dir = repo_root / CACHE_DIR
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_key = hashlib.sha256(f'{package_name}@{version}'.encode('utf-8')).hexdigest()
    cache_file = cache_dir / f'{cache_key}.json'
    if cache_file.exists():
        try:
            return json.loads(cache_file.read_text(encoding='utf-8'))
        except json.JSONDecodeError:
            cache_file.unlink(missing_ok=True)

    package_data = fetch_json(
        f'{PUB_HOST}/api/packages/{package_name}/versions/{version}',
    )
    with tempfile.NamedTemporaryFile(
        'w',
        encoding='utf-8',
        dir=cache_dir,
        delete=False,
    ) as handle:
        handle.write(json.dumps(package_data, indent=2, sort_keys=True) + '\n')
        temp_path = Path(handle.name)
    os.replace(temp_path, cache_file)
    return package_data


def load_package_locations(repo_root: Path) -> dict[str, Path]:
    package_config_path = repo_root / PACKAGE_CONFIG_FILE
    if not package_config_path.exists():
        return {}

    package_config = json.loads(package_config_path.read_text(encoding='utf-8'))
    locations: dict[str, Path] = {}
    for package in package_config.get('packages', []):
        if not isinstance(package, dict):
            continue
        name = package.get('name')
        root_uri = package.get('rootUri')
        if not isinstance(name, str) or not isinstance(root_uri, str):
            continue
        parsed_uri = urllib.parse.urlparse(root_uri)
        if parsed_uri.scheme == 'file':
            decoded_path = Path(urllib.request.url2pathname(parsed_uri.path))
            locations[name] = (
                decoded_path
                if decoded_path.is_absolute()
                else (package_config_path.parent / decoded_path).resolve()
            )
            continue
        locations[name] = (package_config_path.parent / root_uri).resolve()
    return locations


def make_pub_purl(name: str, version: str) -> str:
    encoded_name = urllib.parse.quote(name, safe='')
    encoded_version = urllib.parse.quote(version, safe='')
    return f'pkg:pub/{encoded_name}@{encoded_version}'


def append_reference(references: list[dict[str, str]], ref_type: str, url: str | None, seen: set[tuple[str, str]]) -> None:
    if not url:
        return
    key = (ref_type, url)
    if key in seen:
        return
    references.append({'type': ref_type, 'url': url})
    seen.add(key)


def string_or_none(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def normalize_links(
    pubspec: dict[str, object] | None,
    package_name: str,
) -> list[dict[str, str]]:
    references: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    append_reference(references, 'website', f'{PUB_HOST}/packages/{package_name}', seen)
    if not isinstance(pubspec, dict):
        return references
    append_reference(references, 'website', string_or_none(pubspec.get('homepage')), seen)
    append_reference(references, 'vcs', string_or_none(pubspec.get('repository')), seen)
    append_reference(references, 'documentation', string_or_none(pubspec.get('documentation')), seen)
    append_reference(references, 'issue-tracker', string_or_none(pubspec.get('issue_tracker')), seen)
    return references


def fallback_links(package_name: str) -> list[dict[str, str]]:
    return [{'type': 'website', 'url': f'{PUB_HOST}/packages/{package_name}'}]


def git_links(locked_info: dict[str, object], package_name: str) -> list[dict[str, str]]:
    description = locked_info.get('description')
    if not isinstance(description, dict):
        return fallback_links(package_name)
    url = string_or_none(description.get('url'))
    if not url:
        return fallback_links(package_name)
    return [{'type': 'vcs', 'url': url}]


def pubspec_dependency_names(
    pubspec: dict[str, object],
    locked_packages: dict[str, dict[str, object]],
) -> list[str]:
    dependencies = pubspec.get('dependencies') or {}
    if isinstance(dependencies, list):
        return [
            name
            for name in dependencies
            if isinstance(name, str) and name in locked_packages
        ]
    if not isinstance(dependencies, dict):
        return []
    return [name for name in dependencies.keys() if name in locked_packages]


def package_component(name: str, locked_info: dict[str, object], description: str, links: list[dict[str, str]], is_direct: bool, component_type: str = 'library') -> dict[str, object]:
    version = str(locked_info['version'])
    properties = [
        {'name': 'pub:source', 'value': locked_info.get('source', 'unknown')},
        {'name': 'pub:relationship', 'value': 'direct' if is_direct else 'transitive'},
    ]

    component: dict[str, object] = {
        'bom-ref': make_pub_purl(name, version),
        'type': component_type,
        'name': name,
        'version': version,
        'purl': make_pub_purl(name, version),
        'scope': 'required',
        'properties': properties,
        'externalReferences': links,
    }
    if description:
        component['description'] = description
    return component


def build_sbom(repo_root: Path) -> dict[str, object]:
    root = parse_pubspec_file(repo_root / PUBSPEC_FILE, require_identity=True)
    locked_packages = parse_pubspec_lock(repo_root / LOCK_FILE)
    package_locations = load_package_locations(repo_root)
    if not locked_packages:
        raise ValueError('No packages found in pubspec.lock')

    root_ref = make_pub_purl(str(root['name']), str(root['version']))
    component_cache: dict[str, dict[str, object]] = {}
    dependency_map: dict[str, set[str]] = {root_ref: set()}
    direct_dependencies = [
        name for name in root['dependencies'] if name in locked_packages
    ]
    queue = deque(direct_dependencies)
    visited: set[str] = set()

    for name in direct_dependencies:
        locked_info = locked_packages[name]
        dependency_map[root_ref].add(
            make_pub_purl(name, str(locked_info['version'])),
        )

    while queue:
        package_name = queue.popleft()
        if package_name in visited:
            continue
        visited.add(package_name)

        locked_info = locked_packages.get(package_name)
        if not locked_info or 'version' not in locked_info:
            continue

        source = locked_info.get('source', 'unknown')
        dependencies: list[str]
        if source == 'hosted':
            package_data = fetch_package_version(
                repo_root,
                package_name,
                str(locked_info['version']),
            )
            pubspec = package_data.get('pubspec', {})
            if not isinstance(pubspec, dict):
                raise ValueError(f'Unexpected pubspec payload for {package_name}')
            dependencies = pubspec_dependency_names(pubspec, locked_packages)
            component_cache[package_name] = package_component(
                package_name,
                locked_info,
                str(pubspec.get('description', '')),
                normalize_links(pubspec, package_name),
                is_direct=package_name in direct_dependencies,
            )
        elif source == 'sdk':
            sdk_component = SDK_COMPONENTS.get(package_name, {})
            dependencies = [
                name
                for name in sdk_component.get('dependencies', [])
                if name in locked_packages
            ]
            component_cache[package_name] = package_component(
                package_name,
                locked_info,
                sdk_component.get('description', ''),
                list(sdk_component.get('links', [])),
                is_direct=package_name in direct_dependencies,
                component_type=sdk_component.get('component_type', 'framework'),
            )
        elif source == 'git':
            package_root = package_locations.get(package_name)
            local_pubspec = (
                parse_pubspec_file(
                    package_root / PUBSPEC_FILE,
                    require_identity=False,
                )
                if package_root and (package_root / PUBSPEC_FILE).exists()
                else None
            )
            dependencies = (
                pubspec_dependency_names(local_pubspec, locked_packages)
                if local_pubspec
                else []
            )
            component_cache[package_name] = package_component(
                package_name,
                locked_info,
                str(local_pubspec.get('description', '')) if local_pubspec else '',
                normalize_links(local_pubspec, package_name)
                if local_pubspec
                else git_links(locked_info, package_name),
                is_direct=package_name in direct_dependencies,
            )
        else:
            package_root = package_locations.get(package_name)
            local_pubspec = (
                parse_pubspec_file(
                    package_root / PUBSPEC_FILE,
                    require_identity=False,
                )
                if package_root and (package_root / PUBSPEC_FILE).exists()
                else None
            )
            dependencies = (
                pubspec_dependency_names(local_pubspec, locked_packages)
                if local_pubspec
                else []
            )
            component_cache[package_name] = package_component(
                package_name,
                locked_info,
                str(local_pubspec.get('description', '')) if local_pubspec else '',
                (
                    normalize_links(local_pubspec, package_name)
                    if local_pubspec
                    else fallback_links(package_name)
                ),
                is_direct=package_name in direct_dependencies,
            )

        package_ref = make_pub_purl(package_name, str(locked_info['version']))
        dependency_map.setdefault(package_ref, set())
        for dependency_name in dependencies:
            dependency_info = locked_packages.get(dependency_name)
            if not dependency_info or 'version' not in dependency_info:
                continue
            dependency_ref = make_pub_purl(dependency_name, dependency_info['version'])
            dependency_map[package_ref].add(dependency_ref)
            if dependency_name not in visited:
                queue.append(dependency_name)

    root_component = {
        'bom-ref': root_ref,
        'type': 'application',
        'name': root['name'],
        'version': root['version'],
        'description': root['description'],
        'externalReferences': [
            {'type': 'website', 'url': REPO_URL},
            {'type': 'vcs', 'url': REPO_URL},
        ],
        'properties': [
            {'name': 'app:display_name', 'value': "Sebastian's Bike Display"},
        ],
    }

    components = sorted(
        component_cache.values(),
        key=lambda item: (
            next(
                (
                    prop.get('value') != 'direct'
                    for prop in item.get('properties', [])
                    if prop.get('name') == 'pub:relationship'
                ),
                True,
            ),
            str(item['name']).lower(),
        ),
    )

    dependency_entries = [
        {
            'ref': ref,
            'dependsOn': sorted(depends_on),
        }
        for ref, depends_on in dependency_map.items()
    ]
    dependency_entries.sort(key=lambda item: item['ref'])

    return {
        'bomFormat': 'CycloneDX',
        'specVersion': '1.6',
        'version': 1,
        'metadata': {
            'component': root_component,
        },
        'components': components,
        'dependencies': dependency_entries,
    }


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    try:
        sbom = build_sbom(repo_root)
    except (
        ValueError,
        urllib.error.URLError,
        urllib.error.HTTPError,
        json.JSONDecodeError,
    ) as error:
        print(f'Failed to generate SBOM: {error}', file=sys.stderr)
        return 1

    output_path = repo_root / OUTPUT_FILE
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(sbom, indent=2, sort_keys=False) + '\n', encoding='utf-8')
    print(f'Wrote {output_path}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
