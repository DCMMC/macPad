"""Offline regression coverage for binary edits and account lifecycle ownership."""
import ast
import copy
import json
import os
import struct
import unittest
from pathlib import Path
from unittest.mock import Mock

import build
import install


def image(padding=128):
    """One executable section and UUID, with controlled header padding."""
    segment_size = 72 + 80
    command_size = segment_size + 24
    section_offset = 32 + command_size + padding
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 2, 2, 2, command_size, 0, 0)
    segment = struct.pack('<II16sQQQQIIII', 0x19, segment_size, b'__TEXT',
                          0x100000000, 4096, 0, 4096, 7, 5, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT',
                          0x100000000 + section_offset, 4, section_offset,
                          2, 0, 0, 0x80000400, 0, 0, 0)
    uuid = struct.pack('<II16s', 0x1b, 24, bytes(range(16)))
    return header + segment + section + uuid + bytes(padding) + b'CODE'


class BinaryTests(unittest.TestCase):
    def test_load_edge_preserves_executable_section(self):
        original = image()
        edited = build.append(original, ['@loader_path/ns'])
        before, after = build.parse(original), build.parse(edited)
        self.assertEqual(before['sections'], after['sections'])
        self.assertEqual(before['uuid'], after['uuid'])
        self.assertEqual(after['dependencies'], [{'cmd': '0xc', 'name': '@loader_path/ns'}])

    def test_repeated_dependency_does_not_append_twice(self):
        edited = build.append(image(), ['@loader_path/ns'])
        self.assertEqual(edited, build.append(edited, ['@loader_path/ns']))

    def test_tight_header_fails_before_changing_code(self):
        original = image(0)
        with self.assertRaises(ValueError):
            build.append(original, ['/usr/local/lib/account.dylib'])
        self.assertEqual(original[-4:], b'CODE')

    def test_nonzero_padding_is_not_overwritten(self):
        original = bytearray(image())
        original[32 + 176] = 1
        with self.assertRaises(ValueError):
            build.append(bytes(original), ['@loader_path/ns'])

    def test_unknown_architecture_is_refused(self):
        original = bytearray(image())
        struct.pack_into('<I', original, 8, 0)
        with self.assertRaises(ValueError):
            build.arm64e(bytes(original))


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        # Exercise the production lifecycle functions without loading native
        # libproc, reading account files, or starting a launchd job.
        tree = ast.parse((build.B / 'manager.py').read_text())
        definitions = [n for n in tree.body if isinstance(n, ast.FunctionDef)
                       and n.name in ('owned', 'alive', 'complete', 'stop')]
        self.env = {'os': os, 'R': Path('/var/mnt/rootfs'),
                    'PREFIX': 'com.macpad.account15.session.v31.',
                    'SPECS': [['akd', 'akd.plist', '/usr/local/libexec/macpad-account15/akd-confined/akd', '501', '20', 1, 'hash']],
                    'path': Mock(), 'query': Mock(), 'store': Mock(), 'subprocess': Mock()}
        exec(compile(ast.Module(body=definitions, type_ignores=[]), 'manager.py', 'exec'), self.env)
        self.record = {'kind': 'akd', 'label': self.env['PREFIX'] + 'akd', 'pid': 123,
                       'path': os.path.realpath('/var/mnt/rootfs/usr/local/libexec/macpad-account15/akd-confined/akd')}

    def test_recycled_pid_is_not_accepted_as_owned_daemon(self):
        self.env['path'].return_value = '/usr/libexec/akd'
        self.env['query'].return_value = (0, 123, '')
        self.assertFalse(self.env['alive'](self.record))

    def test_foreign_label_is_not_stopped(self):
        foreign = copy.deepcopy(self.record)
        foreign['label'] = 'com.apple.akd'
        with self.assertRaises(RuntimeError):
            self.env['stop']({'records': [foreign]})
        self.env['subprocess'].run.assert_not_called()

    def test_idle_helper_can_adopt_its_own_replacement_pid(self):
        row = self.record
        row['kind'] = 'icloudhelper'
        self.env['query'].return_value = (0, 456, '')
        self.env['path'].return_value = row['path']
        self.assertTrue(self.env['alive'](row))
        self.assertEqual(row['pid'], 456)

    def test_installer_rejects_native_system_and_traversal_targets(self):
        for path in ['/usr/libexec/akd', '/var/jb/usr/bin/launchctl',
                     '/var/mnt/rootfs/usr/local/lib/../../etc/passwd',
                     '/var/mnt/rootfs/Users/mobile/Library/Accounts/Accounts4.sqlite']:
            self.assertFalse(install.allowed(path), path)

    def test_private_job_registration_closure(self):
        jobs = json.loads((build.B / 'jobs.json').read_text())
        services = json.loads((build.B / 'services.json').read_text())
        seen = set()
        for role, name, target, uid, gid, _ in services:
            job = jobs[name]
            self.assertEqual(job['ProgramArguments'][1:5], [uid, gid, '/var/mnt/rootfs', target])
            for endpoint in job['MachServices']:
                self.assertTrue(endpoint.startswith('com.macpad.account15.'))
                self.assertNotIn(endpoint, seen)
                seen.add(endpoint)
            self.assertNotIn('MACWS_IDENTITY_DIAGNOSTICS', job['EnvironmentVariables'])


if __name__ == '__main__':
    unittest.main()
