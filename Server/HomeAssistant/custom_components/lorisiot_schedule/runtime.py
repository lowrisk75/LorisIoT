"""Bounded executor for already committed one-shot intents."""
import asyncio
from functools import partial


class Runtime:
    def __init__(self, store, execute, *, executor=asyncio.to_thread, command_timeout=5):
        if not 0 < command_timeout <= 5:
            raise ValueError('Invalid command timeout')
        self.store = store
        self.execute = execute
        self.executor = executor
        self.command_timeout = command_timeout
        self._poll_lock = asyncio.Lock()
        # Keep timed-out services counted until they actually finish: cancellation is
        # cooperative and must neither stall polling nor permit unbounded dispatch.
        self._commands = set()
        self._stopped = False

    async def _io(self, function, *args, **kwargs):
        return await self.executor(partial(function, *args, **kwargs))

    async def start(self):
        await self._io(self.store.recover_uncertain)

    async def poll(self):
        if self._stopped or self._poll_lock.locked():
            return
        async with self._poll_lock:
            records = await self._io(self.store.claim_due)
            async with asyncio.TaskGroup() as group:
                for record in records:
                    group.create_task(self._run(record))

    async def _run(self, record):
        confirmed = False
        command = None
        deadline = asyncio.get_running_loop().time() + self.command_timeout
        try:
            # Queue only within the same total deadline used for execution. A stuck
            # service keeps its slot, but cannot hold the rest of the batch forever.
            while len(self._commands) >= 8 and not self._stopped:
                remaining = deadline - asyncio.get_running_loop().time()
                if remaining <= 0:
                    break
                done, _ = await asyncio.wait(tuple(self._commands), timeout=remaining,
                                             return_when=asyncio.FIRST_COMPLETED)
                for finished in done:
                    self._command_finished(finished)
            remaining = deadline - asyncio.get_running_loop().time()
            if (not self._stopped and len(self._commands) < 8
                    and remaining > 0
                    and record['start'] <= self.store.clock() <= record['start'] + self.store.MAX_LATE_SECONDS):
                command = asyncio.create_task(self.execute(record))
                self._commands.add(command)
                command.add_done_callback(self._command_finished)
                done, _ = await asyncio.wait({command}, timeout=remaining)
                if command in done:
                    confirmed = command.result() is True
        except asyncio.CancelledError:
            # If execution may have started, cancellation preserves uncertainty and never retries.
            await asyncio.shield(self._io(self.store.finish, record['remoteID'], record['revision'], confirmed=False))
            raise
        except Exception:
            confirmed = False
        finally:
            if command is not None and not command.done():
                command.cancel()
        await self._io(self.store.finish, record['remoteID'], record['revision'], confirmed=confirmed)

    def _command_finished(self, command):
        self._commands.discard(command)
        # Retrieve late failures without turning them into an acknowledgement or retry.
        if not command.cancelled():
            command.exception()

    async def close(self):
        self._stopped = True
        async with self._poll_lock:
            for command in tuple(self._commands):
                command.cancel()
            await self._io(self.store.recover_uncertain)
