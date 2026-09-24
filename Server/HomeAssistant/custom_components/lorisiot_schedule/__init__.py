"""Explicitly provisioned, authenticated HA one-shot schedules. No discovery or auto-install."""
import asyncio
from datetime import datetime, timedelta, timezone
from functools import partial
import json
import logging
import math
import sqlite3
import time

from aiohttp import web
import voluptuous as vol

from homeassistant.const import EVENT_HOMEASSISTANT_STOP
from homeassistant.core import Context, CoreState, callback
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.event import async_track_time_interval
from homeassistant.helpers.http import HomeAssistantView

from .runtime import Runtime
from .ramps import StepRamps
from .store import Conflict, InvalidRequest, JournalCorrupt, NotFound, Store

DOMAIN = 'lorisiot_schedule'
PREFIX = '/api/lorisiot_schedule/v1'
_LOGGER = logging.getLogger(__name__)
CONFIG_SCHEMA = vol.Schema({
    DOMAIN: vol.Schema({
        vol.Required('allowed_targets'): vol.All(cv.ensure_list, [cv.entity_id], vol.Length(max=256)),
        vol.Optional('stepped_sunrise_targets', default=[]): vol.All(cv.ensure_list, [cv.entity_id], vol.Length(max=256)),
    })
}, extra=vol.ALLOW_EXTRA)


# Mirrored from homeassistant.components.light so this component keeps no dependency on the light
# platform: LightEntityFeature.TRANSITION, and the colour modes that carry a brightness.
LIGHT_TRANSITION_FEATURE = 32
BRIGHTNESS_COLOR_MODES = frozenset(
    {'brightness', 'color_temp', 'hs', 'xy', 'rgb', 'rgbw', 'rgbww', 'white'})


def ramp_capability_error(hass, record, stepped_targets=()):
    """A ramp the luminaire cannot perform must be refused now, never silently degraded at wake."""
    if not isinstance(record, dict):
        return None  # The journal rejects a malformed record with its own error.
    level, transition = record.get('level'), record.get('transition')
    if level is None and transition is None:
        return None
    target = record.get('deviceID')
    if not isinstance(target, str):
        return None
    observed = hass.states.get(target)
    if observed is None:
        return 'target_state_unknown'
    features = observed.attributes.get('supported_features')
    modes = observed.attributes.get('supported_color_modes') or ()
    if level is not None and not BRIGHTNESS_COLOR_MODES.intersection(modes):
        return 'target_has_no_brightness'
    if (transition is not None and not (type(features) is int and features & LIGHT_TRANSITION_FEATURE)
            and not ('autoOffAt' in record and target in stepped_targets)):
        return 'target_has_no_transition'
    return None


def public_record(record):
    return {key: value for key, value in record.items() if key != 'userID'}


async def bounded_json(request):
    limit = 16_384
    if request.content_length is not None and request.content_length > limit:
        raise web.HTTPRequestEntityTooLarge(max_size=limit, actual_size=request.content_length)
    body = bytearray()
    async for chunk in request.content.iter_chunked(4096):
        body.extend(chunk)
        if len(body) > limit:
            raise web.HTTPRequestEntityTooLarge(max_size=limit, actual_size=len(body))
    try:
        result = json.loads(body)
        if not isinstance(result, dict):
            raise ValueError()
        return result
    except (ValueError, UnicodeError) as error:
        raise web.HTTPBadRequest(text='Invalid schedule request') from error


class AdminView(HomeAssistantView):
    requires_auth = True

    def __init__(self, hass, state):
        self.hass = hass
        self.state = state

    def user(self, request):
        user = request.get('hass_user')
        if user is None:
            raise web.HTTPUnauthorized()
        if not user.is_admin or not user.is_active:
            raise web.HTTPForbidden()
        return user.id

    async def invoke(self, function, *args, **kwargs):
        try:
            record = await self.hass.async_add_executor_job(partial(function, *args, **kwargs))
            return self.json(public_record(record))
        except InvalidRequest:
            return self.json({'error': 'invalid_request'}, status_code=400)
        except NotFound:
            return self.json({'error': 'not_found'}, status_code=404)
        except Conflict:
            return self.json({'error': 'unconfirmed_or_conflict'}, status_code=409)
        except (JournalCorrupt, sqlite3.Error, OSError):
            self.state['healthy'] = False
            return self.json({'error': 'journal_unavailable'}, status_code=503)


