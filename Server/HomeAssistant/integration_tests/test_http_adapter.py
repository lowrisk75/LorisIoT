"""Real HA 2026.9.1 authentication/HTTP/runtime, isolated on localhost with fake services.

Run explicitly using the pinned qualification environment. No default_config, discovery,
physical integration or user configuration is loaded. Tokens and databases are disposable.
"""
import asyncio
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid

from aiohttp.test_utils import TestClient, TestServer
from homeassistant.auth import auth_manager_from_config
from homeassistant.auth.const import GROUP_ID_ADMIN, GROUP_ID_READ_ONLY
from homeassistant.const import __version__, EVENT_HOMEASSISTANT_STOP
from homeassistant.core import CoreState, HomeAssistant
from homeassistant.components.http.server import HomeAssistantHTTP
from homeassistant.helpers import device_registry, entity_registry

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from custom_components.lorisiot_schedule import CONFIG_SCHEMA, DOMAIN, PREFIX, async_setup


class HTTPAdapterTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.assertEqual(__version__, '2026.9.1', 'Requalify new HA versions explicitly')
        self.directory = tempfile.TemporaryDirectory(prefix='lorisiot-ha-http-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.hass = HomeAssistant(self.directory.name)
        self.addAsyncCleanup(self.shutdown)
        device_registry.async_setup(self.hass)
        await device_registry.async_load(self.hass, load_empty=True)
        await entity_registry.async_load(self.hass, load_empty=True)
        self.hass.auth = await auth_manager_from_config(self.hass, [], [])
        self.admin = await self.hass.auth.async_create_system_user('Fixture admin', group_ids=[GROUP_ID_ADMIN])
        self.reader = await self.hass.auth.async_create_system_user('Fixture reader', group_ids=[GROUP_ID_READ_ONLY])
        self.tokens = {}
        for user in [self.admin, self.reader]:
            refresh = await self.hass.auth.async_create_refresh_token(user)
            self.tokens[user.id] = self.hass.auth.async_create_access_token(refresh)
        server = HomeAssistantHTTP(self.hass, None, None, None, ['127.0.0.1'], 0, [], 'modern')
        self.hass.http = server
        await server.async_initialize(cors_origins=[], use_x_forwarded_for=False, login_threshold=-1,
                                      is_ban_enabled=False, use_x_frame_options=True)
        self.assertTrue(await async_setup(self.hass, CONFIG_SCHEMA(
            {DOMAIN: {'allowed_targets': ['switch.fixture', 'light.fixture', 'light.basic']}})))
        self.hass.set_state(CoreState.running)
        self.client = TestClient(TestServer(server.app, host='127.0.0.1'))
        await self.client.start_server()
        self.calls = []
        async def fake_service(call):
            self.calls.append((call.service, dict(call.data), call.context.user_id))
            self.hass.states.async_set('switch.fixture', 'on' if call.service == 'turn_on' else 'off')
        self.hass.services.async_register('switch', 'turn_on', fake_service)
        self.hass.services.async_register('switch', 'turn_off', fake_service)
        self.hass.states.async_set('switch.fixture', 'off')
        # A luminaire owns its ramp: turning on with a transition reports ON at once and climbs
        # to the requested level long after the command deadline has passed.
        async def fake_light(call):
            self.calls.append((call.service, dict(call.data), call.context.user_id))
            attributes = {'supported_features': 32, 'supported_color_modes': ['brightness']}
            if call.service == 'turn_on':
                self.hass.states.async_set('light.fixture', 'on', attributes | {'brightness': 3})
            else:
                self.hass.states.async_set('light.fixture', 'off', attributes)
        self.hass.services.async_register('light', 'turn_on', fake_light)
        self.hass.services.async_register('light', 'turn_off', fake_light)
        self.hass.states.async_set('light.fixture', 'off',
                                   {'supported_features': 32, 'supported_color_modes': ['brightness']})
        self.owner = {'appID': 'fixture.app', 'installationID': str(uuid.uuid4())}

    async def shutdown(self):
        if hasattr(self, 'client'):
            await self.client.close()
        if hasattr(self, 'hass'):
            self.hass.bus.async_fire(EVENT_HOMEASSISTANT_STOP)
            await self.hass.async_block_till_done()
            await self.hass.async_stop(force=True)

    def headers(self, user=None):
        return {'Authorization': 'Bearer ' + self.tokens[(user or self.admin).id]}

    def request(self, **changes):
        request = {'remoteID': str(uuid.uuid4()), 'owner': self.owner.copy(), 'providerID': 'fixture-ha',
                   'scheduleID': 'wake', 'deviceID': 'switch.fixture', 'on': True,
                   'start': time.time() + 60, 'enabled': True}
        return request | changes

    async def create(self, request=None):
        response = await self.client.post(PREFIX + '/records', headers=self.headers(),
                                          json={'record': request or self.request()})
        self.assertEqual(response.status, 200, await response.text())
        return await response.json()

    async def test_real_auth_rejects_anonymous_and_non_admin_requests(self):
        for method, path, body in [('get', '/health', None), ('post', '/records', {'record': self.request()})]:
            response = await getattr(self.client, method)(PREFIX + path, json=body)
            self.assertEqual(response.status, 401)
            response = await getattr(self.client, method)(PREFIX + path, headers=self.headers(self.reader), json=body)
            self.assertEqual(response.status, 403)
        self.assertEqual(self.calls, [])
        response = await self.client.get(PREFIX + '/health', headers=self.headers())
        self.assertEqual(response.status, 200)
        self.assertTrue((await response.json())['ready'])

    async def test_http_create_read_and_cancel_require_exact_owner_and_revision(self):
        saved = await self.create()
        path = PREFIX + '/records/' + saved['remoteID']
        response = await self.client.get(path, headers=self.headers())
        self.assertEqual(await response.json(), saved)
        self.assertNotIn('userID', saved)
        other = self.owner | {'installationID': str(uuid.uuid4())}
        for owner, revision in [(other, saved['revision']), (self.owner, saved['revision'] + 1)]:
            response = await self.client.delete(path, headers=self.headers(), json={'owner': owner, 'expectedRevision': revision})
            self.assertEqual(response.status, 409)
        response = await self.client.delete(path, headers=self.headers(),
                                            json={'owner': self.owner, 'expectedRevision': saved['revision']})
        self.assertEqual(response.status, 200)
        self.assertEqual((await response.json())['state'], 'removed')
        self.assertEqual(self.calls, [])

    async def test_http_body_bounds_and_unknown_targets_never_reach_a_service(self):
        for request in [self.request(deviceID='switch.other'), self.request(on=1), self.request(area_id='all')]:
            response = await self.client.post(PREFIX + '/records', headers=self.headers(), json={'record': request})
            self.assertEqual(response.status, 400)
        response = await self.client.post(PREFIX + '/records', headers=self.headers(), data='x' * 16_385)
        self.assertEqual(response.status, 413)
        async def chunked():
            for _ in range(5):
                yield b'x' * 4096
        response = await self.client.post(PREFIX + '/records', headers=self.headers(), data=chunked())
        self.assertEqual(response.status, 413)
        self.assertEqual(self.calls, [])

    async def test_real_service_dispatch_has_one_exact_target_and_fresh_confirmation(self):
        saved = await self.create()
        state = self.hass.data[DOMAIN]
        state['store'].clock = lambda: saved['start']
        await state['runtime'].poll()
        await state['runtime'].poll()
        self.assertEqual(self.calls, [('turn_on', {'entity_id': 'switch.fixture'}, self.admin.id)])
        record = await self.hass.async_add_executor_job(state['store'].get, self.admin.id, saved['remoteID'])
        self.assertEqual(record['state'], 'applied')

    async def test_starting_server_is_not_ready_and_cannot_run_a_due_schedule(self):
        saved = await self.create()
        state = self.hass.data[DOMAIN]
        state['store'].clock = lambda: saved['start']
        self.hass.set_state(CoreState.starting)
        response = await self.client.get(PREFIX + '/health', headers=self.headers())
        self.assertFalse((await response.json())['ready'])
        response = await self.client.post(PREFIX + '/records', headers=self.headers(), json={'record': self.request()})
        self.assertEqual(response.status, 503)
        await asyncio.sleep(1.1)
        self.assertEqual(self.calls, [])
        record = await self.hass.async_add_executor_job(state['store'].get, self.admin.id, saved['remoteID'])
        self.assertEqual(record['state'], 'armed')

    async def test_revoking_admin_before_due_time_prevents_service_dispatch(self):
        saved = await self.create()
        await self.hass.auth.async_update_user(self.admin, is_active=False)
        state = self.hass.data[DOMAIN]
        state['store'].clock = lambda: saved['start']
        await state['runtime'].poll()
        self.assertEqual(self.calls, [])
        record = await self.hass.async_add_executor_job(state['store'].get, self.admin.id, saved['remoteID'])
        self.assertEqual(record['state'], 'uncertain')

    async def test_old_matching_state_is_not_an_execution_confirmation(self):
        async def no_report(_call):
            pass
        self.hass.services.async_register('switch', 'turn_on', no_report)
        self.hass.states.async_set('switch.fixture', 'on')
        saved = await self.create()
        state = self.hass.data[DOMAIN]
        state['store'].clock = lambda: saved['start']
        await state['runtime'].poll()
        record = await self.hass.async_add_executor_job(state['store'].get, self.admin.id, saved['remoteID'])
        self.assertEqual(record['state'], 'uncertain')


    async def due(self, request):
        saved = await self.create(request)
        state = self.hass.data[DOMAIN]
        state['store'].clock = lambda: saved['start']
        await state['runtime'].poll()
        await state['runtime'].poll()
        return await self.hass.async_add_executor_job(state['store'].get, self.admin.id, saved['remoteID'])

    async def test_a_sunrise_is_one_service_call_carrying_its_own_transition(self):
        await self.due(self.request(deviceID='light.fixture', level=0.75, transition=1200))
        self.assertEqual(self.calls, [('turn_on', {'entity_id': 'light.fixture', 'brightness': 191,
                                                   'transition': 1200.0}, self.admin.id)])

    async def test_a_ramp_in_flight_confirms_without_reaching_its_final_level(self):
        record = await self.due(self.request(deviceID='light.fixture', level=0.75, transition=1200))
        self.assertEqual(self.hass.states.get('light.fixture').attributes['brightness'], 3)
        self.assertEqual(record['state'], 'applied')

    async def test_an_instant_level_is_uncertain_until_the_light_reports_it(self):
        record = await self.due(self.request(deviceID='light.fixture', level=0.5))
        self.assertEqual(record['state'], 'uncertain')


    async def test_a_light_that_cannot_ramp_is_refused_at_provisioning(self):
        # An allowlisted target: only the missing capability can refuse it.
        self.hass.states.async_set('light.basic', 'off',
                                   {'supported_features': 0, 'supported_color_modes': ['onoff']})
        for changes in [{'level': 0.5}, {'transition': 600}]:
            with self.subTest(changes=changes):
                response = await self.client.post(
                    PREFIX + '/records', headers=self.headers(),
                    json={'record': self.request(deviceID='light.basic', **changes)})
                self.assertEqual(response.status, 400, await response.text())
        self.assertEqual(self.calls, [])

    async def test_a_capable_light_still_accepts_its_ramp(self):
        saved = await self.create(self.request(deviceID='light.fixture', level=0.5, transition=600))
        self.assertEqual(saved['state'], 'armed')


    async def test_a_lapsed_lease_reaches_no_service(self):
        saved = await self.create(self.request(expiresAt=time.time() + 30))
        state = self.hass.data[DOMAIN]
        state['store'].clock = lambda: saved['start']
        await state['runtime'].poll()
        self.assertEqual(self.calls, [])
        record = await self.hass.async_add_executor_job(state['store'].get, self.admin.id, saved['remoteID'])
        self.assertEqual(record['state'], 'expired')


if __name__ == '__main__':
    unittest.main()
