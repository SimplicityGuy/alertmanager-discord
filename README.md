# alertmanager-discord

![alertmanager-discord](https://github.com/SimplicityGuy/alertmanager-discord/actions/workflows/build.yml/badge.svg) ![License: MIT](https://img.shields.io/github/license/SimplicityGuy/alertmanager-discord) [![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit)](https://github.com/pre-commit/pre-commit)

Give this a webhook (with the DISCORD_WEBHOOK environment variable) and point it as a webhook on alertmanager, and it will post your alerts into a discord channel for you as they trigger:

![](/images/demo-new.png)

## Warning

This program is not a replacement to alertmanager, it accepts webhooks from alertmanager, not Prometheus.

The standard data flow should be:

```
Prometheus -------------> alertmanager -------------------> alertmanager-discord

alerting:                 receivers:
  alertmanagers:          - name: 'discord_webhook'         environment:
  - static_configs:         webhook_configs:                   - DISCORD_WEBHOOK=https://discordapp.com/api/we...
    - targets:              - url: 'http://localhost:9094'
       - 127.0.0.1:9093
```

## Example alertmanager config:

```
global:
  # The smarthost and SMTP sender used for mail notifications.
  smtp_smarthost: 'localhost:25'
  smtp_from: 'alertmanager@example.org'
  smtp_auth_username: 'alertmanager'
  smtp_auth_password: 'password'

# The directory from which notification templates are read.
templates:
- '/etc/alertmanager/template/*.tmpl'

# The root route on which each incoming alert enters.
route:
  group_by: ['alertname']
  group_wait: 20s
  group_interval: 5m
  repeat_interval: 3h
  receiver: discord_webhook

receivers:
- name: 'discord_webhook'
  webhook_configs:
  - url: 'http://localhost:9094'
```

## Docker

Please see [alertmanager-discord](https://github.com/users/SimplicityGuy/packages/container/package/alertmanager-discord) for builds.
