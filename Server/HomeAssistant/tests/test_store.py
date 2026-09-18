"""Persistent scheduling contracts using synthetic targets; no Home Assistant or network."""
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import tempfile
import sqlite3
import unittest
import uuid

MODULE_PATH = Path(__file__).resolve().parents[1] / 'custom_components/lorisiot_schedule/store.py'
spec = importlib.util.spec_from_file_location('schedule_store_fixture', MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
Store, Conflict, InvalidRequest, NotFound = module.Store, module.Conflict, module.InvalidRequest, module.NotFound


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='lorisiot-server-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'schedules.sqlite'
        self.now = 1_900_000_000.0
        self.owner = {'appID': 'fixture.app', 'installationID': str(uuid.uuid4())}
        self.store = Store(self.path, {'switch.fixture'}, clock=lambda: self.now)

    def request(self, **changes):
        value = {'remoteID': str(uuid.uuid4()), 'owner': self.owner.copy(), 'providerID': 'fixture-ha',
                 'scheduleID': 'wake', 'deviceID': 'switch.fixture', 'on': True,
                 'start': self.now + 60, 'enabled': True}
        value.update(changes)
        return value

    def test_insert_is_durable_and_replay_is_idempotent(self):
        request = self.request()
        first = self.store.put('fixture-user', request)
        recreated = Store(self.path, {'switch.fixture'}, clock=lambda: self.now)
        self.assertEqual(recreated.get('fixture-user', request['remoteID']), first)
        self.assertEqual(recreated.put('fixture-user', request), first)

    def test_unknown_targets_bulk_selectors_and_invalid_numbers_are_rejected(self):
        for changes in [{'deviceID': 'switch.unapproved'}, {'deviceID': 'switch.fixture/../all'},
                        {'on': 1}, {'enabled': 'true'}, {'start': float('nan')},
                        {'start': self.now - 1}, {'start': self.now + 400 * 86400},
                        {'target': 'all'}, {'area_id': 'living_room'}]:
            with self.subTest(changes=changes), self.assertRaises(InvalidRequest):
                self.store.put('fixture-user', self.request(**changes))

    def test_user_and_installation_ownership_are_preserved(self):
        request = self.request()
        saved = self.store.put('fixture-user', request)
        with self.assertRaises(NotFound):
            self.store.get('another-user', saved['remoteID'])
        impostor = request | {'owner': {'appID': 'another.app', 'installationID': str(uuid.uuid4())}}
        with self.assertRaises(Conflict):
            self.store.put('fixture-user', impostor, expected_revision=saved['revision'])
        with self.assertRaises(Conflict):
            self.store.remove('fixture-user', saved['remoteID'], impostor['owner'], saved['revision'])

    def test_identity_cannot_be_recreated_with_another_nonce(self):
        self.store.put('fixture-user', self.request())
        with self.assertRaises(Conflict):
            self.store.put('fixture-user', self.request())

    def test_update_requires_the_current_revision(self):
        request = self.request()
        first = self.store.put('fixture-user', request)
        replacement = request | {'start': self.now + 120}
        second = self.store.put('fixture-user', replacement, expected_revision=first['revision'])
        self.assertGreater(second['revision'], first['revision'])
        with self.assertRaises(Conflict):
            self.store.put('fixture-user', request, expected_revision=first['revision'])

    def test_cancelled_and_disabled_schedules_never_become_due(self):
        saved = self.store.put('fixture-user', self.request())
        self.store.remove('fixture-user', saved['remoteID'], self.owner, saved['revision'])
        self.store.put('fixture-user', self.request(scheduleID='disabled', enabled=False))
        self.now += 60
        self.assertEqual(self.store.claim_due(), [])

    def test_claim_is_committed_before_execution_and_never_replayed_after_crash(self):
        saved = self.store.put('fixture-user', self.request())
        self.now += 60
        claimed = self.store.claim_due()
        self.assertEqual(len(claimed), 1)
        self.assertEqual(self.store.get('fixture-user', saved['remoteID'])['state'], 'executing')
        recreated = Store(self.path, {'switch.fixture'}, clock=lambda: self.now)
        recreated.recover_uncertain()
        self.assertEqual(recreated.claim_due(), [])
        self.assertEqual(recreated.get('fixture-user', saved['remoteID'])['state'], 'uncertain')

    def test_expired_schedule_is_missed_and_cannot_fire_on_next_poll(self):
        saved = self.store.put('fixture-user', self.request())
        self.now += 66
        self.assertEqual(self.store.claim_due(), [])
        self.assertEqual(self.store.get('fixture-user', saved['remoteID'])['state'], 'missed')
        self.now += 86400
        self.assertEqual(self.store.claim_due(), [])

    def test_two_pollers_cannot_claim_the_same_schedule(self):
        self.store.put('fixture-user', self.request())
        self.now += 60
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda _: self.store.claim_due(), range(2)))
        self.assertEqual(sum(map(len, results)), 1)

    def test_cancellation_cannot_claim_success_after_execution_started(self):
        saved = self.store.put('fixture-user', self.request())
        self.now += 60
        claimed = self.store.claim_due()[0]
        with self.assertRaises(Conflict):
            self.store.remove('fixture-user', saved['remoteID'], self.owner, claimed['revision'])
        self.store.finish(saved['remoteID'], claimed['revision'], confirmed=True)
        self.assertEqual(self.store.get('fixture-user', saved['remoteID'])['state'], 'applied')

    def test_late_execution_callback_cannot_overwrite_recovery(self):
        saved = self.store.put('fixture-user', self.request())
        self.now += 60
        claimed = self.store.claim_due()[0]
        self.store.recover_uncertain()
        self.store.finish(saved['remoteID'], claimed['revision'], confirmed=True)
        self.assertEqual(self.store.get('fixture-user', saved['remoteID'])['state'], 'uncertain')

    def test_queue_capacity_is_bounded_without_dropping_existing_jobs(self):
        limited = Store(self.path, {'switch.fixture'}, clock=lambda: self.now, max_records=2)
        first = limited.put('fixture-user', self.request(scheduleID='one'))
        limited.put('fixture-user', self.request(scheduleID='two'))
        with self.assertRaises(Conflict):
            limited.put('fixture-user', self.request(scheduleID='three'))
        self.assertEqual(limited.get('fixture-user', first['remoteID'])['state'], 'armed')

    def test_cancel_then_new_nonce_cannot_be_undone_by_a_delayed_old_request(self):
        old = self.request()
        first = self.store.put('fixture-user', old)
        self.store.remove('fixture-user', first['remoteID'], self.owner, first['revision'])
        new = self.request()
        second = self.store.put('fixture-user', new)
        self.assertEqual(second['state'], 'armed')
        self.assertEqual(self.store.put('fixture-user', old)['state'], 'removed')
        self.assertEqual(self.store.get('fixture-user', second['remoteID'])['state'], 'armed')
        self.store.remove('fixture-user', second['remoteID'], self.owner, second['revision'])
        self.assertEqual(self.store.put('fixture-user', old)['state'], 'removed')

    def test_corrupt_persisted_payload_cannot_be_claimed_as_a_command(self):
        request = self.request()
        self.store.put('fixture-user', request)
        malformed = request | {'on': 'not-a-boolean'}
        db = sqlite3.connect(self.path)
        try:
            db.execute('UPDATE schedules SET payload=?', (json.dumps(malformed),))
            db.commit()
        finally:
            db.close()
        self.now += 60
        with self.assertRaises(ValueError):
            self.store.claim_due()
        with self.assertRaises(ValueError):
            Store(self.path, {'switch.fixture'}, clock=lambda: self.now)


    # A sunrise ramp is one atomic command carrying its own transition time: the luminaire
    # owns the ramp (Zigbee/Matter Level Control), so the journal stores an intent, never steps.
    def test_light_level_and_transition_round_trip_through_the_journal(self):
        store = Store(self.path, {'light.fixture'}, clock=lambda: self.now)
        request = self.request(deviceID='light.fixture', level=0.75, transition=1200.0)
        saved = store.put('fixture-user', request)
        self.assertEqual(saved['level'], 0.75)
        self.assertEqual(saved['transition'], 1200.0)
        recreated = Store(self.path, {'light.fixture'}, clock=lambda: self.now)
        self.assertEqual(recreated.get('fixture-user', request['remoteID']), saved)

    def test_out_of_range_level_and_transition_are_rejected(self):
        store = Store(self.path, {'light.fixture'}, clock=lambda: self.now)
        for changes in [{'level': 1.5}, {'level': -0.1}, {'level': float('nan')}, {'level': 'bright'},
                        {'level': True}, {'level': 0.5, 'on': False}, {'transition': -1},
                        {'transition': 4000}, {'transition': float('inf')}, {'transition': 'slow'}]:
            with self.subTest(changes=changes), self.assertRaises(InvalidRequest):
                store.put('fixture-user', self.request(deviceID='light.fixture', **changes))

    def test_level_and_transition_are_rejected_on_a_target_that_cannot_ramp(self):
        for changes in [{'level': 0.5}, {'transition': 30}]:
            with self.subTest(changes=changes), self.assertRaises(InvalidRequest):
                self.store.put('fixture-user', self.request(**changes))

    def test_legacy_power_records_written_before_ramps_remain_readable(self):
        request = self.request()
        saved = self.store.put('fixture-user', request)
        self.assertIsNone(saved['level'])
        self.assertIsNone(saved['transition'])
        db = sqlite3.connect(self.path)
        try:
            legacy = {key: value for key, value in request.items()}
            db.execute('UPDATE schedules SET payload=?', (json.dumps(legacy, sort_keys=True, separators=(',', ':')),))
            db.commit()
        finally:
            db.close()
        recreated = Store(self.path, {'switch.fixture'}, clock=lambda: self.now)
        self.assertEqual(recreated.get('fixture-user', request['remoteID'])['on'], True)


    # A lease bounds a zombie intent: a client gone for good stops arming the home. It does not
    # bound a cancellation, whose client is alive and whose lease is still fresh.
    def test_an_intent_whose_lease_lapsed_before_its_start_never_executes(self):
        saved = self.store.put('fixture-user', self.request(expiresAt=self.now + 30))
        self.now += 60
        self.assertEqual(self.store.claim_due(), [])
        self.assertEqual(self.store.get('fixture-user', saved['remoteID'])['state'], 'expired')
        self.now += 86400
        self.assertEqual(self.store.claim_due(), [])

    def test_a_still_valid_lease_executes_normally(self):
        saved = self.store.put('fixture-user', self.request(expiresAt=self.now + 86400))
        self.now += 60
        self.assertEqual(len(self.store.claim_due()), 1)
        self.assertEqual(self.store.get('fixture-user', saved['remoteID'])['state'], 'executing')

    def test_an_unusable_lease_is_rejected(self):
        for changes in [{'expiresAt': self.now - 1}, {'expiresAt': float('nan')},
                        {'expiresAt': 'tomorrow'}, {'expiresAt': self.now + 400 * 86400}]:
            with self.subTest(changes=changes), self.assertRaises(InvalidRequest):
                self.store.put('fixture-user', self.request(**changes))


if __name__ == '__main__':
    unittest.main()
