"""Explicitly provisioned, authenticated HA one-shot schedules. No discovery or auto-install."""
from datetime import datetime, timedelta, timezone
from functools import partial
import json
import logging
import sqlite3
import time

from aiohttp import web
import voluptuous as vol

from homeassistant.const import EVENT_HOMEASSISTANT_STOP
from homeassistant.core import Context, CoreState
from homeassistant.helpers import config_validation as cv
from homeassistant.helpers.event import async_track_time_interval
from homeassistant.helpers.http import HomeAssistantView

from .runtime import Runtime
from .store import Conflict, InvalidRequest, JournalCorrupt, NotFound, Store

DOMAIN = 'lorisiot_schedule'
PREFIX = '/api/lorisiot_schedule/v1'
_LOGGER = logging.getLogger(__name__)
CONFIG_SCHEMA = vol.Schema({
    DOMAIN: vol.Schema({vol.Required('allowed_targets'): vol.All(cv.ensure_list, [cv.entity_id], vol.Length(max=256))})
}, extra=vol.ALLOW_EXTRA)


# Mirrored from homeassistant.components.light so this component keeps no dependency on the light
# platform: LightEntityFeature.TRANSITION, and the colour modes that carry a brightness.
LIGHT_TRANSITION_FEATURE = 32
BRIGHTNESS_COLOR_MODES = frozenset(
    {'brightness', 'color_temp', 'hs', 'xy', 'rgb', 'rgbw', 'rgbww', 'white'})


def ramp_capability_error(hass, record):
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
    if transition is not None and not (type(features) is int and features & LIGHT_TRANSITION_FEATURE):
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
                          'durable': True, 'executionPolicy': 'at_most_once'})


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
        error = ramp_capability_error(self.hass, body['record'])
        if error is not None:
            return self.json({'error': error}, status_code=400)
        return await self.invoke(self.state['store'].put, user, body['record'],
                                 expected_revision=body.get('expectedRevision'))


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
    try:
        store = await hass.async_add_executor_job(partial(
            Store, hass.config.path('.storage', DOMAIN + '.sqlite'), targets))
    except (InvalidRequest, JournalCorrupt, sqlite3.Error, OSError):
        _LOGGER.error('Schedule journal unavailable; integration was not started')
        return False

    async def execute(record):
        user = await hass.auth.async_get_user(record['userID'])
        if (hass.state is not CoreState.running or user is None or not user.is_active
                or not user.is_admin or record['deviceID'] not in targets):
            return False
        target = record['deviceID']
        data = {'entity_id': target}
        if record['on'] and record['level'] is not None:
            data['brightness'] = round(record['level'] * 255)
        if record['transition'] is not None:
            data['transition'] = record['transition']
        before = datetime.now(timezone.utc)
        await hass.services.async_call(target.split('.', 1)[0], 'turn_on' if record['on'] else 'turn_off',
                                       data, blocking=True, context=Context(user_id=user.id))
        observed = hass.states.get(target)
        # Service completion alone is not device confirmation. Require a report after the send.
        if observed is None or observed.last_reported < before:
            return False
        if record['transition'] is not None:
            # The luminaire owns the ramp. Its terminal level, and a fade-out's final off, land long
            # after the command deadline, so only the start of the ramp is confirmed here.
            if record['on']:
                return observed.state == 'on'
            return True
        if observed.state != ('on' if record['on'] else 'off'):
            return False
        return record['level'] is None or observed.attributes.get('brightness') == data['brightness']

    runtime = Runtime(store, execute, executor=hass.async_add_executor_job)
    try:
        await runtime.start()
    except (JournalCorrupt, sqlite3.Error, OSError):
        _LOGGER.error('Schedule recovery failed; integration was not started')
        return False
    state = {'store': store, 'runtime': runtime, 'targets': targets, 'healthy': True}
    hass.data[DOMAIN] = state
    for view in [HealthView, RecordsView, RecordView]:
        hass.http.register_view(view(hass, state))

    async def poll(_now):
        if hass.state is not CoreState.running:
            return
        try:
            await runtime.poll()
            state['healthy'] = True
        except Exception:
            state['healthy'] = False
            _LOGGER.error('Schedule processing unavailable; no uncertain intent will be replayed')

    cancel_poll = async_track_time_interval(hass, poll, timedelta(seconds=1))

    async def stop(_event):
        cancel_poll()
        await runtime.close()

    hass.bus.async_listen_once(EVENT_HOMEASSISTANT_STOP, stop)
    return True