class HealthView(AdminView):
    url = PREFIX + '/health'
    name = 'api:lorisiot_schedule:health'

    async def get(self, request):
        self.user(request)
        return self.json({'protocolVersion': 1, 'ready': self.hass.state is CoreState.running and self.state['healthy'],
                          'serverTime': time.time(), 'allowedTargets': sorted(self.state['targets']),
                          'minLeadSeconds': 15, 'maxLateSeconds': Store.MAX_LATE_SECONDS,
                          'durable': True, 'executionPolicy': 'at_most_once',
                          'sunriseAutoOffVersion': 1})


class RecordsView(AdminView):
    url = PREFIX + '/records'
    name = 'api:lorisiot_schedule:records'

    async def post(self, request):
        user = self.user(request)
        if self.hass.state is not CoreState.running or not self.state['healthy']:
            return self.json({'error': 'server_not_ready'}, status_code=503)
        body = await bounded_json(request)
        if set(body) - {'record', 'expectedRevision'} or 'record' not in body:
            raise web.HTTPBadRequest(text='Invalid schedule request')
        error = ramp_capability_error(self.hass, body['record'], self.state['stepped_targets'])
        if error is not None:
            return self.json({'error': error}, status_code=400)
        return await self.invoke(self.state['store'].put, user, body['record'],
                                 expected_revision=body.get('expectedRevision'))


class RetireView(AdminView):
    url = PREFIX + '/retire'
    name = 'api:lorisiot_schedule:retire'

    async def post(self, request):
        user = self.user(request)
        if self.hass.state is not CoreState.running or not self.state['healthy']:
            return self.json({'error': 'server_not_ready'}, status_code=503)
        body = await bounded_json(request)
        if set(body) != {'record'}:
            raise web.HTTPBadRequest(text='Invalid retirement request')
        return await self.invoke(self.state['store'].retire_absent_sunrise, user, body['record'])


class RecordView(AdminView):
    url = PREFIX + '/records/{remote_id}'
    name = 'api:lorisiot_schedule:record'

    async def get(self, request, remote_id):
        return await self.invoke(self.state['store'].get, self.user(request), remote_id)

    async def delete(self, request, remote_id):
        user = self.user(request)
        body = await bounded_json(request)
        if set(body) != {'owner', 'expectedRevision'}:
            raise web.HTTPBadRequest(text='Invalid cancellation request')
        return await self.invoke(self.state['store'].remove, user, remote_id, body['owner'], body['expectedRevision'])


