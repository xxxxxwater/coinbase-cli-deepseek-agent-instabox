"""Offline tests: execute only the Codex helper definitions, never the shell script."""
import json
import os
from pathlib import Path
import tempfile
import tomllib
import unittest
from unittest.mock import patch

source = Path('scripts/ds-model.sh').read_text()
helpers = source.split('# ---- Codex: parse and validate before any configuration writes\n', 1)[1].split('codex_candidate = prepare_codex', 1)[0]
namespace = {'json': json, 'os': os}
exec(helpers, namespace)
prepare = namespace['prepare_codex']
replace = namespace['replace_codex']

class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'config.toml'

    def update(self, text):
        self.path.write_text(text)
        candidate = prepare(str(self.path), 'new"model', 'https://example.invalid')
        replace(str(self.path), candidate)
        return tomllib.loads(self.path.read_text())

    def test_existing_provider_and_root(self):
        result = self.update('''model = "old"
model_reasoning_effort = "high"
[model_providers.deepseek]
name = "old"
custom = 42
[model_providers.other]
name = "Other"
[mcp_servers.demo]
command = "true"
''')
        self.assertEqual(result['model_reasoning_effort'], 'high')
        self.assertEqual(result['model'], 'new"model')
        self.assertEqual(result['model_providers']['deepseek']['custom'], 42)
        self.assertEqual(result['model_providers']['other'], {'name': 'Other'})
        self.assertEqual(result['mcp_servers']['demo'], {'command': 'true'})

    def test_empty_missing_and_idempotent(self):
        candidate = prepare(str(self.path), 'new"model', 'https://example.invalid')
        replace(str(self.path), candidate)
        self.assertEqual(prepare(str(self.path), 'new"model', 'https://example.invalid'), candidate)
        self.assertEqual(self.update('')['model_provider'], 'deepseek')

    def test_old_managed_block(self):
        self.assertEqual(self.update('''# >>> deepseek-model (managed by ds-model.sh)
model = "old"
model_provider = "deepseek"
[model_providers.deepseek]
name = "DeepSeek"
# <<< deepseek-model
[mcp_servers.demo]
command = "true"
''')['mcp_servers']['demo']['command'], 'true')

    def test_all_toml_types_and_nested_arrays(self):
        original = '''title = "雪"
boolean = true
integer = 123
float = 1.25
date = 2026-11-16
time = 10:20:30.123
stamp = 2026-11-16T10:20:30Z
local = 2026-11-16T10:20:30
array = [1, "two", {a = [false, 3]}]
[[tables]]
"a.b" = "x"
[[tables]]
"a.b" = "y"
'''
        before = tomllib.loads(original)
        after = self.update(original)
        for k, v in before.items():
            self.assertEqual(after[k], v)

    def test_invalid_input_unchanged(self):
        for data in (b'[broken', b'\xff', b'model_providers = 1', b'[model_providers]\ndeepseek = 2'):
            self.path.write_bytes(data)
            with self.assertRaises((ValueError, UnicodeError)):
                prepare(str(self.path), 'm', 'https://example.invalid')
            self.assertEqual(self.path.read_bytes(), data)

    def test_preparation_precedes_other_writes(self):
        self.assertLess(source.index('codex_candidate = prepare_codex'),
                        source.index('json.dump(d, open(claude'))

    def test_unencodable_candidate_does_not_touch_original(self):
        self.path.write_text('model="old"')
        with self.assertRaises((ValueError, UnicodeError)):
            candidate = prepare(str(self.path), '\ud800', 'https://example.invalid')
            replace(str(self.path), candidate)
        self.assertEqual(self.path.read_text(), 'model="old"')

    def test_replace_failure_preserves_original_and_cleans_temp(self):
        self.path.write_text('model="old"')
        candidate = prepare(str(self.path), 'm', 'https://example.invalid')
        with patch('os.replace', side_effect=OSError('simulated')):
            with self.assertRaises(OSError):
                replace(str(self.path), candidate)
        self.assertEqual(self.path.read_text(), 'model="old"')
        self.assertEqual(list(Path(self.tmp.name).iterdir()), [self.path])

unittest.main()
