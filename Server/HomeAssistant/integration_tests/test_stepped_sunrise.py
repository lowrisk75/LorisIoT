"""Opt-in software ramp, qualified against real HA with synthetic light reports."""
import asyncio
from functools import partial
import test_http_adapter as adapter
DOMAIN, PREFIX = adapter.DOMAIN, adapter.PREFIX
from custom_components.lorisiot_schedule.store import Conflict


class SteppedSunriseTests(adapter.HTTPAdapterTests):
    stepped_targets = ['light.basic']

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.attrs = {'supported_features': 4, 'supported_color_modes': ['rgb', 'color_temp']}
        self.hass.states.async_set('light.basic', 'off', self.attrs)
        async def basic_light(call):
            target = call.data['entity_id']
            if target != 'light.basic':
                attrs = {'supported_features': 32, 'supported_color_modes': ['brightness']}
                level = 3
            else:
                attrs = self.attrs
                level = call.data.get('brightness', 1)
            self.calls.append((call.service, dict(call.data), call.context.user_id))
            self.hass.states.async_set(target, 'on' if call.service == 'turn_on' else 'off',
                attrs | ({'brightness': level} if call.service == 'turn_on' else {})
                | ({'color_temp_kelvin': call.data['color_temp_kelvin']} if 'color_temp_kelvin' in call.data else {}), context=call.context)
        self.hass.services.async_register('light', 'turn_on', basic_light)
        self.hass.services.async_register('light', 'turn_off', basic_light)

    async def start_stepped(self):
        req = self.request(deviceID='light.basic', level=0.8, transition=600)
        req['autoOffAt'] = req['start'] + 1500
        record = await self.due(req)
        self.assertEqual(record['state'], 'holding')
        self.assertEqual(self.calls[-1][1], {'entity_id': 'light.basic', 'brightness': 3})
        return record

    async def advance(self, at):
        state = self.hass.data[DOMAIN]
        state['store'].clock = lambda: at
        await state['ramps'].poll()
        await self.hass.async_block_till_done()

    async def test_gentle_profile_curve_fade_and_owned_off(self):
        self.attrs = dict(supported_features=4, supported_color_modes=['brightness'])
        self.hass.states.async_set('light.basic', 'off', self.attrs)
        req = self.request(deviceID='light.basic', level=0.4, transition=600)
        req.update(autoOffAt=req['start'] + 1500, sunriseProfile='gentle-v1')
        record = await self.due(req)
        self.assertEqual(record['state'], 'holding')
        await self.advance(record['start'] + 300)
        self.assertEqual(self.calls[-1][1]['brightness'], 29)
        await self.advance(record['start'] + 600)
        self.assertEqual(self.calls[-1][1]['brightness'], 102)
        await self.advance(record['autoOffAt'] - 60)
        self.assertEqual(self.calls[-1][1]['brightness'], 51)
        await self.advance(record['autoOffAt'])
        await self.hass.data[DOMAIN]['runtime'].poll()
        self.assertEqual(self.calls[-1][0], 'turn_off')
        self.assertEqual(len(self.calls), 5)

    async def test_gentle_profile_warmth_is_capability_bounded(self):
        self.attrs |= dict(min_color_temp_kelvin=2700, max_color_temp_kelvin=6500)
        self.hass.states.async_set('light.basic', 'off', self.attrs)
        req = self.request(deviceID='light.basic', level=0.4, transition=600)
        req.update(autoOffAt=req['start'] + 1500, sunriseProfile='gentle-v1')
        record = await self.due(req)
        self.assertEqual(record['state'], 'holding')
        self.assertEqual(self.calls[-1][1]['color_temp_kelvin'], 2700)
        await self.advance(record['start'] + 600)
        self.assertEqual(self.calls[-1][1]['color_temp_kelvin'], 3000)

    async def test_steps_reach_target_then_owned_auto_off(self):
        record = await self.start_stepped()
        await self.advance(record['start'] + 300)
        self.assertEqual(self.calls[-1][1]['brightness'], 105)
        await self.advance(record['start'] + 600)
        self.assertEqual(self.calls[-1][1]['brightness'], 204)
        self.assertTrue(all('transition' not in c[1] for c in self.calls))
        await self.advance(record['autoOffAt'])
        await self.hass.data[DOMAIN]['runtime'].poll()
        self.assertEqual(self.calls[-1][0], 'turn_off')

    async def test_no_burst_when_polling_repeatedly(self):
        record = await self.start_stepped()
        for seconds in range(1, 15):
            await self.advance(record['start'] + seconds)
        self.assertEqual(len(self.calls), 1)
        await self.advance(record['start'] + 15)
        self.assertEqual(len(self.calls), 2)
        await self.advance(record['start'] + 15)
        self.assertEqual(len(self.calls), 2)

    async def test_manual_takeover_stops_all_later_steps_and_off(self):
        record = await self.start_stepped()
        old = self.hass.states.get('light.basic')
        self.hass.states.async_set('light.basic', 'on', dict(old.attributes) | {'brightness': 180})
        await self.hass.async_block_till_done()
        await self.advance(record['start'] + 300)
        await self.advance(record['autoOffAt'])
        await self.hass.data[DOMAIN]['runtime'].poll()
        self.assertEqual(len(self.calls), 1)

    async def test_passive_identical_reports_preserve_steps_and_off(self):
        record = await self.start_stepped()
        for at in [record['start'] + 300, record['start'] + 600]:
            old = self.hass.states.get('light.basic')
            self.hass.states.async_set('light.basic', old.state, dict(old.attributes))
            await self.hass.async_block_till_done()
            await self.advance(at)
        await self.advance(record['autoOffAt'])
        await self.hass.data[DOMAIN]['runtime'].poll()
        self.assertEqual(self.calls[-1][0], 'turn_off')
        self.assertEqual(len(self.calls), 4)

    async def test_cancel_between_steps_prevents_next_step(self):
        record = await self.start_stepped()
        store = self.hass.data[DOMAIN]['store']
        await self.hass.async_add_executor_job(partial(store.remove, self.admin.id, record['remoteID'],
            record['owner'], record['revision']))
        await self.advance(record['start'] + 300)
        self.assertEqual(len(self.calls), 1)

    async def test_restart_never_resumes_steps_or_off(self):
        record = await self.start_stepped()
        state = self.hass.data[DOMAIN]
        await state['ramps'].close()
        await state['runtime'].start()
        await self.advance(record['start'] + 300)
        await self.advance(record['autoOffAt'])
        await state['runtime'].poll()
        self.assertEqual(len(self.calls), 1)

    async def test_late_final_step_is_not_replayed(self):
        record = await self.start_stepped()
        await self.advance(record['start'] + 606)
        await self.advance(record['autoOffAt'])
        await self.hass.data[DOMAIN]['runtime'].poll()
        self.assertEqual(len(self.calls), 1)

    async def test_missing_step_confirmation_abandons_session(self):
        record = await self.start_stepped()
        async def silent(call):
            self.calls.append((call.service, dict(call.data), call.context.user_id))
        self.hass.services.async_register('light', 'turn_on', silent)
        await self.advance(record['start'] + 300)
        await self.advance(record['start'] + 600)
        await self.advance(record['autoOffAt'])
        await self.hass.data[DOMAIN]['runtime'].poll()
        self.assertEqual(len(self.calls), 2)

    async def test_generic_transition_stays_refused_without_native_support(self):
        response = await self.client.post(PREFIX + '/records', headers=self.headers(),
            json={'record': self.request(deviceID='light.basic', level=0.8, transition=600)})
        self.assertEqual(response.status, 400)

    async def test_cancel_during_step_cannot_claim_success(self):
        record = await self.start_stepped()
        store = self.hass.data[DOMAIN]['store']
        store.clock = lambda: record['start'] + 15
        claimed = await self.hass.async_add_executor_job(partial(store.claim_ramp_step,
            record['remoteID'], record['revision']))
        self.assertEqual(claimed['state'], 'executing')
        with self.assertRaises(Conflict):
            await self.hass.async_add_executor_job(partial(store.remove, self.admin.id,
                record['remoteID'], record['owner'], claimed['revision']))

    async def test_missing_past_session_requires_persisted_tombstone(self):
        req = self.request(deviceID='light.basic', level=0.8, transition=600)
        req['start'] -= 86400
        req['autoOffAt'] = req['start'] + 1500
        response = await self.client.post(PREFIX + '/retire', headers=self.headers(), json={'record': req})
        self.assertEqual(response.status, 200, await response.text())
        self.assertEqual((await response.json())['state'], 'removed')
        response = await self.client.get(PREFIX + '/records/' + req['remoteID'], headers=self.headers())
        self.assertEqual((await response.json())['state'], 'removed')
        replay = await self.create(req)
        self.assertEqual(replay['state'], 'removed')
        self.assertEqual(self.calls, [])

    async def test_missing_current_session_cannot_be_retired_as_expired(self):
        req = self.request(deviceID='light.basic', level=0.8, transition=600)
        req['autoOffAt'] = req['start'] + 1500
        response = await self.client.post(PREFIX + '/retire', headers=self.headers(), json={'record': req})
        self.assertEqual(response.status, 409)

    async def test_retirement_never_replaces_a_known_uncertain_session(self):
        record = await self.start_stepped()
        state = self.hass.data[DOMAIN]
        await state['runtime'].start()
        state['store'].clock = lambda: record['autoOffAt'] + 10
        req = {k:v for k,v in record.items() if k not in ('state','revision','updatedAt','userID')}
        response = await self.client.post(PREFIX + '/retire', headers=self.headers(), json={'record': req})
        self.assertEqual(response.status, 409)

    async def test_percentage_quantization_reaches_target_and_turns_off(self):
        # Real-device regression: brightness=1 becomes 0 at a 1%-resolution adapter.
        async def percent_light(call):
            raw = call.data.get('brightness', 0)
            percent = int(raw * 100 / 255)
            reported = int(percent * 255 / 100)
            self.calls.append((call.service, dict(call.data), call.context.user_id))
            self.hass.states.async_set('light.basic', 'on' if call.service == 'turn_on' else 'off',
                self.attrs | ({'brightness': reported} if call.service == 'turn_on' else {}), context=call.context)
        self.hass.services.async_register('light', 'turn_on', percent_light)
        self.hass.services.async_register('light', 'turn_off', percent_light)
        req = self.request(deviceID='light.basic', level=0.1, transition=60)
        req['autoOffAt'] = req['start'] + 120
        record = await self.due(req)
        self.assertEqual(record['state'], 'holding')
        self.assertGreater(self.hass.states.get('light.basic').attributes['brightness'], 0)
        for seconds in (15, 30, 45, 60):
            await self.advance(record['start'] + seconds)
        self.assertEqual(self.hass.states.get('light.basic').attributes['brightness'], 25)
        await self.advance(record['autoOffAt'])
        await self.hass.data[DOMAIN]['runtime'].poll()
        self.assertEqual(self.hass.states.get('light.basic').state, 'off')

    async def test_zero_brightness_is_never_a_confirmed_first_step(self):
        async def zero_light(call):
            self.calls.append((call.service, dict(call.data), call.context.user_id))
            self.hass.states.async_set('light.basic', 'on', self.attrs | {'brightness': 0}, context=call.context)
        self.hass.services.async_register('light', 'turn_on', zero_light)
        req = self.request(deviceID='light.basic', level=0.1, transition=60)
        req['autoOffAt'] = req['start'] + 120
        record = await self.due(req)
        self.assertEqual(record['state'], 'uncertain')
        await self.advance(record['start'] + 30)
        self.assertEqual(len(self.calls), 1)

    async def test_fractional_percent_report_is_confirmed(self):
        async def fractional(call):
            self.hass.states.async_set('light.basic', 'on', self.attrs | {'brightness': 2.55}, context=call.context)
        self.hass.services.async_register('light', 'turn_on', fractional)
        req = self.request(deviceID='light.basic', level=0.1, transition=60)
        req['autoOffAt'] = req['start'] + 120
        self.assertEqual((await self.due(req))['state'], 'holding')

    async def test_positive_report_outside_percent_bucket_is_rejected(self):
        async def wrong(call):
            self.hass.states.async_set('light.basic', 'on', self.attrs | {'brightness': 4}, context=call.context)
        self.hass.services.async_register('light', 'turn_on', wrong)
        req = self.request(deviceID='light.basic', level=0.1, transition=60)
        req['autoOffAt'] = req['start'] + 120
        self.assertEqual((await self.due(req))['state'], 'uncertain')
