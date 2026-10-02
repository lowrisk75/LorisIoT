"""Temporary journals only; never connect to HA or a real lamp."""
import asyncio
import tempfile
import unittest
import uuid
from pathlib import Path
from test_runtime import load

Store, Runtime = load('store').Store, load('runtime').Runtime


class SunriseAutoOffTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='sunrise-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.now = 1_900_000_000.0
        self.path = Path(self.directory.name) / 'fixture.sqlite'
        self.store = Store(self.path, {'light.fixture'}, clock=lambda: self.now)
        self.request = dict(remoteID=str(uuid.uuid4()),
            owner=dict(appID='fixture.app', installationID=str(uuid.uuid4())),
            providerID='fixture', scheduleID='sunrise', deviceID='light.fixture',
            on=True, enabled=True, start=self.now + 60, level=0.8,
            transition=600, autoOffAt=self.now + 60 + 600 + 900)
        self.calls = []

    def state(self):
        return self.store.get('fixture-user', self.request['remoteID'])['state']

    async def execute(self, record):
        self.calls.append(record['state'])
        return True

    async def test_off_only_after_confirmed_start_once(self):
        self.store.put('fixture-user', self.request)
        runtime = Runtime(self.store, self.execute)
        await runtime.start()
        self.now = self.request['start']
        await runtime.poll()
        self.assertEqual(self.state(), 'holding')
        self.now = self.request['autoOffAt']
        await asyncio.gather(runtime.poll(), runtime.poll())
        await runtime.poll()
        self.assertEqual(self.calls, ['executing', 'offExecuting'])
        self.assertEqual(self.state(), 'completed')

    async def test_failed_start_never_arms_off(self):
        self.store.put('fixture-user', self.request)
        async def fail(record):
            self.calls.append(record['state'])
            return False
        runtime = Runtime(self.store, fail)
        self.now = self.request['start']
        await runtime.poll()
        self.now = self.request['autoOffAt']
        await runtime.poll()
        self.assertEqual(self.calls, ['executing'])
        self.assertEqual(self.state(), 'uncertain')

    async def test_manual_takeover_permanently_revokes_off(self):
        self.store.put('fixture-user', self.request)
        runtime = Runtime(self.store, self.execute)
        self.now = self.request['start']
        await runtime.poll()
        self.store.revoke_sunrise('light.fixture')
        self.now = self.request['autoOffAt']
        await runtime.poll()
        self.assertEqual(self.calls, ['executing'])
        self.assertEqual(self.state(), 'overridden')

    async def test_restart_preserves_pending_but_distrusts_started_session(self):
        self.store.put('fixture-user', self.request)
        self.store.recover_uncertain()
        self.assertEqual(self.state(), 'armed')
        runtime = Runtime(self.store, self.execute)
        self.now = self.request['start']
        await runtime.poll()
        reopened = Store(self.path, {'light.fixture'}, clock=lambda: self.now)
        await Runtime(reopened, self.execute).start()
        self.assertEqual(self.state(), 'uncertain')
        self.now = self.request['autoOffAt']
        await Runtime(reopened, self.execute).poll()
        self.assertEqual(self.calls, ['executing'])

    async def test_late_off_never_replays(self):
        self.store.put('fixture-user', self.request)
        runtime = Runtime(self.store, self.execute)
        self.now = self.request['start']
        await runtime.poll()
        self.now = self.request['autoOffAt'] + 6
        await runtime.poll()
        self.assertEqual(self.state(), 'missed')
        self.assertEqual(self.calls, ['executing'])

    async def test_explicit_cancel_holding_leaves_lamp_alone(self):
        self.store.put('fixture-user', self.request)
        runtime = Runtime(self.store, self.execute)
        self.now = self.request['start']
        await runtime.poll()
        record = self.store.get('fixture-user', self.request['remoteID'])
        self.store.remove('fixture-user', record['remoteID'], record['owner'], record['revision'])
        self.now = self.request['autoOffAt']
        await runtime.poll()
        self.assertEqual(self.calls, ['executing'])

    def test_rejects_invalid_or_unbounded_session(self):
        for change in [dict(on=False), dict(deviceID='switch.fixture'), dict(transition=None),
                       dict(autoOffAt=True), dict(autoOffAt=float('nan')),
                       dict(autoOffAt=self.request['start']+600),
                       dict(autoOffAt=self.request['start']+600+180*60+1)]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.store.put('fixture-user', dict(self.request, **change))

    def test_overlapping_sessions_on_same_light_are_rejected(self):
        self.store.put('fixture-user', self.request)
        with self.assertRaises(RuntimeError):
            self.store.put('other-user', dict(self.request, remoteID=str(uuid.uuid4()), scheduleID='other'))
