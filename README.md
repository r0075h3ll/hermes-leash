# hermes-leash

Run a [Hermes Agent](https://hermes-agent.nousresearch.com) Telegram bot on EC2 without it quietly eating your credit card.

A chat agent that's "always on" is mostly just always billing you. CloudWatch alarms tell you you're bleeding; they don't stop it. This stack adds teeth:

- **Idle kill switch** — greps the gateway log for inbound Telegram messages every 60 seconds. No human has talked to the bot for 10 minutes? It publishes an SNS notice and shuts the instance down.
- **Budget hard stop** — an AWS Budgets action that stops the instance when your monthly spend crosses the limit, regardless of idle state.
- **Billing alarm** — email when estimated charges cross a threshold.
- **No open ports** — zero inbound security group rules. Everything runs through SSM Session Manager.

## What's here

```
template.yaml          CloudFormation stack (the whole thing)
scripts/hermes.sh      start/stop/status/ssh control from your laptop
scripts/check-idle.sh  standalone copy of the idle monitor
```

## Before you deploy

1. **Enable billing alerts** — AWS Console → Billing → Billing preferences → turn on *Receive CloudWatch Billing Alerts*. Billing metrics only exist in us-east-1, so that's where the alarm lives. They're month-to-date and delayed; treat them as a rough gauge, not a meter.

2. **Get three secrets into Secrets Manager**, from whatever machine currently has Hermes configured:

   ```bash
   aws secretsmanager create-secret --region us-east-1 --name hermes-agent-env \
     --secret-string file://~/.hermes/.env
   aws secretsmanager create-secret --region us-east-1 --name hermes-agent-auth \
     --secret-string file://~/.hermes/auth.json
   aws secretsmanager create-secret --region us-east-1 --name hermes-agent-config \
     --secret-string file://~/.hermes/config.yaml
   ```

   `.env` needs your `TELEGRAM_BOT_TOKEN`. `auth.json` is your Hermes login — never commit or paste its contents anywhere.

   If a secret already exists, use `put-secret-value` instead.

3. **Grab the ARNs:**

   ```bash
   for s in env auth config; do
     aws secretsmanager describe-secret --region us-east-1 \
       --secret-id hermes-agent-$s --query ARN --output text
   done
   ```

## Deploy

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name hermes-agent \
  --template-file template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    HermesEnvSecretArn="<env secret arn>" \
    HermesAuthSecretArn="<auth secret arn>" \
    HermesConfigSecretArn="<config secret arn>" \
    AlertEmail="you@example.com" \
    BudgetLimitUsd=5 \
    BillingAlarmThresholdUsd=5
```

The stack uses the account's default VPC (it must have outbound internet access). When it finishes, click the SNS confirmation email or you'll never see an alert.

Then connect and check the gateway came up:

```bash
INSTANCE_ID=$(aws cloudformation describe-stacks --region us-east-1 --stack-name hermes-agent \
  --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

aws ssm start-session --region us-east-1 --target "$INSTANCE_ID"
systemctl status hermes
journalctl -u hermes -f
```

## Parameters worth knowing

| Parameter | Default | What it does |
|---|---|---|
| `BudgetLimitUsd` | `10` | Monthly spend at which Budgets force-stops the instance |
| `BillingAlarmThresholdUsd` | `10` | Email alert threshold for estimated charges |
| `EnableIdleShutdown` | `true` | Set `false` to skip the idle monitor entirely |
| `IdleTimeoutMinutes` | `10` | Minutes of Telegram silence before auto-stop |

The idle timer can also be disabled at runtime without redeploying:

```bash
touch /home/hermes/.idle-shutdown-disabled   # inside an SSM session
```

## Controlling it day to day

```bash
export HERMES_INSTANCE_ID=i-xxxxxxxxxxxxxxxxx

scripts/hermes.sh start    # boots it, waits, restarts hermes.service if needed
scripts/hermes.sh status   # instance state + service uptime
scripts/hermes.sh ssh      # SSM session
scripts/hermes.sh stop     # stops the service cleanly, then the instance
```

Stopping manually is fine — the idle monitor is a backstop, not a requirement.

## How the idle check works

Every 60 seconds a systemd timer runs `check-idle.sh`, which takes the last `inbound message` line from `gateway.log` and compares its timestamp to now. That's the only reliable activity signal: Hermes touches its own state files constantly, so mtimes never go stale and anything based on them never fires.

Two deliberate safety rails: if the log shows no inbound messages *ever* (fresh instance), it stays up rather than shutting down immediately; and if the log file itself doesn't exist yet, it stays up.

## Limits

- The budget action stops this one instance. It will not touch anything else in the account.
- Budget evaluation isn't instant — expect some overshoot past the threshold before the stop lands.
- The idle monitor reads timestamps with GNU `date -d`; it assumes the AL2023 default locale/log format. If you change Hermes' log format, update the grep.
