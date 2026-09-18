"""No hardware: only a fake service and temporary SQLite files."""
import asyncio
import importlib.util
from pathlib import Path
import tempfile
import unittest
import uuid


def load(name):
    path = Path(__file__).resolve().parents[1] / 'custom_components/lorisiot_schedule' / (name + '.py')
    spec = importlib.util.spec_from_file_location('fixture_' + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


Store, Runtime = load('store').Store, load('runtime').Runtime


class RuntimeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='lorisiot-runtime-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.now = 1_900_000_000.0
        self.store = Store(Path(self.directory.name) / 'schedules.sqlite', {'switch.fixture'}, clock=lambda: self.now)
        self.request = {'remoteID': str(uuid.uuid4()), 'owner': {'appID': 'fixture.app', 'installationID': str(uuid.uuid4())},
                        'providerID': 'fixture-ha', 'scheduleID': 'wake', 'deviceID': 'switch.fixture',
                        'on': True, 'start': self.now + 60, 'enabled': True}
        self.store.put('fixture-user', self.request)
        self.calls = []

    async def execute(self, record):
        self.calls.append((record['deviceID'], record['on']))
        self.assertEqual(self.store.get('fixture-user', record['remoteID'])['state'], 'executing')
        return True

    def state(self):
        return self.store.get('fixture-user', self.request['remoteID'])['state']

    async def test_executes_once_without_any_app_connection(self):
        runtime = Runtime(self.store, self.execute)
        await runtime.start()
        await runtime.poll()
        self.assertEqual(self.calls, [])
        self.now += 60
        await asyncio.gather(runtime.poll(), runtime.poll())
        await runtime.poll()
        self.assertEqual(self.calls, [('switch.fixture', True)])
        self.assertEqual(self.state(), 'applied')
        await runtime.close()

    async def test_service_failure_is_uncertain_and_never_retried(self):
        async def fail(record):
            self.calls.append(record['remoteID'])
            raise OSError('Fixture lost response')
        runtime = Runtime(self.store, fail)
        self.now += 60
        await runtime.poll()
        await runtime.poll()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.state(), 'uncertain')

    async def test_batch_larger_than_concurrency_limit_executes_each_fast_service_once(self):
        for index in range(11):
            request = dict(self.request, remoteID=str(uuid.uuid4()), scheduleID=f'wake-{index}')
            self.store.put('fixture-user', request)
        runtime = Runtime(self.store, self.execute)
        self.now += 60
        await runtime.poll()
        await runtime.poll()
        self.assertEqual(len(self.calls), 12)
        self.assertEqual(self.state(), 'applied')
        await runtime.close()

    async def test_stuck_services_retain_capacity_without_blocking_other_claims(self):
        for index in range(11):
            request = dict(self.request, remoteID=str(uuid.uuid4()), scheduleID=f'wake-{index}')
            self.store.put('fixture-user', request)
        release = asyncio.Event()
        async def stuck(record):
            self.calls.append(record['remoteID'])
            while not release.is_set():
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    pass
            return True
        runtime = Runtime(self.store, stuck, command_timeout=0.02)
        self.now += 60
        try:
            await asyncio.wait_for(runtime.poll(), timeout=1)
            self.assertEqual(len(self.calls), 8)
            self.assertEqual(self.state(), 'uncertain')
            request = dict(self.request, remoteID=str(uuid.uuid4()), scheduleID='later', start=self.now + 60)
            self.store.put('fixture-user', request)
            self.now += 60
            await asyncio.wait_for(runtime.poll(), timeout=1)
            self.assertEqual(len(self.calls), 8)
            self.assertEqual(self.store.get('fixture-user', request['remoteID'])['state'], 'uncertain')
        finally:
            release.set()
            await asyncio.sleep(0)
            await runtime.close()

    async def test_service_timeout_is_bounded_and_uncertain(self):
        async def stall(record):
            await asyncio.sleep(5)
        runtime = Runtime(self.store, stall, command_timeout=0.02)
        self.now += 60
        await asyncio.wait_for(runtime.poll(), timeout=1)
        self.assertEqual(self.state(), 'uncertain')

    async def test_closed_runtime_cannot_start_a_device_command(self):
        runtime = Runtime(self.store, self.execute)
        await runtime.close()
        self.now += 60
        await runtime.poll()
        self.assertEqual(self.calls, [])

    async def test_timeout_does_not_wait_for_service_cancellation_acknowledgement(self):
        release = asyncio.Event()
        cancelled = asyncio.Event()
        async def ignores_cancellation(record):
            self.calls.append(record['remoteID'])
            try:
                await release.wait()
            except asyncio.CancelledError:
                cancelled.set()
                await release.wait()
            return True
        runtime = Runtime(self.store, ignores_cancellation, command_timeout=0.02)
        self.now += 60
        polling = asyncio.create_task(runtime.poll())
        try:
            await asyncio.wait_for(cancelled.wait(), timeout=1)
            done, _ = await asyncio.wait({polling}, timeout=0.2)
            self.assertIn(polling, done, 'Timed-out service must not hold the scheduler open')
            await polling
            self.assertEqual(self.state(), 'uncertain')
            await runtime.poll()
            self.assertEqual(len(self.calls), 1)
        finally:
            release.set()
            await polling
            await runtime.close()

    async def test_cancellation_retains_uncertainty(self):
        entered = asyncio.Event()
        async def wait_for_cancel(record):
            entered.set()
            await asyncio.sleep(5)
        runtime = Runtime(self.store, wait_for_cancel)
        self.now += 60
        task = asyncio.create_task(runtime.poll())
        await asyncio.wait_for(entered.wait(), timeout=1)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertEqual(self.state(), 'uncertain')
        await runtime.close()

    async def test_backward_clock_step_after_claim_cannot_execute_early(self):
        async def executor(work):
            result = await asyncio.to_thread(work)
            if work.func == self.store.claim_due:
                self.now -= 3600
            return result
        runtime = Runtime(self.store, self.execute, executor=executor)
        self.now += 60
        await runtime.poll()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.state(), 'uncertain')


if __name__ == '__main__':
    unittest.main()
