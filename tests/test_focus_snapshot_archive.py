"""Frozen inputs remain readable without entering recursive project scans."""

import errno
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import uuid
import zipfile

import test_cycle as fixtures
from cycle_state import Blocked
from focus_pair_view import materialize, artifact, read_record, ViewInspector
from focus_snapshot_archive import compact_legacy_views, read_source, archive_path


class SnapshotArchiveTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown

    def view(self, legacy=False):
        # Bytes, not text: Windows text mode writes CRLF, and the tests compare exact bytes.
        (self.root / 'App.csproj').write_bytes(b'<Project/>\n')
        (self.root / 'Example.cs').write_bytes(b'class Example {}\n')
        pair = {'id': uuid.uuid4().hex, 'phase': 'final', 'snapshot': self.repo.snapshot()}
        view = materialize(self.cycle, pair)
        if legacy:
            root = Path(view['root'])
            with zipfile.ZipFile(archive_path(root)) as archive:
                for name in archive.namelist():
                    p = root / name
                    p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_bytes(archive.read(name))
            archive_path(root).unlink()
            view.pop('storage')
            pair['view'] = artifact(self.store, pair['view']['path'], view)
        return pair, view

    def test_archive_does_not_add_projects_or_source_to_recursive_scans(self):
        pair, view = self.view()
        self.assertEqual(list(self.root.rglob('*.csproj')), [self.root / 'App.csproj'])
        self.assertEqual(list(self.root.rglob('*.cs')), [self.root / 'Example.cs'])
        self.assertEqual(read_source(view, 'App.csproj'), b'<Project/>\n')
        self.assertTrue(Path(view['root']).is_dir())
        self.assertFalse(list(Path(view['root']).iterdir()))
        self.assertEqual(materialize(self.cycle, pair), view)

    def test_list_read_and_diff_keep_logical_names(self):
        _, view = self.view()
        reader = ViewInspector(view)
        for operation, name in (('list', '.'), ('read', 'Example.cs'), ('diff', 'Example.cs')):
            with self.subTest(operation=operation):
                result = reader.call({'tool': 'focus_inspect', 'arguments': {
                    'operation': operation, 'path': name, 'offset': 0, 'limit': 20}})
                self.assertTrue(result['success'], result)
        self.assertFalse(reader.call({'tool': 'focus_inspect', 'arguments': {
            'operation': 'read', 'path': '../source.zip', 'offset': 0, 'limit': 20}})['success'])

    def test_migration_preserves_sealed_manifest_snapshot_and_all_bytes(self):
        pair, view = self.view(legacy=True)
        snapshot = self.repo.snapshot()
        manifest = self.store.directory / pair['view']['path']
        original = manifest.read_bytes()
        expected = {name: read_source(view, name) for name in view['files']}
        receipts = compact_legacy_views(self.store, lambda: None)
        self.assertEqual(len(receipts), 1)
        self.assertEqual(manifest.read_bytes(), original)
        self.assertEqual(read_record(self.store, pair['view']), view)
        self.assertEqual(self.repo.snapshot(), snapshot)
        self.assertEqual(list(self.root.rglob('*.csproj')), [self.root / 'App.csproj'])
        self.assertEqual({name: read_source(view, name) for name in view['files']}, expected)
        self.assertEqual(compact_legacy_views(self.store, lambda: None), receipts)

    def test_archive_integrity_is_checked_when_inspecting(self):
        _, view = self.view()
        archive_path(Path(view['root'])).write_bytes(b'corrupt zip')
        with self.assertRaisesRegex(ValueError, 'archive cannot be read'):
            read_source(view, 'App.csproj')

    def test_migration_resumes_after_partial_retirement(self):
        pair, view = self.view(legacy=True)
        root = Path(view['root'])
        unlink = Path.unlink
        retired = []
        def interrupt(path, *a, **kw):
            if path.is_relative_to(root):
                if retired:
                    raise OSError('simulated interrupted retirement')
                retired.append(path)
            return unlink(path, *a, **kw)
        with patch.object(Path, 'unlink', interrupt), self.assertRaisesRegex(Blocked, 'interrupted retirement'):
            compact_legacy_views(self.store, lambda: None)
        self.assertEqual(len(retired), 1)
        self.assertTrue(read_source(view, retired[0].relative_to(root).as_posix()))
        receipt = (root.parent / 'source-archive.json').read_bytes()
        compact_legacy_views(self.store, lambda: None)
        self.assertEqual((root.parent / 'source-archive.json').read_bytes(), receipt)
        self.assertEqual(list(self.root.rglob('*.csproj')), [self.root / 'App.csproj'])

    def test_unknown_or_changed_loose_files_are_preserved(self):
        for changed in (False, True):
            with self.subTest(changed=changed):
                _, view = self.view(legacy=True)
                root = Path(view['root'])
                name = 'App.csproj' if changed else 'operator.txt'
                (root / name).write_bytes(b'preserve me')
                with self.assertRaisesRegex(Blocked, 'Unexpected or changed'):
                    compact_legacy_views(self.store, lambda: None)
                self.assertEqual((root / name).read_bytes(), b'preserve me')
                self.assertFalse(archive_path(root).exists())
                # Restore this fixture for the next independent case.
                if changed:
                    (root / name).write_bytes(b'<Project/>\n')
                else:
                    (root / name).unlink()

    def test_corrupt_existing_archive_never_retires_loose_copies(self):
        _, view = self.view(legacy=True)
        root = Path(view['root'])
        with zipfile.ZipFile(archive_path(root), 'w') as archive:
            archive.writestr('App.csproj', b'wrong')
        with self.assertRaises(Blocked):
            compact_legacy_views(self.store, lambda: None)
        self.assertEqual((root / 'App.csproj').read_bytes(), b'<Project/>\n')

    def test_manifest_cannot_move_migration_outside_runtime_source_root(self):
        pair, view = self.view(legacy=True)
        view['root'] = str(self.root)
        artifact(self.store, pair['view']['path'], view)
        with self.assertRaisesRegex(Blocked, 'runtime-owned location'):
            compact_legacy_views(self.store, lambda: None)
        self.assertEqual((self.root / 'App.csproj').read_bytes(), b'<Project/>\n')

    def test_legacy_symlink_is_not_followed_or_retired(self):
        _, view = self.view(legacy=True)
        path = Path(view['root']) / 'App.csproj'
        path.unlink()
        try:
            path.symlink_to(self.root / 'App.csproj')
        except OSError:
            self.skipTest('symlink creation unavailable')
        with self.assertRaisesRegex(Blocked, 'symlinks'):
            compact_legacy_views(self.store, lambda: None)
        self.assertTrue(path.is_symlink())

    def test_missing_legacy_file_is_not_silently_dropped(self):
        _, view = self.view(legacy=True)
        (Path(view['root']) / 'App.csproj').unlink()
        with self.assertRaisesRegex(Blocked, 'Incomplete legacy'):
            compact_legacy_views(self.store, lambda: None)

    def test_runtime_storage_symlink_becomes_preserving_blocker(self):
        directory = self.store.directory / 'pair-reviews'
        target = self.root / 'operator-storage'
        target.mkdir()
        original = target / 'keep.csproj'
        original.write_text('operator content')
        directory.parent.mkdir(parents=True, exist_ok=True)
        if directory.exists():
            directory.rmdir()
        try:
            directory.symlink_to(target, target_is_directory=True)
        except OSError as error:
            if error.errno not in (errno.EPERM, errno.EACCES, errno.ENOTSUP):
                raise
            self.skipTest('symlink creation unavailable')
        with self.assertRaisesRegex(Blocked, 'symlinks') as result:
            compact_legacy_views(self.store, lambda: None)
        self.assertEqual(result.exception.code, 'snapshot-storage')
        self.assertEqual(original.read_text(), 'operator content')
        self.assertTrue(directory.is_symlink())

    def test_unsealed_legacy_copies_are_preserved_and_reported(self):
        pair, view = self.view(legacy=True)
        (self.store.directory / pair['view']['path']).unlink()
        with self.assertRaisesRegex(Blocked, 'Unsealed legacy'):
            compact_legacy_views(self.store, lambda: None)
        self.assertEqual((Path(view['root']) / 'App.csproj').read_bytes(), b'<Project/>\n')

    def test_runtime_records_migration_without_changing_review_credit(self):
        self.view(legacy=True)
        original = json.loads(json.dumps(self.state))
        self.cycle.prepare_snapshot_storage()
        reference = self.state['snapshot_storage']
        self.assertEqual({k: v for k, v in self.state.items() if k not in ('snapshot_storage', 'updated')},
                         {k: v for k, v in original.items() if k != 'updated'})
        self.cycle.prepare_snapshot_storage()
        self.assertEqual(self.state['snapshot_storage'], reference)
        self.assertEqual(len(read_record(self.store, reference)['views']), 1)


if __name__ == '__main__':
    unittest.main()
