#!/usr/bin/env python3
"""Desktop isolation contracts; runnable without GTK, Xvfb or a Babet build."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_gui_real_files import probe_environment


class ProbeEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='babet_probe_env_')
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.original = dict(os.environ, DISPLAY=':117', WAYLAND_DISPLAY='wayland-0',
                             GDK_DEBUG='portals', GDK_BACKEND='wayland',
                             GSK_RENDERER='vulkan', GTK_USE_PORTAL='1',
                             DBUS_SESSION_BUS_ADDRESS='unix:path=/desktop/bus',
                             DBUS_STARTER_ADDRESS='unix:path=/desktop/bus',
                             DBUS_STARTER_BUS_TYPE='session',
                             ASAN_OPTIONS='halt_on_error=1:detect_leaks=0',
                             UBSAN_OPTIONS='halt_on_error=1', LANGUAGE='fr',
                             BABET_FAKE_GTK_FAIL='42')

    def test_desktop_isolation_reaches_child_process(self):
        env = probe_environment(self.original, self.folder)
        child = subprocess.run(
            [sys.executable, '-c', 'import json,os;print(json.dumps(dict(os.environ)))'],
            env=env, check=True, capture_output=True, text=True, timeout=5)
        received = json.loads(child.stdout)
        self.assertEqual(received['DISPLAY'], ':117')
        self.assertEqual(received['GDK_BACKEND'], 'x11')
        self.assertEqual(received['GDK_DEBUG'], 'no-portals')
        self.assertEqual(received['GSK_RENDERER'], 'cairo')
        self.assertEqual(received['DBUS_SESSION_BUS_ADDRESS'],
                         'unix:path=' + str(self.folder / 'no-session-bus'))
        self.assertFalse((self.folder / 'no-session-bus').exists())
        for key in ('DBUS_STARTER_ADDRESS', 'DBUS_STARTER_BUS_TYPE', 'WAYLAND_DISPLAY',
                    'GTK_USE_PORTAL', 'BABET_FAKE_GTK_FAIL'):
            self.assertNotIn(key, received)

    def test_parent_and_sanitizer_settings_are_preserved(self):
        before = dict(self.original)
        env = probe_environment(self.original, self.folder)
        self.assertEqual(self.original, before)
        for key in ('ASAN_OPTIONS', 'UBSAN_OPTIONS', 'PATH'):
            self.assertEqual(env.get(key), before.get(key))
        self.assertEqual(env['G_DEBUG'], 'fatal-criticals')

    def test_desktop_state_is_temporary(self):
        env = probe_environment(self.original, self.folder)
        for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME'):
            path = Path(env[key])
            self.assertEqual(path.parent, self.folder)
            self.assertTrue(path.is_dir())
            (path / 'probe').write_text('temporary test state')
        self.tmp.cleanup()
        self.assertFalse(self.folder.exists())

    def test_empty_environment_never_requests_bus_autolaunch(self):
        env = probe_environment({}, self.folder)
        self.assertTrue(env['DBUS_SESSION_BUS_ADDRESS'].startswith('unix:path='))
        self.assertEqual(env['LC_ALL'], 'C.UTF-8')
        self.assertEqual(env['LANGUAGE'], 'C')
        self.assertEqual(env['GIO_USE_VFS'], 'local')


if __name__ == '__main__':
    unittest.main(verbosity=2)
