# N8N Workflow Automation Platform on AWS

## Overview
This repository contains a CloudFormation template that deploys a production-ready n8n workflow automation platform on AWS EC2. The instance runs n8n inside Docker Compose and exposes HTTPS via Caddy using Let's Encrypt. SQLite stores the workflow data under `/opt/n8n/data`.

**Key Features:**
- Automatic HTTPS with Let's Encrypt
- DynamoDB backup for workflows, credentials, and encryption key
- Automatic restore on instance replacement
- Cost-optimized ARM-based EC2 instances
- SSM Session Manager access (no SSH required)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         DynamoDB                                │
│  ┌─────────────┐  ┌────────────────┐  ┌──────────────────┐     │
│  │  workflows  │  │  credentials   │  │  encryption_key  │     │
│  └─────────────┘  └────────────────┘  └──────────────────┘     │
└─────────────┬────────────────────────────────────┬──────────────┘
              │                                    │
         Export (cron)                        Import (boot)
              │                                    │
              ▼                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                         EC2 Instance                            │
│  ┌──────────────┐  ┌────────────────┐  ┌──────────────────┐    │
│  │     n8n      │  │     Caddy      │  │  Backup Scripts  │    │
│  │  (Docker)    │  │   (HTTPS)      │  │  (cron hourly)   │    │
│  └──────────────┘  └────────────────┘  └──────────────────┘    │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  /opt/n8n/data/                                          │   │
│  │    ├── database.sqlite                                   │   │
│  │    └── .encryption_key (persisted to DynamoDB)           │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Resources Created

| Resource | Name | Description |
|----------|------|-------------|
| DynamoDB Table | `N8N-Backup` | Stores workflows, credentials, encryption key |
| EC2 Instance | `N8N-Server` | Runs n8n and Caddy containers |
| Security Group | `N8N-SecurityGroup` | Allows HTTP/HTTPS traffic |
| IAM Role | `N8N-InstanceRole` | SSM access + DynamoDB permissions |
| IAM Instance Profile | `N8N-InstanceProfile` | Attached to EC2 instance |

All resources are tagged with:
- `Project: N8N`
- `Environment: Production` (configurable)

## Prerequisites
- An AWS IAM user with permissions to deploy CloudFormation stacks, create EC2 instances, DynamoDB tables, and manage security groups.
- A DNS record pointing the chosen `DomainName` to the EC2 instance's public IP (Caddy needs this to obtain certificates once the instance is running).
- A local SSH key pair so you keep the private key; CloudFormation references a key pair name that you import beforehand. Example generation command:
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/n8n-key -N ''
  ```
- AWS CLI configured with the desired region/account.

## Deployment

### 1. Import your public key into EC2
```bash
aws ec2 import-key-pair --key-name N8N-KeyPair \
  --public-key-material fileb://~/.ssh/n8n-key.pub
```

### 2. Create the stack
```bash
aws cloudformation create-stack \
  --stack-name N8N \
  --template-body file://cloudformation/template.yaml \
  --parameters ParameterKey=DomainName,ParameterValue=n8n.example.com \
               ParameterKey=N8nVersion,ParameterValue=1.121.3 \
               ParameterKey=KeyPairName,ParameterValue=N8N-KeyPair \
               ParameterKey=BackupFrequencyMinutes,ParameterValue=60 \
               ParameterKey=Environment,ParameterValue=Production \
  --capabilities CAPABILITY_NAMED_IAM
```

### 3. Wait for completion
```bash
aws cloudformation wait stack-create-complete --stack-name N8N
```

### 4. Get the stack outputs
```bash
aws cloudformation describe-stacks --stack-name N8N \
  --query "Stacks[0].Outputs" --output table
```

### 5. Update your DNS
Point your domain's A record to the `N8NServerPublicIP` output value.

### 6. Access n8n
Visit `https://your-domain.com` in your browser.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InstanceType` | `t4g.micro` | EC2 instance type (ARM options are cheaper) |
| `DomainName` | (required) | Domain name for n8n (must point to EC2 IP) |
| `N8nVersion` | `1.121.3` | n8n Docker image version |
| `KeyPairName` | (required) | Existing EC2 key pair name |
| `BackupFrequencyMinutes` | `60` | How often to backup to DynamoDB |
| `Environment` | `Production` | Environment tag (Production/Staging/Development) |

## DynamoDB Backup System

### How it works
1. **On first boot**: A new encryption key is generated and stored in DynamoDB
2. **On subsequent boots**: The encryption key is restored from DynamoDB, ensuring credential decryption works
3. **Every hour** (configurable): A cron job exports workflows and credentials to DynamoDB
4. **On instance replacement**: Workflows and credentials are automatically imported from DynamoDB

### Backup scripts location
- `/opt/n8n/scripts/export-to-dynamodb.sh` - Exports to DynamoDB
- `/opt/n8n/scripts/import-from-dynamodb.sh` - Imports from DynamoDB
- `/opt/n8n/scripts/post-import.sh` - Runs after n8n starts to import workflows

