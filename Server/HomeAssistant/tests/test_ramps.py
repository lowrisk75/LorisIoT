import asyncio
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'custom_components/lorisiot_schedule'))
from ramps import StepRamps


class StepRampBoundsTests(unittest.IsolatedAsyncioTestCase):
    def record(self, n=0):
        return dict(deviceID=f'light.fixture{n}', start=100, transition=600, level=0.8,
                    revision=3, remoteID=str(n))

    async def test_timeout_does_not_retry_and_revokes(self):
        called, revoked = [], []
        async def slow(record, level, now):
            called.append(level)
            await asyncio.sleep(1)
        ramps = StepRamps(lambda: 115, slow, revoked.append, timeout=0.01)
        ramps.add(self.record(), 1)
        await ramps.poll()
        await ramps.poll()
        self.assertEqual(len(called), 1)
        self.assertEqual(revoked, ['light.fixture0'])
        await ramps.close()
        await asyncio.sleep(0)

    async def test_uncancellable_calls_keep_all_eight_slots(self):
        release = asyncio.Event()
        called = []
        async def stuck(record, level, now):
            called.append(record['deviceID'])
            try:
                await release.wait()
            except asyncio.CancelledError:
                await release.wait()
            return True
        ramps = StepRamps(lambda: 115, stuck, lambda target: None, timeout=0.01)
        for n in range(10):
            ramps.add(self.record(n), 1)
        try:
            await ramps.poll()
            await ramps.poll()
            self.assertEqual(len(called), 8)
        finally:
            release.set()
            await asyncio.sleep(0)
            await ramps.close()

    async def test_backward_clock_revokes_without_a_send(self):
        async def execute(*args):
            self.fail('No command allowed after a backward clock jump')
        revoked = []
        ramps = StepRamps(lambda: 99, execute, revoked.append)
        ramps.add(self.record(), 1)
        await ramps.poll()
        self.assertEqual(revoked, ['light.fixture0'])

    async def test_stop_prevents_future_dispatch(self):
        async def execute(*args):
            self.fail('No command after shutdown')
        ramps = StepRamps(lambda: 115, execute, lambda target: None)
        ramps.add(self.record(), 1)
        await ramps.close()
        await ramps.poll()
