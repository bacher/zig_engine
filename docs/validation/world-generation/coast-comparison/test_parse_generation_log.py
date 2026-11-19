"""Run with python3 -m unittest discover -s this-directory -v."""
from pathlib import Path
import json
import re
import tempfile
import unittest

import parse_generation_log as parser


ROOT = Path(__file__).parent
CURRENT = ROOT / 'fixtures/current-generation-half-12345-1.txt'


class ParseGenerationLogTests(unittest.TestCase):
    def test_archived_logs_reproduce_complete_recorded_summaries(self):
        summaries = json.loads((ROOT / 'full-regeneration-summary.json').read_text())
        for name, expected in summaries.items():
            with self.subTest(log=name):
                parsed = parser.parse(ROOT / f'{name}.txt')
                parsed['source_log'] = expected['source_log']
                self.assertEqual(parsed, expected)

    def test_unmodified_current_benchmark_output(self):
        parsed = parser.parse(CURRENT)
        for section in parsed['sections']:
            self.assertEqual(len(section['sites']), 17)
            self.assertIn('surface_start', section)
            for site in section['sites'].values():
                self.assertIn('surface_extraction_prepared_chunk_and_neighbors', site)
                self.assertIn('surface_allocations', site['output'])

    def expect_invalid(self, text, message):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'incomplete.txt'
            path.write_text(text)
            with self.assertRaisesRegex(ValueError, message):
                parser.parse(path)

    def test_missing_extraction_timing_is_rejected(self):
        text = CURRENT.read_text()
        text = re.sub(r'^surface_extraction_prepared_chunk_and_neighbors:.*\n', '',
                      text, count=1, flags=re.MULTILINE)
        self.expect_invalid(text, 'missing surface extraction timing')

    def test_missing_startup_metrics_are_rejected(self):
        text = re.sub(r'^surface_start .*\n', '', CURRENT.read_text(),
                      count=1, flags=re.MULTILINE)
        self.expect_invalid(text, 'missing surface startup metrics')

    def test_site_count_must_match_replay_record(self):
        text = CURRENT.read_text().replace('representative_replay sites=17',
                                          'representative_replay sites=18', 1)
        self.expect_invalid(text, 'expected 18 sites, found 17')

    def test_missing_replay_count_is_rejected(self):
        text = re.sub(r'^representative_replay .*\n', '', CURRENT.read_text(),
                      count=1, flags=re.MULTILINE)
        self.expect_invalid(text, 'missing representative_replay site count')

    def test_missing_output_field_is_rejected(self):
        text = re.sub(r' face_bytes=\d+', '', CURRENT.read_text(), count=1)
        self.expect_invalid(text, 'missing fields face_bytes')


if __name__ == '__main__':
    unittest.main()
