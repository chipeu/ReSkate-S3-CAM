"""Run offline validation and create an installable, allowlisted ReSkate plugin ZIP.

Run from any directory: python tools/package_release.py
No files are installed into the game. Existing release ZIPs are never overwritten.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile
import zipfile
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--test', action='store_true', help='Make the explicitly named experimental test ZIP')
ARGS = parser.parse_args()

ROOT = Path(__file__).resolve().parent.parent
MOD = ROOT / 'Dynamic_Camera'
VERSION = json.loads((MOD / 'manifest.json').read_text(encoding='utf-8-sig'))['version_number']
CONFIG = json.loads((ROOT / 'tools/release_config.json').read_text(encoding='utf-8-sig'))
INSTALL_FOLDER = CONFIG['install_folder']
BUILD = f'DynamicCamera-{VERSION}-TEST' if ARGS.test else f'Dynamic_Camera-{VERSION}-ReSkate-{CONFIG["target_runtime"]}'
OUTPUT = ROOT / 'release' / f'{BUILD}.zip'
REPORT = ROOT / 'release' / f'{BUILD}-validation.json'
RUNNER = ROOT / 'tools/luau_run.exe'

def verify_update(archive):
    """Model the pinned launcher's folder-root selection and check external data survives an update."""
    prefix = INSTALL_FOLDER + '/'
    names = archive.namelist()
    assert all(n.startswith(prefix) and not n.lower().endswith('.zip') for n in names)
    markers = [n for n in names if n.rsplit('/', 1)[-1] == 'reskate-plugin.json']
    assert len(markers) == 1 and markers[0].rsplit('/', 1)[0] == INSTALL_FOLDER
    # Launcher/mod_manager.cpp: mod_name selects the content root's folder, not the versioned ZIP basename.
    with tempfile.TemporaryDirectory(prefix='dyncam-package-') as temporary:
        sandbox = Path(temporary).resolve()
        assert sandbox.is_relative_to(Path(tempfile.gettempdir()).resolve())
        installed = sandbox / 'Mods' / INSTALL_FOLDER
        storage = sandbox / 'LocalAppData/ReSkate/Plugins' / INSTALL_FOLDER / 'storage.json'
        preset = sandbox / 'Mods/.reskate_plugin_data' / INSTALL_FOLDER / 'presets/personal.json'
        sentinels = {storage: b'{"enabled":true,"settings":{"keep":"my settings"},"menu_shortcut":"Ctrl+K","release_acknowledgments":{"schema":1,"versions":{"1.2.5":true}}}',
                     preset: b'{"name":"my preset","values":{"keep":42}}'}
        for path, data in sentinels.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        installed.mkdir(parents=True)
        (installed / 'manifest.json').write_text('{"version_number":"1.1.1"}')
        for name in names:
            relative = Path(name.removeprefix(prefix))
            assert not relative.is_absolute() and '..' not in relative.parts
            target = installed / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(name))
        assert json.loads((installed / 'manifest.json').read_text())['version_number'] == VERSION
        assert all(path.read_bytes() == data for path, data in sentinels.items())
        assert [p.name for p in (sandbox / 'Mods').iterdir() if not p.name.startswith('.')] == [INSTALL_FOLDER]
    return dict(installer_target=INSTALL_FOLDER, duplicate_mod_created=False,
                external_settings_preserved=True, external_presets_preserved=True, nested_zip_count=0)

