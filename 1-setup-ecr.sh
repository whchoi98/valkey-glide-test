#!/bin/bash
set -e
REGION=ap-northeast-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME=valkey-glide-test

echo "=== ECR 리포지토리 생성 ==="
aws ecr describe-repositories --repository-names $REPO_NAME --region $REGION 2>/dev/null && \
  echo "✅ 리포지토리가 이미 존재합니다" || \
  (aws ecr create-repository --repository-name $REPO_NAME --region $REGION --query 'repository.repositoryUri' --output text && echo "✅ 리포지토리 생성 완료")
