"""Unimplemented conformance contracts; replace each failure with its real fixture."""
import unittest


class CompatibilityTests(unittest.TestCase):
    def test_volume_in_use(self):
        'DC-043: Force removal of a volume referenced by running or stopped container is refused and checksum survives.'
        self.fail('UNIMPLEMENTED DC-043; no runtime compatibility evidence')

    def test_volume_copyup(self):
        'DC-044: Named and anonymous volume population, nocopy, UID and mode match reference behavior.'
        self.fail('UNIMPLEMENTED DC-044; no runtime compatibility evidence')

    def test_archive_ownership(self):
        'DC-045: Copy in and out preserve expected UID, GID, mode, links and directory-content semantics.'
        self.fail('UNIMPLEMENTED DC-045; no runtime compatibility evidence')

    def test_host_file_events(self):
        'DC-046: Host create, atomic save, rename and delete emit events and trigger application reload.'
        self.fail('UNIMPLEMENTED DC-046; no runtime compatibility evidence')

    def test_host_permissions(self):
        'DC-047: Parallel non-root creates and renames preserve permission semantics without intermittent EACCES.'
        self.fail('UNIMPLEMENTED DC-047; no runtime compatibility evidence')

    def test_filesystem_metadata(self):
        'DC-048: Exercise xattrs, hardlinks, sparse files, locking and fsync on supported mount types.'
        self.fail('UNIMPLEMENTED DC-048; no runtime compatibility evidence')

    def test_mount_paths(self):
        'DC-049: Bind ExternalSSD paths with spaces and Unicode; distinguish host case sensitivity from guest volume behavior.'
        self.fail('UNIMPLEMENTED DC-049; no runtime compatibility evidence')

    def test_tmpfs_options(self):
        'DC-050: Tmpfs size, UID, GID and mode apply even when image target directory is absent.'
        self.fail('UNIMPLEMENTED DC-050; no runtime compatibility evidence')