### Manual backup/restore
```bash
# Trigger a manual backup
/opt/n8n/scripts/export-to-dynamodb.sh N8N-Backup us-west-2 /opt/n8n/data

# View backup logs
tail -f /var/log/n8n-backup.log

# Check DynamoDB for backups
aws dynamodb scan --table-name N8N-Backup \
  --query 'Items[].{Key:pk.S,Updated:updated_at.S}'
```

### Data stored in DynamoDB
| Key | Description |
|-----|-------------|
| `encryption_key` | n8n encryption key (required for credential decryption) |
| `workflows` | All workflows exported as JSON (base64 encoded) |
| `credentials` | All credentials exported as JSON (base64 encoded) |
| `database_sqlite` | Full SQLite database backup (base64 encoded) |

## Upgrading n8n Version

### Option 1: In-place upgrade (preserves data, no downtime)
```bash
# SSH/SSM into the instance
cd /opt/n8n
sed -i 's/n8n:OLD_VERSION/n8n:NEW_VERSION/g' docker-compose.yml
docker-compose pull
docker-compose up -d
```

### Option 2: Stack recreation (data restored from DynamoDB)
```bash
# First, trigger a manual backup
aws ssm send-command --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["/opt/n8n/scripts/export-to-dynamodb.sh N8N-Backup us-west-2 /opt/n8n/data"]'

# Then delete and recreate the stack
aws cloudformation delete-stack --stack-name N8N
aws cloudformation wait stack-delete-complete --stack-name N8N
aws cloudformation create-stack ... # with new version
```

## Access

### Session Manager (Recommended)
```bash
aws ssm start-session --target <instance-id>
```

Or use the AWS Console: `EC2 > Instances > N8N-Server > Connect > Session Manager`

### SSH (Optional)
If you need SSH access, temporarily add port 22 to the security group and use your key pair.

## Cleanup
```bash
aws cloudformation delete-stack --stack-name N8N
aws cloudformation wait stack-delete-complete --stack-name N8N
```

**Note:** Deleting the stack will also delete the DynamoDB table with your backups. To preserve backups:
- Export the DynamoDB table to S3 before deletion
- Or set `DeletionPolicy: Retain` on the N8NBackupTable resource

To delete the key pair:
```bash
aws ec2 delete-key-pair --key-name N8N-KeyPair
```

## Cost Estimate

| Resource | Approximate Monthly Cost |
|----------|-------------------------|
| EC2 t4g.micro | ~$6/month (or free tier eligible) |
| EBS 10GB gp3 | ~$0.80/month |
| DynamoDB | Pay-per-request (~$0 for light usage) |
| **Total** | **~$7/month** |

---

## GitHub Actions CI/CD

This repository includes a GitHub Actions workflow for automated deployment and updates.

### Workflow Features

| Trigger | What Happens |
|---------|--------------|
| Push to `main` | Validates template, updates stack, applies in-place update, refreshes Caddy, verifies deployment |
| Manual: `update` | Same as push, with optional version override |
| Manual: `deploy-new` | Creates new stack (if doesn't exist) |
| Manual: `status` | Shows current stack status and container health |
| Manual: `delete` | Deletes the stack (requires approval) |

### Setup Instructions

#### 1. Create an IAM Role for GitHub Actions (OIDC)

Create a role that GitHub Actions can assume using OIDC:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/n8n-optimized:*"
        }
      }
    }
  ]
}
```

Attach these permissions to the role:
- `AWSCloudFormationFullAccess`
- `AmazonEC2FullAccess`
- `AmazonDynamoDBFullAccess`
- `IAMFullAccess`
- `AmazonSSMFullAccess`

#### 2. Configure GitHub Secrets

Go to your repository **Settings → Secrets and variables → Actions** and add:

| Secret | Description |
|--------|-------------|
| `AWS_ROLE_ARN` | ARN of the IAM role created above |
| `DOMAIN_NAME` | Your domain (e.g., `n8n.example.com`) |
| `KEY_PAIR_NAME` | Name of your EC2 key pair |

#### 3. Enable GitHub OIDC Provider in AWS

If you haven't already, create the OIDC identity provider in IAM:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### Usage Examples

#### Update n8n to a new version
1. Go to **Actions → N8N-Optimized CI/CD**
2. Click **Run workflow**
3. Select `update` action
4. Enter the new version (e.g., `1.122.0`)
5. Click **Run workflow**

The workflow will:
1. ✅ Validate the CloudFormation template
2. ✅ Update the stack with the new version
3. ✅ Wait for cfn-hup to apply the in-place update (~90 seconds)
4. ✅ Restart Caddy via SSM
5. ✅ Verify n8n is accessible

#### Deploy from scratch
If creating a new stack, the workflow will use the `DOMAIN_NAME` and `KEY_PAIR_NAME` secrets.

#### Monitor deployment
Check the **Actions** tab for workflow runs. Each step provides detailed summaries in the GitHub Actions UI.
