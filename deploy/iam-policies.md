# Permisos IAM

Reemplaza `<INTERNAL_TOOLS>`, `<PAY>`, `<AXIS>` por los IDs de cuenta.

## 1. Role de la EC2 (cuenta internal-tools) — `aloha-support-bot-instance`

Managed policy: `AmazonSSMManagedInstanceCore` (Session Manager + Run Command).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    {
      "Effect": "Allow",
      "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
      "Resource": "arn:aws:ecr:us-east-1:<INTERNAL_TOOLS>:repository/aloha-support-bot"
    },
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:us-east-1:<INTERNAL_TOOLS>:secret:aloha-support-bot/env-*"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:us-east-1:<INTERNAL_TOOLS>:parameter/aloha-support-bot/*"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:us-east-1:<INTERNAL_TOOLS>:log-group:/aloha-support-bot*"
    },
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": [
        "arn:aws:iam::<PAY>:role/support-bot-invoker",
        "arn:aws:iam::<AXIS>:role/support-bot-invoker"
      ]
    }
  ]
}
```

## 2. Role en cada cuenta de producto — `support-bot-invoker`

Trust policy (solo el role de la EC2 puede asumirlo):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::<INTERNAL_TOOLS>:role/aloha-support-bot-instance" },
    "Action": "sts:AssumeRole"
  }]
}
```

Permisos (solo invocar ESE agente):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "bedrock-agentcore:InvokeAgentRuntime",
    "Resource": "arn:aws:bedrock-agentcore:us-east-1:<PAY>:runtime/pay_support-*"
  }]
}
```

## 3. Role de deploy para GitHub Actions (OIDC) — `aloha-support-bot-deploy`

Trust: provider `token.actions.githubusercontent.com`, condición
`sub = repo:<ORG>/aloha-support-bot:ref:refs/heads/main`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:us-east-1:<INTERNAL_TOOLS>:repository/aloha-support-bot"
    },
    { "Effect": "Allow", "Action": "ec2:DescribeInstances", "Resource": "*" },
    {
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ssm:us-east-1::document/AWS-RunShellScript"
    },
    {
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": "arn:aws:ec2:us-east-1:<INTERNAL_TOOLS>:instance/*",
      "Condition": { "StringEquals": { "aws:ResourceTag/App": "aloha-support-bot" } }
    },
    { "Effect": "Allow", "Action": ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"], "Resource": "*" }
  ]
}
```
