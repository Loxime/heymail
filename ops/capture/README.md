# HeyMail Capture

Local/staging inbox for application development. It deliberately does not use the production HeyMail SMTP delivery path.

Start it:

```bash
docker compose -f compose.capture.yaml up -d
```

Default endpoints:

- SMTP: `127.0.0.1:1025`
- Inbox UI: `http://127.0.0.1:8025`

Symfony example:

```dotenv
MAILER_DSN=smtp://127.0.0.1:1025
```

If the Symfony application itself runs in Docker, attach it to the same Compose network or include the capture service in that application's Compose file and use `smtp://capture:1025`.

For staging, publish the web UI only behind the staging reverse proxy/authentication layer. Do not expose port 1025 to the public Internet.

This first capture backend uses Mailpit as a hardened capture engine while HeyMail keeps the production API/delivery path. A native HeyMail capture store/API can replace it later without changing application mail configuration.
