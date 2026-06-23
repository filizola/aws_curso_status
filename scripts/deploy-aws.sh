#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY="${ECR_REPOSITORY:-aws-curso-status}"
APP_RUNNER_SERVICE="${APP_RUNNER_SERVICE:-aws-curso-status}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

echo "==> Garantindo repositório ECR: ${ECR_REPOSITORY}"
aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$ECR_REPOSITORY" --image-scanning-configuration scanOnPush=true

echo "==> Build e push da imagem Docker"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
docker build -t "$IMAGE_URI" .
docker push "$IMAGE_URI"

ROLE_NAME="AppRunnerECRAccessRole"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> Criando role IAM para App Runner"
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"build.apprunner.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess
fi

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
SERVICE_ARN="$(aws apprunner list-services \
  --query "ServiceSummaryList[?ServiceName=='${APP_RUNNER_SERVICE}'].ServiceArn | [0]" \
  --output text)"

if [ "$SERVICE_ARN" = "None" ] || [ -z "$SERVICE_ARN" ]; then
  echo "==> Criando serviço App Runner"
  aws apprunner create-service \
    --service-name "$APP_RUNNER_SERVICE" \
    --source-configuration "{
      \"AuthenticationConfiguration\": {\"AccessRoleArn\": \"${ROLE_ARN}\"},
      \"AutoDeploymentsEnabled\": true,
      \"ImageRepository\": {
        \"ImageIdentifier\": \"${IMAGE_URI}\",
        \"ImageRepositoryType\": \"ECR\",
        \"ImageConfiguration\": {\"Port\": \"8080\"}
      }
    }" \
    --instance-configuration '{"Cpu":"1024","Memory":"2048"}' \
    --health-check-configuration '{"Protocol":"HTTP","Path":"/health","Interval":10,"Timeout":5,"HealthyThreshold":1,"UnhealthyThreshold":5}'
else
  echo "==> Serviço já existe, iniciando novo deploy"
  aws apprunner start-deployment --service-arn "$SERVICE_ARN"
fi

echo "==> Aguardando serviço ficar RUNNING..."
for _ in $(seq 1 30); do
  STATUS="$(aws apprunner list-services \
    --query "ServiceSummaryList[?ServiceName=='${APP_RUNNER_SERVICE}'].Status | [0]" \
    --output text)"
  URL="$(aws apprunner describe-service --service-arn "$SERVICE_ARN" --query 'Service.ServiceUrl' --output text 2>/dev/null || true)"
  echo "Status: ${STATUS} | URL: ${URL:-pendente}"
  if [ "$STATUS" = "RUNNING" ] && [ -n "$URL" ] && [ "$URL" != "None" ]; then
    echo
    echo "Aplicação disponível em: https://${URL}/health"
    exit 0
  fi
  sleep 10
done

echo "Deploy iniciado. Verifique o status no console AWS App Runner."
