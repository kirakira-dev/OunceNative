import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mac_bundle as bundle


class MacBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mac bundle's ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.profile = self.root / 'external profiles/0100000000000000'
        self.profile.mkdir(parents=True)
        self.profile.joinpath('game.tsv').write_text(
            'title_id\t0100000000000000\nplatform\tnx\nname\tFixture Game\n'
            'package\tv0\nbuild\tv0\t1.0.0\tmain=' + 'a' * 32 + '\n'
            'modules\tmain\nromfs_marker\tassets/marker\n')
        self.profile.joinpath('dmsh_chain.h').write_text('#define DMSH_CHAIN "123abc"\n')
        self.profile.joinpath('shader_map.tsv').write_text(
            'package\tindex\tstage\tdm_ctl_sha16\tsource\n'
            'example.bin\t0\tvertex\t0123456789abcdef\tfixture\n')
        self.profile.joinpath('c1_full.tsv').write_text('# chain b-123abc\n')
        self.host = self.root / 'host'
        self.host.write_text('fixture executable')
        self.host.chmod(0o755)
        self.patched = self.root / 'rewritten'
        self.patched.mkdir()
        self.patched.joinpath('main.patched.bin').write_bytes(b'fixture code')
        self.patched.joinpath('main.fixups.tsv').write_text('# BUILD_ID\t' + 'a' * 32 + '\n')
        self.romfs = self.root / 'RomFS'
        self.romfs.joinpath('assets').mkdir(parents=True)
        self.romfs.joinpath('assets/marker').write_text('fixture assets')
        self.shaders = self.root / 'shader package'
        self.shaders.mkdir()
        self.shaders.joinpath('0123456789abcdef_b.metallib').write_bytes(b'fixture library')
        self.shaders.joinpath('0123456789abcdef_b.json').write_text('{"chain":"123abc"}')
        self.font = self.root / 'font.ttf'
        self.font.write_bytes(b'fixture font')
        self.output = self.root / 'output/Fixture Game.app'
        self.args = (bundle.game.load(str(self.profile)), 'v0', self.host,
                     self.patched, self.romfs, self.shaders, self.font)

    def package(self, **kwargs):
        with patch.object(bundle, 'clone', side_effect=shutil.copytree), patch.object(bundle, 'run'):
            return bundle.package(*self.args, self.output, **kwargs)

    def test_external_profile_and_resources(self):
        result = self.package()
        contents = self.output / 'Contents'
        self.assertTrue(result['signature_verified'])
        self.assertFalse(result['gameplay_validated'])
        self.assertEqual((contents / 'games' / self.profile.name / 'game.tsv').read_bytes(),
                         (self.profile / 'game.tsv').read_bytes())
        self.assertEqual((contents / 'Resources/RomFS/assets/marker').read_text(), 'fixture assets')
        self.assertEqual((contents / 'Resources/shaders/b-123abc/0123456789abcdef_b.metallib').read_bytes(),
                         b'fixture library')
        info = plistlib.loads((contents / 'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleName'], 'Fixture Game')
        self.assertEqual(info['DMNativeEnvironment']['DM_SAVE'], '${APP_SUPPORT}/save')

    def test_build_mismatch_rejected_without_output(self):
        self.patched.joinpath('main.fixups.tsv').write_text('# BUILD_ID\t' + 'b' * 32 + '\n')
        with self.assertRaisesRegex(bundle.BundleError, 'build ID'):
            self.package()
        self.assertFalse(self.output.parent.exists())

    def test_missing_shader_requires_explicit_diagnostic_flag(self):
        self.shaders.joinpath('0123456789abcdef_b.metallib').unlink()
        with self.assertRaisesRegex(bundle.BundleError, 'libraries missing'):
            self.package()
        report = self.package(allow_incomplete=True)
        self.assertEqual(report['missing_shader_keys'], ['0123456789abcdef'])

    def test_wrong_shader_chain_rejected(self):
        self.shaders.joinpath('0123456789abcdef_b.json').write_text('{"chain":"987def"}')
        with self.assertRaisesRegex(bundle.BundleError, 'chain mismatch'):
            self.package()

    def test_existing_app_is_retained_on_sign_failure(self):
        self.output.mkdir(parents=True)
        (self.output / 'sentinel').write_text('old app')
        def fail_sign(command):
            if command[0] == 'codesign':
                raise subprocess.CalledProcessError(1, command)
        with patch.object(bundle, 'clone', side_effect=shutil.copytree), \
                patch.object(bundle, 'run', side_effect=fail_sign):
            with self.assertRaises(subprocess.CalledProcessError):
                bundle.package(*self.args, self.output, replace=True)
        self.assertEqual((self.output / 'sentinel').read_text(), 'old app')
        self.assertEqual(list(self.output.parent.iterdir()), [self.output])

    def test_replacement_keeps_backup(self):
        self.output.mkdir(parents=True)
        (self.output / 'sentinel').write_text('old app')
        report = self.package(replace=True)
        self.assertEqual((Path(report['backup']) / 'sentinel').read_text(), 'old app')
        self.assertTrue((self.output / 'Contents/Info.plist').is_file())

    def test_existing_output_requires_replace(self):
        self.output.mkdir(parents=True)
        with self.assertRaisesRegex(bundle.BundleError, 'already exists'):
            self.package()

    def test_dry_run_writes_nothing(self):
        report = self.package(dry_run=True)
        self.assertEqual(report['shader_count'], 1)
        self.assertFalse(self.output.parent.exists())

    def test_vulkan_and_dlc_layout(self):
        with (self.profile / 'game.tsv').open('a') as stream:
            stream.write('graphics\tvulkan\n')
        self.args = (bundle.game.load(str(self.profile)), *self.args[1:])
        self.shaders.joinpath('vk_shaders.metallib').write_bytes(b'vk fixture')
        self.shaders.joinpath('vk_shaders.tsv').write_text('# fixture\n')
        aoc = self.root / 'aoc'
        (aoc / '2').mkdir(parents=True)
        (aoc / '2/content').write_text('DLC')
        self.package(aoc=aoc)
        contents = self.output / 'Contents'
        info = plistlib.loads((contents / 'Info.plist').read_bytes())
        self.assertEqual(info['DMNativeEnvironment']['DM_AOC_DIR'], '${RESOURCES}/aoc')
        self.assertEqual((contents / 'Resources/aoc/2/content').read_text(), 'DLC')
        self.assertTrue((contents / 'Resources/shaders/vk/vk_shaders.metallib').is_file())

    def test_output_cannot_contain_inputs(self):
        with self.assertRaisesRegex(bundle.BundleError, 'overlaps'):
            bundle.package(*self.args, self.romfs / 'Bad.app')

    def test_publish_rolls_back_on_rename_failure(self):
        self.output.mkdir(parents=True)
        (self.output / 'sentinel').write_text('old app')
        with self.assertRaises(FileNotFoundError):
            bundle.publish(self.root / 'nonexistent.app', self.output, True)
        self.assertEqual((self.output / 'sentinel').read_text(), 'old app')


if __name__ == '__main__':
    unittest.main()
