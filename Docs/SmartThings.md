# SmartThings native provider — local implementation checkpoint

`IoTSmartThings` talks to Samsung's REST API directly; Home Assistant is not involved.
Add the Swift package product and provide `SmartThingsProvider(token:allowsControl:)`
with a closure returning `SmartThingsAccessToken(value:expiresAt:)` from your OAuth
coordinator. Keep authorization/refresh and namespaced secure storage in the host app.
Do not ship a client secret in an Apple app or paste account tokens into support logs.
No authorization registration or callback backend is supplied by this SDK module.

Call `connect()`, `devices()`, then `capabilities(for:)`. Every component has a distinct
`UUID/component` identity scoped by the provider ID. Read state is supported; generic
power and level commands are available only when explicitly enabled and announced by
the component. Unknown capabilities are not converted into arbitrary commands.
No subscription, background polling, provisioning or scheduling is advertised.

Status is a cloud snapshot. Remote observation timestamps are retained; old or absent
observations are not marked current merely because HTTP succeeded. Even matching
readback produces an accepted receipt, not a claim of physical application. Lost command
responses are uncertain and never automatically replayed. Disconnect cancels pending
HTTP and invalidates retained handles, including after a new connection.

Requests stay on HTTPS api.smartthings.com, approved device routes only; redirects are
refused by BoundedHTTPClient. Pagination, response size, inventory and attribute counts
are bounded. Fresh authorization is requested before each HTTP exchange.

Validation: 15 fixture tests pass, including cancellation while authorization is pending,
foreign pagination, invalid routes, offline/foreign targets, read-only default, retained
handles, stale observations and command uncertainty. No real Samsung account/device has
been tested. Velya does not yet link this module. Local code has not been committed/pushed.

Protocol reference: https://github.com/SmartThingsCommunity/smartthings-core-sdk/blob/master/src/endpoint/devices.ts
OAuth integration: https://developer.smartthings.com/docs/service-integrations/architecture-and-auth-flow
