"""Parse archived mesh and current surface benchmark output without rerunning it."""
from pathlib import Path
import argparse
import hashlib
import json
import re


EXTRACTION_LABELS = (
    'surface_extraction_prepared_chunk_and_neighbors',
    'meshing_prepared_chunk_and_neighbors',
)
START_LABELS = ('surface_start', 'mesh_start')
TIMING_FIELDS = ('median_ms', 'p95_ms', 'units_per_sample', 'throughput_units_s')


def fields(text):
    result = {}
    for key, value in re.findall(r'(\w+)=([^\s]+)', text):
        if value in ('true', 'false'):
            result[key] = value == 'true'
        else:
            try:
                result[key] = float(value) if '.' in value else int(value)
            except ValueError:
                result[key] = value
    return result


def require_fields(record, required, context):
    missing = set(required) - record.keys()
    if missing:
        raise ValueError(f'{context}: missing fields {", ".join(sorted(missing))}')


def validate(sections, path):
    if len(sections) != 2:
        raise ValueError(f'{path}: expected two sections, found {len(sections)}')
    for section, beaches in zip(sections, (False, True)):
        context = f'{path}: beaches={beaches}'
        if section.get('identity', {}).get('beaches') is not beaches:
            raise ValueError(f'{context}: missing or out-of-order identity')
        expected = section.get('representative_replay', {}).get('sites')
        if type(expected) is not int or expected <= 0:
            raise ValueError(f'{context}: missing representative_replay site count')
        if len(section['sites']) != expected:
            raise ValueError(f'{context}: expected {expected} sites, found {len(section["sites"])}')
        for name, site in section['sites'].items():
            site_context = f'{context}: site={name}'
            require_fields(site, ('position', 'samples', 'output'), site_context)
            require_fields(site['position'], ('x', 'y', 'z'), site_context)
            require_fields(site['samples'], ('rounds',), site_context)
            require_fields(site['output'], ('faces', 'face_bytes', 'digest'), site_context)
            for label in ('column_initialization', 'chunk_fill'):
                require_fields(site.get(label, {}), TIMING_FIELDS, f'{site_context}: {label}')
            extraction = next((site[label] for label in EXTRACTION_LABELS if label in site), None)
            if extraction is None:
                raise ValueError(f'{site_context}: missing surface extraction timing')
            require_fields(extraction, TIMING_FIELDS, f'{site_context}: surface extraction')
        startup = next((section[label] for label in START_LABELS if label in section), None)
        if startup is None:
            raise ValueError(f'{context}: missing surface startup metrics')
        require_fields(startup, ('faces', 'face_bytes', 'digest', 'environment_samples_s',
                                 'metadata_fingerprint'), f'{context}: surface startup')


def parse(path):
    text = path.read_text()
    sections = []
    section = None
    site = None
    for line in text.splitlines():
        if line.startswith('preparation_allocations='):
            section = {'sizes': fields(line), 'sites': {}, 'workloads': {}}
            sections.append(section)
            site = None
        elif section is None:
            continue
        elif line.startswith('identity='):
            section['identity'] = fields(line)
        elif line.startswith('site='):
            parsed = fields(line)
            site = parsed.pop('site')
            section['sites'].setdefault(site, {})
            if ' column_initialization:' in line:
                pos = line.index(' column_initialization:')
                section['sites'][site]['position'] = fields(line[:pos])
                section['sites'][site]['column_initialization'] = fields(line[pos:])
            elif ' digest=' in line:
                section['sites'][site]['output'] = parsed
            else:
                section['sites'][site]['samples'] = parsed
        elif line.partition(':')[0] in ('chunk_fill', *EXTRACTION_LABELS):
            if site is None:
                raise ValueError(f'{path}: timing record precedes its site')
            section['sites'][site][line.split(':')[0]] = fields(line)
        elif line.startswith(('cold_column_plus_surface_chunk:', 'cached_column_vertical_chunks:')):
            section['workloads'][line.split(':')[0]] = fields(line)
        elif line.startswith((
            'cache_churn ', 'representative_replay ', 'surface_start ', 'mesh_start ',
            'restart_fingerprint ',
        )):
            section[line.split()[0]] = fields(line)
        elif line.startswith('prepared_fingerprint='):
            section['prepared_fingerprint'] = fields(line)
        elif 'restart' in line and 'matches=' in line:
            section.setdefault('checks', {}).update(fields(line))
    validate(sections, path)
    return {'source_log': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'sections': sections}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('logs', nargs='+', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        result = {p.stem: parse(p) for p in args.logs}
    except ValueError as error:
        parser.error(str(error))
    encoded = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end='')
