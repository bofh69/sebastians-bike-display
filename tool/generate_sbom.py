#!/usr/bin/env python3
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from pathlib import Path

REPO_URL = 'https://github.com/bofh69/sebastians-bike-display'
PUB_HOST = 'https://pub.dev'
LOCK_FILE = 'pubspec.lock'
PUBSPEC_FILE = 'pubspec.yaml'
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
    },
}


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding='utf-8').splitlines()


def parse_root_pubspec(path: Path) -> dict[str, object]:
    name = None
    description = None
    version = None
    dependencies = []
    in_dependencies = False

    for raw_line in read_lines(path):
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue

        if not line.startswith(' '):
            in_dependencies = line == 'dependencies:'
            if line.startswith('name:'):
                name = line.split(':', 1)[1].strip().strip('"\'')
            elif line.startswith('description:'):
                description = line.split(':', 1)[1].strip().strip('"\'')
            elif line.startswith('version:'):
                version = line.split(':', 1)[1].strip().strip('"\'')
            continue

        if in_dependencies and line.startswith('  ') and not line.startswith('    '):
            dependency_name = line[2:].split(':', 1)[0].strip()
            if dependency_name:
                dependencies.append(dependency_name)

    if not name or not version:
        raise ValueError('Failed to parse root package name/version from pubspec.yaml')

    return {
        'name': name,
        'description': description or '',
        'version': version,
        'dependencies': dependencies,
    }


def parse_pubspec_lock(path: Path) -> dict[str, dict[str, str]]:
    packages: dict[str, dict[str, str]] = {}
    current_name = None
    in_packages = False

    for raw_line in read_lines(path):
        line = raw_line.rstrip('\n')
        if not line.strip() or line.lstrip().startswith('#'):
            continue

        if not line.startswith(' '):
            if line == 'packages:':
                in_packages = True
                current_name = None
                continue
            if in_packages:
                break
            continue

        if not in_packages:
            continue

        if line.startswith('  ') and not line.startswith('    '):
            current_name = line[2:].split(':', 1)[0].strip()
            packages[current_name] = {}
            continue

        if current_name and line.startswith('    '):
            stripped = line.strip()
            if stripped.startswith('source:'):
                packages[current_name]['source'] = stripped.split(':', 1)[1].strip().strip('"\'')
            elif stripped.startswith('version:'):
                packages[current_name]['version'] = stripped.split(':', 1)[1].strip().strip('"\'')
            elif stripped.startswith('dependency:'):
                packages[current_name]['dependency'] = stripped.split(':', 1)[1].strip().strip('"\'')

    return packages


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
    cache_file = cache_dir / f'{package_name}-{version}.json'
    if cache_file.exists():
        return json.loads(cache_file.read_text(encoding='utf-8'))

    package_data = fetch_json(
        f'{PUB_HOST}/api/packages/{package_name}/versions/{version}',
    )
    cache_file.write_text(
        json.dumps(package_data, indent=2, sort_keys=True) + '\n',
        encoding='utf-8',
    )
    return package_data


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


def normalize_links(pubspec: dict[str, object], package_name: str) -> list[dict[str, str]]:
    references: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    append_reference(references, 'website', f'{PUB_HOST}/packages/{package_name}', seen)
    append_reference(references, 'website', string_or_none(pubspec.get('homepage')), seen)
    append_reference(references, 'vcs', string_or_none(pubspec.get('repository')), seen)
    append_reference(references, 'documentation', string_or_none(pubspec.get('documentation')), seen)
    append_reference(references, 'issue-tracker', string_or_none(pubspec.get('issue_tracker')), seen)
    return references


def pubspec_dependency_names(pubspec: dict[str, object], locked_packages: dict[str, dict[str, str]]) -> list[str]:
    dependencies = pubspec.get('dependencies') or {}
    if not isinstance(dependencies, dict):
        return []
    return [name for name in dependencies.keys() if name in locked_packages]


def package_component(name: str, locked_info: dict[str, str], description: str, links: list[dict[str, str]], is_direct: bool, component_type: str = 'library') -> dict[str, object]:
    version = locked_info['version']
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
    root = parse_root_pubspec(repo_root / PUBSPEC_FILE)
    locked_packages = parse_pubspec_lock(repo_root / LOCK_FILE)
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
        dependency_map[root_ref].add(make_pub_purl(name, locked_info['version']))

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
                locked_info['version'],
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
            dependencies = []
            component_cache[package_name] = package_component(
                package_name,
                locked_info,
                sdk_component.get('description', ''),
                list(sdk_component.get('links', [])),
                is_direct=package_name in direct_dependencies,
                component_type=sdk_component.get('component_type', 'framework'),
            )
        else:
            dependencies = []
            component_cache[package_name] = package_component(
                package_name,
                locked_info,
                '',
                [],
                is_direct=package_name in direct_dependencies,
            )

        package_ref = make_pub_purl(package_name, locked_info['version'])
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
    except (ValueError, urllib.error.URLError) as error:
        print(f'Failed to generate SBOM: {error}', file=sys.stderr)
        return 1

    output_path = repo_root / OUTPUT_FILE
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(sbom, indent=2, sort_keys=False) + '\n', encoding='utf-8')
    print(f'Wrote {output_path}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
