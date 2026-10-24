"""Parse existing benchmark-generation output without running the benchmark."""
from pathlib import Path
import argparse
import hashlib
import json
import re


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


def parse(path):
    text = path.read_text()
    sections = []
    section = None
    site = None
    for line in text.splitlines():
        if line.startswith('preparation_allocations='):
            section = {'sizes': fields(line), 'sites': {}, 'workloads': {}}
            sections.append(section)
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
        elif line.startswith(('chunk_fill:', 'meshing_prepared_chunk_and_neighbors:')):
            section['sites'][site][line.split(':')[0]] = fields(line)
        elif line.startswith(('cold_column_plus_surface_chunk:', 'cached_column_vertical_chunks:')):
            section['workloads'][line.split(':')[0]] = fields(line)
        elif line.startswith(('cache_churn ', 'representative_replay ', 'mesh_start ', 'restart_fingerprint ')):
            section[line.split()[0]] = fields(line)
        elif line.startswith('prepared_fingerprint='):
            section['prepared_fingerprint'] = fields(line)
        elif 'restart' in line and 'matches=' in line:
            section.setdefault('checks', {}).update(fields(line))
    assert len(sections) == 2, (str(path), len(sections))
    assert [s['identity']['beaches'] for s in sections] == [False, True]
    assert all(len(s['sites']) == 11 for s in sections)
    return {'source_log': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'sections': sections}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('logs', nargs='+', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = {p.stem: parse(p) for p in args.logs}
    encoded = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end='')
