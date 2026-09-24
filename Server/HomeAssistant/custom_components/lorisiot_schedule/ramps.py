"""Ephemeral, bounded sunrise steps. Never reconstruct a started ramp after restart."""
import asyncio


class StepRamps:
    INTERVAL = 15

    def __init__(self, clock, execute, revoke, *, timeout=5):
        self.clock, self.execute, self.revoke = clock, execute, revoke
        self.timeout = timeout
        self.entries = {}
        self.commands = set()
        self.stopped = False
        self.lock = asyncio.Lock()

    def add(self, record, initial):
        if not self.stopped:
            self.entries[record['deviceID']] = {
                'record': record.copy(), 'initial': initial,
                'next': record['start'] + self.INTERVAL}

    def cancel(self, target):
        self.entries.pop(target, None)

    def _done(self, task):
        self.commands.discard(task)
        if not task.cancelled():
            task.exception()

    async def poll(self):
        if self.stopped or self.lock.locked():
            return
        async with self.lock:
            now = self.clock()
            due = []
            for target, entry in tuple(self.entries.items()):
                record = entry['record']
                end = record['start'] + record['transition']
                if now < record['start'] or now > end + 5:
                    self.cancel(target)
                    self.revoke(target)
                elif now >= entry['next']:
                    due.append((target, entry))
            # Outstanding services retain their slots even if cancellation is ignored.
            async with asyncio.TaskGroup() as group:
                for target, entry in due[:max(0, 8 - len(self.commands))]:
                    group.create_task(self._step(target, entry, now))

    async def _step(self, target, entry, now):
        if self.stopped or self.entries.get(target) is not entry:
            return
        record = entry['record']
        end = record['start'] + record['transition']
        level = round(entry['initial'] + (round(record['level'] * 255) - entry['initial'])
                      * min(1, (now - record['start']) / record['transition']))
        entry['next'] = min(end, now + self.INTERVAL)
        task = asyncio.create_task(self.execute(record, level, now))
        self.commands.add(task)
        task.add_done_callback(self._done)
        confirmed = False
        try:
            done, _ = await asyncio.wait({task}, timeout=self.timeout)
            if task in done:
                confirmed = task.result() is True
        except asyncio.CancelledError:
            raise
        except Exception:
            confirmed = False
        finally:
            if not task.done():
                task.cancel()
            if not confirmed:
                self.cancel(target)
                self.revoke(target)
        if confirmed:
            record['revision'] += 2  # durable claim, then confirmed finish
            if now >= end:
                self.cancel(target)

    async def close(self):
        self.stopped = True
        self.entries.clear()
        for task in tuple(self.commands):
            task.cancel()
