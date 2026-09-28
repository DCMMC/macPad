"""Executable tests of bounded CodeDirectory parsing and cache invalidation."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('boot_trust',
    ROOT / 'layout/usr/macOS/bin/macws_boot_trust.py')
trust = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trust)


def directory(hash_type=2):
    sizes = {1: 20, 2: 32, 3: 20, 4: 48}
    size = sizes[hash_type]
    return struct.pack('>9I4BI', 0xfade0c02, 48 + size, 0x20001,
                       0, 48, 44, 0, 1, 4096, size, hash_type, 0, 12, 0) + b'app\0' + bytes(size)


def macho(subtype=0, codes=None, endian='<', cpu=0x0100000c):
    codes = [directory()] if codes is None else codes
    entries, content = b'', b''
    start = 12 + 8 * len(codes)
    for index, code in enumerate(codes):
        entries += struct.pack('>II', 0 if index == 0 else 0xfff + index,
                               start + len(content))
        content += code
    signature = struct.pack('>III', 0xfade0cc0, start + len(content), len(codes)) + entries + content
    header = struct.pack(endian + '8I', 0xfeedfacf, cpu, subtype, 2, 1, 16, 0, 0)
    command = struct.pack(endian + '4I', 0x1d, 16, 48, len(signature))
    return header + command + signature


def fat(slices, wide=False, endian='>'):
    length = 32 if wide else 20
    offset = 8 + len(slices) * length
    entries, content = b'', b''
    for subtype, data in slices:
        values = [0x0100000c, subtype, offset + len(content), len(data), 0]
        if wide:
            values += [0]
        entries += struct.pack(endian + ('IIQQII' if wide else 'IIIII'), *values)
        content += data
    return struct.pack(endian + 'II', 0xcafebabf if wide else 0xcafebabe,
                       len(slices)) + entries + content


class BootTrustTests(unittest.TestCase):
    def hashes(self, data):
        return trust.code_hashes(io.BytesIO(data), len(data))

    def test_hash_types_and_truncation(self):
        for kind, algorithm in ((1, 'sha1'), (2, 'sha256'), (3, 'sha256'), (4, 'sha384')):
            with self.subTest(kind=kind):
                blob = directory(kind)
                self.assertEqual(self.hashes(macho(codes=[blob]))[0]['hash'],
                                 hashlib.new(algorithm, blob).hexdigest()[:40])

    def test_best_alternate_directory(self):
        result = self.hashes(macho(codes=[directory(1), directory(2)]))
        self.assertEqual(result[0]['type'], 2)

    def test_fat_endianness_and_64_bit_offsets(self):
        for wide in (False, True):
            for endian in ('<', '>'):
                data = fat([(0, macho()), (0x80000002, macho(0x80000002))], wide, endian)
                self.assertEqual([x['arch'] for x in self.hashes(data)], ['arm64', 'arm64e'])

    def test_big_endian_thin(self):
        self.assertEqual(self.hashes(macho(endian='>'))[0]['arch'], 'arm64')

    def test_non_code_and_other_arch_ignored(self):
        for data in (b'', b'abc', b'ordinary data', macho(cpu=0x01000007)):
            self.assertEqual(self.hashes(data), [])

    def test_unsigned_macho_ignored_not_fabricated(self):
        data = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0)
        self.assertEqual(self.hashes(data), [])

    def test_fat_arch_mismatch_rejected(self):
        with self.assertRaises(trust.InvalidMachO):
            self.hashes(fat([(2, macho(0))]))

    def test_truncated_code_rejected(self):
        data = macho()
        for size in (4, 31, 45, len(data) - 1):
            with self.subTest(size=size), self.assertRaises(trust.InvalidMachO):
                self.hashes(data[:size])

    def test_malformed_offsets_and_lengths_rejected(self):
        # header ncmds, sizeofcmds; LC length, sig offset/size; SuperBlob
        # length/count/index; CD length, hashOffset, unknown hashType.
        for offset, value, endian in ((16, 0xffffffff, '<'), (20, 0xffffffff, '<'),
                (36, 0, '<'), (40, 0, '<'), (44, 0xffffffff, '<'),
                (52, 0xffffffff, '>'), (56, 0xffffffff, '>'),
                (64, 1, '>'), (72, 0xffffffff, '>'), (84, 0xffffffff, '>')):
            data = bytearray(macho())
            struct.pack_into(endian + 'I', data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(trust.InvalidMachO):
                self.hashes(bytes(data))
        data = bytearray(macho())
        data[68 + 37] = 99
        with self.assertRaises(trust.InvalidMachO):
            self.hashes(bytes(data))

    def test_cache_reuses_unchanged_and_invalidates_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'app'
            path.write_bytes(macho())
            records, hashes, _ = trust.scan([str(path)], {})
            with patch.object(trust, 'code_hashes', side_effect=AssertionError('unexpected parse')):
                _, again, counts = trust.scan([str(path)], records)
            self.assertEqual(again, hashes)
            self.assertEqual(counts['cached'], 1)
            replacement = Path(folder) / 'new'
            replacement.write_bytes(macho(codes=[directory(1)]))
            os.replace(replacement, path)
            _, changed, counts = trust.scan([str(path)], records)
            self.assertNotEqual(changed, hashes)
            self.assertEqual(counts['cached'], 0)

    def test_cache_invalidates_in_place_write_and_corrupt_records(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'app'
            path.write_bytes(macho())
            records, hashes, _ = trust.scan([str(path)], {})
            changed = bytearray(path.read_bytes())
            changed[-1] = 1
            path.write_bytes(changed)
            new, changed_hashes, counts = trust.scan([str(path)], records)
            self.assertNotEqual(changed_hashes, hashes)
            self.assertEqual(counts['cached'], 0)
            new[str(path)]['codes'] = [{'hash': 'invalid'}]
            _, _, counts = trust.scan([str(path)], new)
            self.assertEqual(counts['cached'], 0)

    def test_manifest_is_atomic_and_unsafe_cache_ignored(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'cache.json'
            trust.save_cache(str(path), {})
            self.assertEqual(trust.load_cache(str(path)), {})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.write_text(json.dumps({'schema': trust.CACHE_SCHEMA, 'files': {'bad': 1}}))
            path.chmod(0o666)
            self.assertEqual(trust.load_cache(str(path)), {})
            path.unlink()
            path.symlink_to(Path(folder) / 'missing')
            self.assertEqual(trust.load_cache(str(path)), {})

    def test_live_membership_never_inferred_from_manifest(self):
        with patch.object(trust, 'trusted_hashes', return_value={'a' * 40}) as query:
            self.assertEqual(trust.restore({'a' * 40}), (0, 'already-trusted'))
            query.assert_called_once()

    def test_resource_index_does_not_hide_new_code(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'resource'
            path.write_bytes(b'ordinary resource')
            index = trust.ResourceIndex(str(Path(folder) / 'index.sqlite'))
            try:
                records, hashes, _ = trust.scan([str(path)], {}, resources=index)
                self.assertFalse(hashes)
                with patch.object(trust, 'code_hashes', side_effect=AssertionError('read resource again')):
                    _, _, counts = trust.scan([str(path)], records, resources=index)
                self.assertEqual(counts['resource_hits'], 1)
                path.write_bytes(macho())
                _, hashes, counts = trust.scan([str(path)], records, resources=index)
                self.assertTrue(hashes)
                self.assertEqual(counts['resource_hits'], 0)
            finally:
                index.close()

    def test_no_readonly_index_creation_or_update(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'absent.sqlite'
            index = trust.ResourceIndex(str(path), readonly=True)
            index.remember('some-path', [0, 0, 0, 0, 0])
            index.close()
            self.assertFalse(path.exists())

    def test_boot_closure_is_not_deferred_or_narrowed(self):
        script = (ROOT / 'layout/usr/macOS/bin/macos_gui.sh').read_text()
        method = script.split('restore_cold_boot_trust() {', 1)[1].split('\n}', 1)[0]
        for required in ('Hydra.framework', 'steamapps/macws-runtime',
                         '/Applications/*.app', 'launchservicesd.dylib',
                         '/var/jb/usr/macOS/bin/launchservicesd',
                         '/usr/sbin/filecoordinationd',
                         'opt/local/libexec/macws-cursor',
                         '"$ROOTFS$DEFAULTS_BIN"',
                         '"$ROOTFS$LSREGISTER_BIN"',
                         '"$ROOTFS$VNC_BIN"',
                         '"$ROOTFS$TERM_BIN"',
                         '--resource-index', '--manifest'):
            self.assertIn(required, method)
        self.assertLess(method.index('"$@" || return 1'),
                        method.index('BASE_TRUST_READY=1'))

    def test_fresh_rootfs_installs_recoverable_launchservices_loader(self):
        maintainer = (ROOT / 'layout/DEBIAN/postinst').read_text()
        transaction = maintainer.split(
            'install_launchservicesd_loader() {', 1
        )[1].split('\n}', 1)[0]
        self.assertIn('/var/jb/usr/macOS/bin/launchservicesd', transaction)
        self.assertIn('/var/jb/usr/macOS/Frameworks/launchservicesd.dylib',
                      transaction)
        self.assertIn('launchservicesd.macws-original', transaction)
        self.assertIn('cmp -s "$loader" "$target"', transaction)
        self.assertIn('mv -f "$temporary" "$target"', transaction)
        self.assertIn('trust_installed_macho "$target"', transaction)
        self.assertIn('trust_installed_macho "$payload"', transaction)
        self.assertIn('install_launchservicesd_loader || exit 1', maintainer)

        repair = (ROOT / 'layout/usr/macOS/bin/postinst.sh').read_text()
        self.assertIn('LAUNCHSERVICES_TARGET=', repair)
        self.assertIn('${LAUNCHSERVICES_TARGET}.macws-original', repair)
        self.assertIn('cmp -s "$LAUNCHSERVICES_LOADER" '
                      '"$LAUNCHSERVICES_TARGET"', repair)

    def test_fresh_rootfs_prepares_early_windowing_processes(self):
        maintainer = (ROOT / 'layout/DEBIAN/postinst').read_text()
        self.assertIn('ensure_filecoordinationd_signature() {', maintainer)
        self.assertIn('${target}.macws-original', maintainer)
        self.assertIn('ldid -S"$ENTITLEMENTS" -M "$temporary"', maintainer)
        self.assertIn('trust_installed_macho "$target"', maintainer)
        self.assertIn('prepare_windowserver_runtime() {', maintainer)
        self.assertIn('prepare_ventura_windowserver.py', maintainer)
        self.assertIn('prepare_windowserver_runtime || exit 1', maintainer)

        repair = (ROOT / 'layout/usr/macOS/bin/postinst.sh').read_text()
        self.assertIn('ensure_filecoordinationd_signature || exit 1', repair)
        self.assertIn('prepare_windowserver_runtime || exit 1', repair)
        makefile = (ROOT / 'Makefile').read_text()
        self.assertIn('prepare_ventura_windowserver.py', makefile)

    def test_missing_hash_must_really_register_and_verify(self):
        class Add:
            def __call__(self, buffer, size):
                self.called = (bytes(buffer).hex(), size)
                return 0
        class Library:
            jbclient_root_trustcache_add_cdhash = Add()
        library = Library()
        value = 'a' * 40
        with patch.object(trust, 'trusted_hashes', side_effect=[set(), {value}]), \
                patch.object(trust.ctypes, 'CDLL', return_value=library):
            self.assertEqual(trust.restore({value}), (1, 'libjailbreak'))
            self.assertEqual(library.jbclient_root_trustcache_add_cdhash.called, (value, 20))
        with patch.object(trust, 'trusted_hashes', return_value=set()), \
                patch.object(trust.ctypes, 'CDLL', return_value=library):
            with self.assertRaisesRegex(ValueError, 'verification failed'):
                trust.restore({value})


if __name__ == '__main__':
    unittest.main()
