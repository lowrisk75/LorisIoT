"""Versioned, durable one-shot intent journal. This module never controls a device."""
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import time
import uuid


class InvalidRequest(ValueError):
    pass


class JournalCorrupt(ValueError):
    pass


class Conflict(RuntimeError):
    pass


class NotFound(LookupError):
    pass


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,256}', value):
        raise InvalidRequest('Invalid identifier')
    return value


def uuid_string(value):
    try:
        if not isinstance(value, str) or len(value) != 36:
            raise ValueError()
        return str(uuid.UUID(value))
    except ValueError as error:
        raise InvalidRequest('Invalid UUID') from error


def owner_value(value):
    if not isinstance(value, dict) or set(value) != {'appID', 'installationID'}:
        raise InvalidRequest('Invalid owner')
    return {'appID': identifier(value['appID']), 'installationID': uuid_string(value['installationID'])}


def is_target(value):
    return isinstance(value, str) and len(value) <= 255 and bool(
        re.fullmatch(r'(switch|light|fan|input_boolean)\.[a-z0-9_]+', value))


class Store:
    MAX_LATE_SECONDS = 5
    FIELDS = {'remoteID', 'owner', 'providerID', 'scheduleID', 'deviceID', 'on', 'start', 'enabled'}
    # A luminaire owns its own ramp (Zigbee/Matter Level Control transition time), so a sunrise is
    # one atomic intent carrying a target level and a duration -- never a server-driven step sequence.
    RAMP_FIELDS = {'level', 'transition'}
    # A lease bounds a zombie intent: an owner that stops renewing stops arming the home. It does
    # not bound a cancellation, whose owner is alive and whose lease is still fresh.
    LEASE_FIELDS = {'expiresAt'}
    OPTIONAL_FIELDS = RAMP_FIELDS | LEASE_FIELDS
    MAX_TRANSITION_SECONDS = 3600
    STATES = {'armed', 'disabled', 'executing', 'applied', 'uncertain', 'missed', 'expired', 'removed'}

    def __init__(self, path, allowed_targets, *, clock=time.time, max_records=1024):
        self.path = Path(path)
        self.targets = frozenset(allowed_targets)
        if len(self.targets) > 256 or not all(is_target(value) for value in self.targets):
            raise InvalidRequest('Invalid target allowlist')
        if type(max_records) is not int or not 1 <= max_records <= 1024:
            raise InvalidRequest('Invalid queue bound')
        self.clock = clock
        self.max_records = max_records
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.is_symlink():
            raise InvalidRequest('Journal must not be a symbolic link')
        if not self.path.exists():
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.close(fd)
            except FileExistsError:
                pass
        if self.path.stat().st_size > 16 * 1024 * 1024:
            raise InvalidRequest('Journal exceeds its size bound')
        with self._db(write=True) as db:
            version = db.execute('PRAGMA user_version').fetchone()[0]
            if version not in (0, 2):
                raise InvalidRequest('Unsupported journal version')
            db.execute('''CREATE TABLE IF NOT EXISTS schedules (
                remote_id TEXT PRIMARY KEY, user_id TEXT NOT NULL,
                identity TEXT NOT NULL, payload TEXT NOT NULL,
                start REAL NOT NULL, state TEXT NOT NULL,
                revision INTEGER NOT NULL, updated_at REAL NOT NULL)''')
            db.execute("CREATE UNIQUE INDEX IF NOT EXISTS active_identity ON schedules(identity) WHERE state!='removed'")
            db.execute('PRAGMA user_version=2')
            rows = db.execute('SELECT * FROM schedules LIMIT 1025').fetchall()
            if len(rows) > 1024:
                raise JournalCorrupt('Journal exceeds its record bound')
            for row in rows:
                self._record(row)

    @contextmanager
    def _db(self, *, write=False):
        db = sqlite3.connect(self.path, timeout=2, isolation_level=None)
        db.row_factory = sqlite3.Row
        try:
            db.execute('PRAGMA synchronous=FULL')
            db.execute('PRAGMA max_page_count=4096')
            if write:
                db.execute('BEGIN IMMEDIATE')
            yield db
            if write:
                db.commit()
        except BaseException:
            if write:
                db.rollback()
            raise
        finally:
            db.close()

    def _now(self):
        now = self.clock()
        if not math.isfinite(now):
            raise InvalidRequest('Invalid server clock')
        return now

    def _request(self, value, *, check_allowlist=True):
        # Records written before ramps existed omit the ramp fields; they read back as absent.
        if not isinstance(value, dict) or not self.FIELDS <= set(value) <= self.FIELDS | self.OPTIONAL_FIELDS:
            raise InvalidRequest('Unsupported request fields')
        result = dict(value)
        result['remoteID'] = uuid_string(value['remoteID'])
        result['owner'] = owner_value(value['owner'])
        for field in ['providerID', 'scheduleID']:
            result[field] = identifier(value[field])
        if not is_target(value['deviceID']) or (check_allowlist and value['deviceID'] not in self.targets):
            raise InvalidRequest('Target is not provisioned')
        if type(value['on']) is not bool or type(value['enabled']) is not bool:
            raise InvalidRequest('Power and enabled must be boolean')
        if type(value['start']) not in (int, float) or not math.isfinite(value['start']):
            raise InvalidRequest('Start must be a finite UTC timestamp')
        result['start'] = float(value['start'])
        result['level'] = self._level(value)
        result['transition'] = self._transition(value)
        expires = value.get('expiresAt')
        if expires is not None:
            # A lapsed lease is legitimate on a persisted record, so only the shape is checked here.
            if type(expires) not in (int, float) or not math.isfinite(expires):
                raise InvalidRequest('Lease expiry must be a finite UTC timestamp')
            expires = float(expires)
        result['expiresAt'] = expires
        return result

    @staticmethod
    def _ramp_capable(value):
        # Only a light accepts a brightness level or a transition; a switch, fan or helper has neither.
        if not value['deviceID'].startswith('light.'):
            raise InvalidRequest('Target accepts neither a level nor a transition')

    def _level(self, value):
        level = value.get('level')
        if level is None:
            return None
        self._ramp_capable(value)
        if type(level) not in (int, float) or not math.isfinite(level) or not 0.0 <= level <= 1.0:
            raise InvalidRequest('Level must be a finite value within 0 to 1')
        if value['on'] is not True:
            raise InvalidRequest('A level requires the light to be turned on')
        return float(level)

    def _transition(self, value):
        transition = value.get('transition')
        if transition is None:
            return None
        self._ramp_capable(value)
        if (type(transition) not in (int, float) or not math.isfinite(transition)
                or not 0.0 <= transition <= self.MAX_TRANSITION_SECONDS):
            raise InvalidRequest('Transition must be a finite number of seconds within its bound')
        return float(transition)

    @staticmethod
    def _identity(user_id, request):
        return json.dumps([user_id, request['owner'], request['providerID'], request['deviceID'], request['scheduleID']],
                          sort_keys=True, separators=(',', ':'))

    def _record(self, row):
        if row is None:
            raise NotFound('Unknown schedule')
        try:
            if not isinstance(row['payload'], str) or len(row['payload']) > 16_384:
                raise InvalidRequest('Invalid payload size')
            # Removed targets remain readable/cancellable, but can never be executed.
            result = self._request(json.loads(row['payload']), check_allowlist=False)
            user_id = identifier(row['user_id'])
            if (row['remote_id'] != result['remoteID'] or row['identity'] != self._identity(user_id, result)
                    or type(row['start']) not in (int, float) or row['start'] != result['start']
                    or row['state'] not in self.STATES
                    or type(row['revision']) is not int or row['revision'] < 1
                    or type(row['updated_at']) not in (int, float) or not math.isfinite(row['updated_at'])
                    or (row['state'] == 'armed' and not result['enabled'])
                    or (row['state'] == 'disabled' and result['enabled'])):
                raise InvalidRequest('Inconsistent journal record')
        except (ValueError, TypeError, KeyError, OverflowError) as error:
            raise JournalCorrupt('Invalid persisted schedule; execution is blocked') from error
        result.update(userID=row['user_id'], state=row['state'], revision=row['revision'], updatedAt=row['updated_at'])
        return result

    def get(self, user_id, remote_id):
        with self._db() as db:
            return self._record(db.execute('SELECT * FROM schedules WHERE remote_id=? AND user_id=?',
                                          (uuid_string(remote_id), identifier(user_id))).fetchone())

    def put(self, user_id, request, *, expected_revision=None):
        user_id = identifier(user_id)
        request = self._request(request)
        if expected_revision is not None and (type(expected_revision) is not int or expected_revision < 1):
            raise InvalidRequest('Invalid revision')
        payload = json.dumps(request, sort_keys=True, separators=(',', ':'))
        identity = self._identity(user_id, request)
        now = self._now()
        with self._db(write=True) as db:
            row = db.execute('SELECT * FROM schedules WHERE remote_id=?', (request['remoteID'],)).fetchone()
            if row is not None:
                self._record(row)
                if row['identity'] != identity or row['user_id'] != user_id:
                    raise Conflict('Ownership mismatch')
                if row['payload'] == payload:
                    return self._record(row)
                if row['revision'] != expected_revision or row['state'] in ('executing', 'uncertain'):
                    raise Conflict('Schedule changed or execution is uncertain')
            elif expected_revision is not None:
                raise Conflict('Missing previous revision')
            # A replay can read an existing completed receipt; a new intent must be safely ahead.
            if not now + 15 <= request['start'] <= now + 366 * 86400:
                raise InvalidRequest('Schedule must be 15 seconds to 366 days ahead')
            if request['expiresAt'] is not None and not now <= request['expiresAt'] <= now + 366 * 86400:
                raise InvalidRequest('Lease expiry must be now to 366 days ahead')
            state = 'armed' if request['enabled'] else 'disabled'
            other = db.execute("SELECT remote_id FROM schedules WHERE identity=? AND state!='removed' AND remote_id!=?",
                               (identity, request['remoteID'])).fetchone()
            if other:
                raise Conflict('Owned identity already exists with another nonce')
            if row is None:
                # Keep cancellation tombstones while their original request could still be valid.
                # Once both dates are 30 days past, replay already fails the new-intent time gate.
                db.execute("DELETE FROM schedules WHERE state='removed' AND start<? AND updated_at<?",
                           (now - 30 * 86400, now - 30 * 86400))
                if db.execute('SELECT count(*) FROM schedules').fetchone()[0] >= self.max_records:
                    raise Conflict('Schedule journal is full; existing intents are preserved')
                db.execute('INSERT INTO schedules VALUES (?,?,?,?,?,?,?,?)',
                           (request['remoteID'], user_id, identity, payload, request['start'], state, 1, now))
            else:
                db.execute('UPDATE schedules SET payload=?, start=?, state=?, revision=revision+1, updated_at=? WHERE remote_id=?',
                           (payload, request['start'], state, now, request['remoteID']))
            result = self._record(db.execute('SELECT * FROM schedules WHERE remote_id=?', (request['remoteID'],)).fetchone())
        return result  # COMMIT has completed before an acknowledgement escapes.

    def remove(self, user_id, remote_id, owner, expected_revision):
        remote_id = uuid_string(remote_id)
        owner = owner_value(owner)
        if type(expected_revision) is not int or expected_revision < 1:
            raise InvalidRequest('Invalid revision')
        with self._db(write=True) as db:
            row = db.execute('SELECT * FROM schedules WHERE remote_id=? AND user_id=?',
                             (remote_id, identifier(user_id))).fetchone()
            record = self._record(row)
            if record['owner'] != owner:
                raise Conflict('Ownership mismatch')
            if record['state'] == 'removed':
                return record
            if record['revision'] != expected_revision or record['state'] in ('executing', 'uncertain'):
                raise Conflict('Cancellation cannot be confirmed')
            db.execute("UPDATE schedules SET state='removed', revision=revision+1, updated_at=? WHERE remote_id=?",
                       (self._now(), remote_id))
            result = self._record(db.execute('SELECT * FROM schedules WHERE remote_id=?', (remote_id,)).fetchone())
        return result

    def claim_due(self):
        now = self._now()
        result = []
        with self._db(write=True) as db:
            rows = db.execute("SELECT * FROM schedules WHERE state='armed' AND start<=? ORDER BY start LIMIT 32", (now,)).fetchall()
            for row in rows:
                record = self._record(row)
                state = ('missed' if now - row['start'] > self.MAX_LATE_SECONDS
                         else 'expired' if record['expiresAt'] is not None and record['expiresAt'] < now
                         else 'uncertain' if record['deviceID'] not in self.targets else 'executing')
                db.execute('UPDATE schedules SET state=?, revision=revision+1, updated_at=? WHERE remote_id=?',
                           (state, now, row['remote_id']))
                if state == 'executing':
                    result.append(self._record(db.execute('SELECT * FROM schedules WHERE remote_id=?', (row['remote_id'],)).fetchone()))
        return result  # A process crash from here onward leaves an uncertain intent, never a replay.

    def finish(self, remote_id, revision, *, confirmed):
        if type(confirmed) is not bool:
            raise InvalidRequest('Confirmation must be boolean')
        with self._db(write=True) as db:
            db.execute("UPDATE schedules SET state=?, revision=revision+1, updated_at=? WHERE remote_id=? AND revision=? AND state='executing'",
                       ('applied' if confirmed else 'uncertain', self._now(), uuid_string(remote_id), revision))

    def recover_uncertain(self):
        with self._db(write=True) as db:
            db.execute("UPDATE schedules SET state='uncertain', revision=revision+1, updated_at=? WHERE state='executing'", (self._now(),))