def main():
    if not re.fullmatch(r'\d+\.\d+\.\d+', VERSION):
        raise SystemExit('Manifest version must be three integers')
    if f'App.VERSION = "{VERSION}"' not in (MOD / 'plugin/app.lua').read_text(encoding='utf-8-sig'):
        raise SystemExit('Startup log version must match manifest version')
    readme = (MOD / 'README.md').read_text(encoding='utf-8-sig')
    if not re.search(rf'^Build {re.escape(VERSION)} for ReSkate\b', readme, re.MULTILINE):
        raise SystemExit('README build version must match manifest version')
    notes = (MOD / 'plugin/release_notes.lua').read_text(encoding='utf-8-sig')
    # Approved public notes are independent of internal build versions.
    # Unapproved internal versions must never be required in the public list.
    if not notes.strip():
        raise SystemExit("Local public release-note module is missing")
    if OUTPUT.exists() or REPORT.exists():
        raise SystemExit('Release already exists; choose a new build identifier before packaging')
    if not re.fullmatch(r'[A-Za-z0-9_. -]{1,64}', INSTALL_FOLDER) or INSTALL_FOLDER in ('.', '..'):
        raise SystemExit('Invalid stable installation folder')
    previous_versions = []
    for old_zip in (ROOT / 'release').rglob('*.zip'):
        with zipfile.ZipFile(old_zip) as archive:
            manifests = sorted((n for n in archive.namelist() if n.rsplit('/', 1)[-1] == 'manifest.json'), key=lambda n: n.count('/'))
            if manifests:
                old = json.loads(archive.read(manifests[0]))
                if old.get('name') == 'Dynamic_Camera':
                    previous_versions.append(tuple(map(int, old['version_number'].split('.'))))
    if previous_versions and tuple(map(int, VERSION.split('.'))) <= max(previous_versions):
        raise SystemExit('Increase manifest version_number before making a new patch ZIP')
    if not RUNNER.is_file():
        raise SystemExit('Build tools/luau_run.exe using tools/README.md first')
    manifest = json.loads((MOD / 'reskate-plugin.json').read_text(encoding='utf-8-sig'))
    assert manifest['api'] == 1 and manifest['side'] == 'client'
    assert (MOD / manifest['entry']).is_file()
    checks = [
        ('run_core.lua', []), ('mock_selftest.lua', []), ('test_main.lua', []),
        ('test_ui_126.lua', []),
        ('test_ui_127.lua', []),
        ('test_ui_128.lua', []),
        ('test_glue.lua', ['real']), ('test_manual.lua', []), ('test_offboard.lua', []),
        ('test_snapguard.lua', []), ('test_snaps.lua', []), ('test_diag.lua', []),
        ('test_motion_diag_128.lua', []), ('test_tick_io_132.lua', []),
        ('test_final_pose_1219.lua', []), ('test_hill_framing_1222.lua', []), ('test_slope_landing_1225.lua', []), ('test_landing_bound_1229.lua', []), ('test_vert_lookdown_1231.lua', []), ('test_orbit_reversal_1232.lua', []),
        ('test_dyncam4.lua', []), ('run_parity.lua', ['self']), ('run_parity.lua', ['strict', 'unchanged']),
        ('run_adaptive_parity_129.lua', []),
        # Retired predictive route integration remains tested against its actual shipped source.
        ('test_collision_escape_119.lua', ['legacy_124']),
        ('test_collision_prediction_121.lua', ['legacy_124']),
        ('test_collision_glue_fast_124.lua', ['legacy_124']),
    ]
    results = []
    for script, args in checks:
        if args == ['legacy_124']:
            source = ROOT / 'tests/ref_1124'
        elif script == 'run_parity.lua' and args == ['strict', 'unchanged']:
            # Adaptive probes invalidate the old recorded ray order. Keep the
            # complete pre-adaptive oracle strict on the actual shipped source.
            source = ROOT / 'tests/ref_1128'
        else:
            source = MOD / 'plugin'
        command = [str(RUNNER), '-I', str(source), '-I', str(ROOT / 'tests'),
                   '-I', str(ROOT / 'tools/trace/out'), str(ROOT / 'tests' / script), *args]
        run = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        output = run.stdout + run.stderr
        print(output, end='')
        results.append(dict(test=script, args=args, source=str(source.relative_to(ROOT)), exit=run.returncode, output=output))
        if run.returncode:
            raise SystemExit(f'Validation failed: {script}; no ZIP produced')

    # Ship only package metadata/assets and direct Luau modules, never the full repo or release folder.
    names = ['manifest.json', 'reskate-plugin.json', 'README.md', 'CHANGELOG.md', 'LICENSE', 'icon.png']
    names += [p.relative_to(MOD).as_posix() for p in sorted((MOD / 'plugin').glob('*.lua'))]
    actual = {p.relative_to(MOD).as_posix() for p in MOD.rglob('*') if p.is_file()}
    if actual != set(names):
        raise SystemExit(f'Unexpected or missing shipping files: {actual.symmetric_difference(names)}')
    payloads = {name: (MOD / name).read_bytes() for name in names}
    # Avoid publishing a module with a missing literal require target.
    for name, data in payloads.items():
        if name.endswith('.lua'):
            for required in re.findall(r'require\("([\w_]+)"\)', data.decode('utf-8-sig')):
                assert f'plugin/{required}.lua' in payloads, required
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open('xb') as stream, zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(payloads):
            info = zipfile.ZipInfo(INSTALL_FOLDER + '/' + name, date_time=(2026, 10, 29, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, payloads[name])
    with zipfile.ZipFile(OUTPUT) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == {INSTALL_FOLDER + '/' + name for name in payloads}
        assert all(archive.read(INSTALL_FOLDER + '/' + name) == data for name, data in payloads.items())
        update_check = verify_update(archive)
    parity_source = (ROOT / 'tests/run_parity.lua').read_text()
    revised_block = parity_source.split('local landing_revisions = {', 1)[1].split('}', 1)[0]
    landing_ids = re.findall(r'(trace_\w+)\s*=\s*true', revised_block)
    parity_policy = dict(reference_source='actual shipped 1.1.28', reference_full_unchanged_scenarios=17, reference_strict_pre_touchdown_prefixes=16,
                         current_scope='run_adaptive_parity_129.lua: strict current frames before adaptive ray ownership; active framing tested against solids',
                         current_ramp_policy='Pop On ordered rays checked strictly before verified ramp entry; current full ramp geometry in test_popon_vert_121',
                         current_turn_follow_revision=['trace_carve_horizontal10', 'trace_carve_horizontal10_144', 'trace_carve_h5_follow4: intentional travel yaw; test_turn_follow_134'],
                         revised_landing_scenarios=landing_ids, golden_files_rewritten=False,
                         post_touchdown_playback='Full diagnostic only: old recorded ray answers do not establish revised geometric correctness',
                         prior_fixed_fov_revisions=['trace_mixed_fixed_low', 'trace_mixed_fixed_high_144'])
    report = dict(build=BUILD, target=f'ReSkate {CONFIG["target_runtime"]} / plugin API 1',
                  gameplay_tested=False, experimental_test=ARGS.test, tests=results, parity_policy=parity_policy, update_check=update_check,
                  zip_sha256=hashlib.sha256(OUTPUT.read_bytes()).hexdigest(),
                  files={name: hashlib.sha256(data).hexdigest() for name, data in sorted(payloads.items())})
    with REPORT.open('x', encoding='utf-8') as file:
        json.dump(report, file, indent=2)
    print(f'PACKAGED {OUTPUT} ({len(payloads)} files)')
    print(f'SHA256 {report["zip_sha256"]}')

if __name__ == '__main__':
    main()
