# Mobile channel API

The `mobile` channel is a first-party HTTPS transport for private NanoClaw
clients such as NanoClaw Chat for Android Auto. It is registered on the shared
webhook server at `/webhook/mobile`.

## Provisioning

Set a high-entropy, temporary `NANOCLAW_MOBILE_PAIRING_CODE` in the host
environment and restart NanoClaw. Enter that code only in the phone setup UI,
then remove or rotate it after pairing. It is never placed in the APK or shown
on the car display.

`POST /webhook/mobile/pair` accepts:

```json
{ "pairingCode": "…", "deviceName": "rs phone" }
```

The response contains a 15-minute access token and a rotating refresh token.
The client must store the refresh token in Android Keystore-backed secure
storage. `POST /webhook/mobile/token` rotates it and returns another access
token. `DELETE /webhook/mobile/device` revokes the current device.

## Authenticated operations

Pass the access token as `Authorization: Bearer …`.

- `GET /webhook/mobile/agents` returns every current agent group. The client
  does not maintain a second allowlist; removing an agent from NanoClaw removes
  it from discovery and subsequent sends fail closed.
- `POST /webhook/mobile/messages` accepts `agentGroupId`, `clientMessageId`,
  and `text`. A client message ID is idempotent per device and returns its
  original receipt when retried. Prompts are limited to 2,000 characters.
- `GET /webhook/mobile/events?after=<seq>` returns up to 100 ordered events for
  catch-up after reconnect.
- `POST /webhook/mobile/events/<id>/read` marks an event read.

Each paired device gets one durable NanoClaw conversation/session per agent.
Inbound messages are stamped with `surface=android_auto`, `driving=true`, and
a concise speech-friendly response preference. Credentials are stored only as
SHA-256 hashes in NanoClaw's database, and API responses disable caching.

The webhook must be exposed only through the installation's authenticated TLS
ingress. Never publish the raw webhook port directly to the internet.
