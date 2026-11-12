import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import port
import test_mac_bundle


class PortTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_mac_bundle.MacBundleTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        self.arguments = ['--profile', str(f.profile), '--work', str(f.root / 'work'),
                          '--extracted', str(f.root), '--patched', str(f.patched),
                          '--shaders', str(f.shaders), '--font', str(f.font),
                          '--output', str(f.output)]

    def args(self, command='build', extra=()):
        return port.parser().parse_args([command, *self.arguments, *extra])

    def test_plan_does_not_write(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            port.main(['plan', *self.arguments])
        plan = json.loads(output.getvalue())
        self.assertEqual(plan['platform'], 'nx')
        self.assertTrue(plan['requires_gameplay_validation'])
        self.assertFalse((self.fixture.root / 'work').exists())

    def test_external_profile_build_and_report(self):
        f = self.fixture
        original = (f.profile / 'game.tsv').read_bytes()
        seen = {}
        def host(repo, output, env, logs, profile):
            seen.update(profile=profile, env=env)
            output.parent.mkdir(parents=True)
            shutil.copy2(f.host, output)
        with patch.object(port.platform, 'system', return_value='Darwin'), \
                patch.object(port.platform, 'machine', return_value='arm64'), \
                patch.object(port.shutil, 'which', return_value='/usr/bin/fixture'), \
                patch.object(port.common, 'build_mac_host', side_effect=host), \
                patch.object(port.bundle, 'clone', side_effect=shutil.copytree), \
                patch.object(port.bundle, 'run'), \
                patch.dict(os.environ, {'IOSOUT': '/should/not/be/used', 'DM_NVN_FACTDUMP': '/no'}), \
                contextlib.redirect_stdout(io.StringIO()):
            port.build(self.args())
        self.assertNotEqual(seen['profile'].dir, f.profile)
        self.assertEqual(seen['env']['DM_GAME'], str(seen['profile'].dir))
        self.assertNotIn('IOSOUT', seen['env'])
        self.assertNotIn('DM_NVN_FACTDUMP', seen['env'])
        self.assertEqual((f.profile / 'game.tsv').read_bytes(), original)
        report = json.loads((f.root / 'work/last-build.json').read_text())
        self.assertEqual(report['status'], 'complete')
        self.assertEqual(report['result']['shader_count'], 1)
        self.assertTrue((f.output / 'Contents/MacOS/dmhost').is_file())

    def test_unknown_version_stops_before_work(self):
        with self.assertRaisesRegex(port.bundle.BundleError, 'unknown version'):
            port.describe(self.args(extra=['--version', 'v999']))
        self.assertFalse((self.fixture.root / 'work').exists())

    def test_unknown_nx2_shader_input_is_not_guessed(self):
        f = self.fixture
        path = f.profile / 'game.tsv'
        path.write_text(path.read_text().replace('platform\tnx', 'platform\tnx2'))
        args = self.args()
        args.shaders = None
        with self.assertRaisesRegex(port.bundle.BundleError, 'NX2 needs'):
            port.describe(args)

    def test_work_stays_outside_repository(self):
        args = self.args()
        args.work = port.REPO / 'untracked-game'
        with self.assertRaisesRegex(port.bundle.BundleError, 'outside'):
            port.describe(args)

    def test_failed_build_records_stage_and_keeps_existing_app(self):
        f = self.fixture
        f.output.mkdir(parents=True)
        (f.output / 'sentinel').write_text('old app')
        with patch.object(port.platform, 'system', return_value='Darwin'), \
                patch.object(port.platform, 'machine', return_value='arm64'), \
                patch.object(port.shutil, 'which', return_value='/usr/bin/fixture'), \
                patch.object(port.common, 'build_mac_host', side_effect=port.common.BuildError('compiler failed')), \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(port.common.BuildError, 'compiler failed'):
                port.build(self.args(extra=['--replace']))
        self.assertEqual((f.output / 'sentinel').read_text(), 'old app')
        reports = list((f.root / 'work/builds').glob('*/status.json'))
        self.assertEqual(len(reports), 1)
        report = json.loads(reports[0].read_text())
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['stage'], 'Build native Mac host')


if __name__ == '__main__':
    unittest.main()
