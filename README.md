# hermes-leash

Run a [Hermes Agent](https://hermes-agent.nousresearch.com) Telegram bot on EC2 without it eating your credit card.

A chat agent that's "always on" bills you whether anyone talks to it or not. CloudWatch alarms report spend after it happens. This stack stops the instance instead.

- An idle kill switch greps `gateway.log` for inbound Telegram messages every 60 seconds. After 10 minutes with no message it publishes an SNS notice and shuts the instance down.
- A scheduled Lambda stops `hermes.service` over SSM each night, waits for it to exit, then stops the instance. You get an SNS email either way.
- An AWS Budgets action stops the instance when monthly spend crosses your limit, regardless of idle state.
- An nftables rule blocks outbound traffic to ThreatFox-listed malicious IPs, and a timer refreshes the list every 30 minutes.
- A CloudWatch billing alarm emails you when estimated charges cross a threshold.
- Zero inbound security group rules. Everything runs through SSM Session Manager.

## What's here

```
template.yaml                CloudFormation stack (the whole thing)
scripts/hermes.sh            start/stop/status/ssh control from your laptop
scripts/check-idle.sh        standalone copy of the idle monitor
scripts/threatfox-block.sh   standalone copy of the IOC blocker
scripts/update-auth-secret.sh sync local auth.json to Secrets Manager and instance
```

## Before you deploy

1. **Enable billing alerts** — AWS Console → Billing → Billing preferences → turn on *Receive CloudWatch Billing Alerts*. Billing metrics only exist in us-east-1, so that's where the alarm lives. They're month-to-date and delayed, so treat them as approximate.

2. **Get three secrets into Secrets Manager**, from whatever machine currently has Hermes configured.

   ```bash
   aws secretsmanager create-secret --region us-east-1 --name hermes-agent-env \
     --secret-string file://$HOME/.hermes/.env
   aws secretsmanager create-secret --region us-east-1 --name hermes-agent-auth \
     --secret-string file://$HOME/.hermes/auth.json
   aws secretsmanager create-secret --region us-east-1 --name hermes-agent-config \
     --secret-string file://$HOME/.hermes/config.yaml
   ```

   `.env` needs your `TELEGRAM_BOT_TOKEN`. `auth.json` is your Hermes login. Never commit or paste its contents anywhere.

   If a secret already exists, use `put-secret-value` instead.

3. **Grab the ARNs**

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

Then connect and check the gateway came up.

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
| `EnableThreatFoxBlock` | `true` | Set `false` to deploy without the IOC firewall |

The idle timer can also be disabled at runtime without redeploying.

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

Stopping manually is fine. The idle monitor exists as a backstop.

## How the idle check works

Every 60 seconds a systemd timer runs `check-idle.sh`, which takes the last `inbound message` line from `gateway.log` and compares its timestamp to now. That's the only reliable activity signal. Hermes touches its own state files constantly, so mtimes never go stale and anything based on them never fires.

Two safety rails exist for fresh instances. One that has never seen an inbound message stays up, and so does one whose log file doesn't exist yet.

## How the IOC blocking works

Every 30 minutes, and once more right after boot, a systemd timer runs `threatfox-block.sh`. It pulls abuse.ch's ThreatFox recent feed, keeps IPv4 entries with confidence 80 or higher (`ip` and `ip:port` types), and loads them into an nftables set on the output chain. The chain logs each attempt and rejects it, so a process that tries to reach a blocked IP gets `Connection refused` immediately instead of hanging until timeout. A trailing drop rule catches anything reject can't answer.

Blocked IPs accumulate in `/var/lib/threatfox-block/blocked.txt` and never expire, so the list only grows. If the feed can't be fetched, the script re-applies the last known list instead of flushing the rules.

Spot checks:

```bash
sudo nft get element ip threatfox blocked { 1.2.3.4 }   # is this IP in the set?
sudo journalctl -k -f | grep threatfox-block             # live view of attempted hits
tail -5 /var/log/threatfox-block.log                     # refresh history
```

## Syncing credentials

If your local `~/.hermes/auth.json` gets updated (e.g., after re-authenticating), sync it to the running instance:

```bash
INSTANCE_ID=i-xxxxxxxxxxxxxxxxx \
SECRET_ARN=arn:aws:secretsmanager:us-east-1:123456789012:secret:hermes-agent-auth-xxxxxx \
./scripts/update-auth-secret.sh
```

This updates Secrets Manager and pushes the new credentials to the instance via SSM, then restarts hermes.service.

## Limits

- The budget action stops this one instance. It will not touch anything else in the account.
- Budget evaluation isn't instant. Expect some overshoot past the threshold before the stop lands.
- The idle monitor reads timestamps with GNU `date -d`. It assumes the AL2023 default locale/log format. If you change Hermes' log format, update the grep.