async def async_setup(hass, config):
    if DOMAIN not in config:
        return True
    if DOMAIN in hass.data:
        return True
    targets = frozenset(config[DOMAIN]['allowed_targets'])
    stepped_targets = frozenset(config[DOMAIN].get('stepped_sunrise_targets', []))
    if not stepped_targets <= targets or any(not target.startswith('light.') for target in stepped_targets):
        _LOGGER.error('Stepped sunrise targets must be explicitly allowed lights')
        return False
    try:
        store = await hass.async_add_executor_job(partial(
            Store, hass.config.path('.storage', DOMAIN + '.sqlite'), targets))
    except (InvalidRequest, JournalCorrupt, sqlite3.Error, OSError):
        _LOGGER.error('Schedule journal unavailable; integration was not started')
        return False

    # Event-loop-owned guard: revocation is synchronous, before asynchronous journal writes.
    # A missing/foreign context is conservative loss of ownership, not proof of a manual action.
    sunrise_contexts = {}
    revoked = set()

    async def execute(record, *, step_level=None, step_due=None):
        user = await hass.auth.async_get_user(record['userID'])
        if (hass.state is not CoreState.running or user is None or not user.is_active
                or not user.is_admin or record['deviceID'] not in targets):
            return False
        target = record['deviceID']
        session = 'autoOffAt' in record
        off_phase = record['state'] == 'offExecuting'
        on = record['on'] and not off_phase
        context = Context(user_id=user.id)
        if session:
            current = await hass.async_add_executor_job(partial(store.get, record['userID'], record['remoteID']))
            if current['revision'] != record['revision'] or current['state'] != record['state']:
                return False
            if off_phase or step_level is not None:
                context_id = sunrise_contexts.get(target)
                observed = hass.states.get(target)
                if (target in revoked or context_id != record['remoteID'].replace('-', '')
                        or observed is None or observed.state != 'on'
                        or observed.context.id != context_id):
                    return False
                context = Context(id=context_id, user_id=user.id)
            else:
                # Never turn an unavailable device's unknown state into an OFF obligation.
                observed = hass.states.get(target)
                if observed is None or observed.state not in ('on', 'off') or ramp_capability_error(hass, record, stepped_targets):
                    return False
                context = Context(id=record['remoteID'].replace('-', ''), user_id=user.id)
                sunrise_contexts[target] = context.id
                revoked.discard(target)
        due = step_due if step_level is not None else record['autoOffAt'] if off_phase else record['start']
        observed = hass.states.get(target)
        features = observed.attributes.get('supported_features', 0) if observed else 0
        stepped = (session and target in stepped_targets
                   and not (type(features) is int and features & LIGHT_TRANSITION_FEATURE))
        software = stepped and not off_phase and step_level is None
        if (hass.state is not CoreState.running or not user.is_active or not user.is_admin
                or not due <= store.clock() <= due + Store.MAX_LATE_SECONDS):
            return False
        data = {'entity_id': target}
        if on and record['level'] is not None:
            data['brightness'] = round(record['level'] * 255)
            if step_level is not None:
                data['brightness'] = step_level
            elif software:
                current = observed.attributes.get('brightness', 1) if observed.state == 'on' else 1
                data['brightness'] = min(data['brightness'], max(1, current if type(current) is int else 1))
        brightness_bounds = None
        if on and stepped and 'brightness' in data:
            # Many adapters expose 0..255 but transport integer percentages. Start at
            # a nonzero 1%, send the ceiling, and accept only that percentage's floor/
            # ceiling representation (or fractional value), never an arbitrary tolerance.
            percent = max(1, min(100, round(data['brightness'] * 100 / 255)))
            scaled = percent * 255 / 100
            brightness_bounds = (math.floor(scaled), math.ceil(scaled))
            data['brightness'] = brightness_bounds[1]
        if record['transition'] is not None and not off_phase and not software and step_level is None:
            data['transition'] = record['transition']
        before = datetime.now(timezone.utc)
        await hass.services.async_call(target.split('.', 1)[0], 'turn_on' if on else 'turn_off',
                                       data, blocking=True, context=context)
        observed = hass.states.get(target)
        # Service completion alone is not device confirmation. Require a report after the send.
        if observed is None or observed.last_reported < before:
            return False
        if session and (target in revoked or observed.context.id != context.id):
            return False
        if record['transition'] is not None and not off_phase and not software and step_level is None:
            # The luminaire owns the ramp. Its terminal level, and a fade-out's final off, land long
            # after the command deadline, so only the start of the ramp is confirmed here.
            if record['on']:
                return observed.state == 'on'
            return True
        if observed.state != ('on' if on else 'off'):
            return False
        reported = observed.attributes.get('brightness')
        if brightness_bounds is not None:
            confirmed = (type(reported) in (int, float) and math.isfinite(reported)
                         and reported > 0 and brightness_bounds[0] <= reported <= brightness_bounds[1])
        else:
            confirmed = off_phase or record['level'] is None or reported == data['brightness']
        if confirmed and software:
            ramps.add(record | {'revision': record['revision'] + 1}, data['brightness'])
        return confirmed

    runtime = Runtime(store, execute, executor=hass.async_add_executor_job)
    try:
        await runtime.start()
    except (JournalCorrupt, sqlite3.Error, OSError):
        _LOGGER.error('Schedule recovery failed; integration was not started')
        return False
    state = {'store': store, 'runtime': runtime, 'targets': targets,
             'stepped_targets': stepped_targets, 'healthy': True}
    hass.data[DOMAIN] = state

    async def persist_revocation(target):
        try:
            await hass.async_add_executor_job(store.revoke_sunrise, target)
        except Exception:
            state['healthy'] = False
            _LOGGER.error('Sunrise ownership journal unavailable; OFF remains blocked')

    @callback
    def revoke(target):
        ramps.cancel(target)
        if target in sunrise_contexts and target not in revoked:
            revoked.add(target)
            hass.async_create_task(persist_revocation(target))

    async def execute_step(record, level, due):
        claimed = None
        confirmed = False
        try:
            claimed = await hass.async_add_executor_job(partial(
                store.claim_ramp_step, record['remoteID'], record['revision']))
            confirmed = await execute(claimed, step_level=level, step_due=due)
            return confirmed
        finally:
            if claimed is not None:
                await asyncio.shield(hass.async_add_executor_job(partial(
                    store.finish, claimed['remoteID'], claimed['revision'], confirmed=confirmed)))

    ramps = StepRamps(lambda: store.clock(), execute_step, revoke)
    state['ramps'] = ramps

    @callback
    def state_changed(event):
        target = event.data.get('entity_id')
        if target not in sunrise_contexts:
            return
        observed = event.data.get('new_state')
        if observed is None or observed.context.id != sunrise_contexts[target] or observed.state in ('unknown', 'unavailable'):
            revoke(target)

    @callback
    def service_called(event):
        if event.data.get('domain') not in ('light', 'homeassistant') or event.data.get('service') not in ('turn_on', 'turn_off', 'toggle'):
            return
        data = event.data.get('service_data') or {}
        entities = data.get('entity_id')
        # Area/device/all selectors can hide the exact target: relinquish conservatively.
        if isinstance(entities, str):
            entities = [part.strip() for part in entities.split(',')]
        selected = set(entities or ()) if isinstance(entities, (list, tuple)) else set()
        for target, context_id in tuple(sunrise_contexts.items()):
            if event.context.id != context_id and (not selected or 'all' in selected or target in selected
                                                   or data.get('area_id') or data.get('device_id') or data.get('label_id')):
                revoke(target)

    @callback
    def report_filter(data):
        return data.get('entity_id') in sunrise_contexts

    @callback
    def state_reported(event):
        target = event.data.get('entity_id')
        # Identical passive reports receive a fresh event context while HA keeps
        # the original State.context. They do not establish a manual takeover.
        # Explicit service calls remain guarded independently by service_called.
        observed = event.data.get('new_state')
        if observed is None or observed.context.id != sunrise_contexts.get(target):
            revoke(target)

    cancel_reports = hass.bus.async_listen('state_reported', state_reported, event_filter=report_filter)
    cancel_states = hass.bus.async_listen('state_changed', state_changed)
    cancel_services = hass.bus.async_listen('call_service', service_called)
    for view in [HealthView, RecordsView, RecordView, RetireView]:
        hass.http.register_view(view(hass, state))

    async def poll(_now):
        if hass.state is not CoreState.running:
            return
        try:
            await ramps.poll()
            await runtime.poll()
            state['healthy'] = True
        except Exception:
            state['healthy'] = False
            _LOGGER.error('Schedule processing unavailable; no uncertain intent will be replayed')

    cancel_poll = async_track_time_interval(hass, poll, timedelta(seconds=1))

    async def stop(_event):
        cancel_poll()
        cancel_states()
        cancel_reports()
        cancel_services()
        await ramps.close()
        await runtime.close()

    hass.bus.async_listen_once(EVENT_HOMEASSISTANT_STOP, stop)
    return True
