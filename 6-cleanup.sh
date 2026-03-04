#!/bin/bash
REGION=ap-northeast-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Valkey Glide 테스트 환경 정리 ==="

# 1. K8s 리소스 삭제
echo "🗑️  [1/4] K8s 리소스 삭제..."
kubectl delete namespace valkey-test --ignore-not-found 2>/dev/null || true
echo "✅ 완료"

# 2. FIS 실험 템플릿 삭제
echo "🗑️  [2/4] FIS 실험 템플릿 삭제..."
for AZ in a b; do
  FILE="/tmp/fis-template-az-${AZ}.id"
  if [ -f "$FILE" ]; then
    TID=$(cat $FILE)
    aws fis delete-experiment-template --id $TID --region $REGION 2>/dev/null && \
      echo "  삭제: $TID" || echo "  스킵: $TID"
    rm -f $FILE
  fi
done
echo "✅ 완료"

# 3. FIS IAM Role 삭제
echo "🗑️  [3/4] FIS IAM Role 삭제..."
aws iam delete-role-policy --role-name FIS-ElastiCache-Role --policy-name FIS-ElastiCache-Policy 2>/dev/null || true
aws iam delete-role --role-name FIS-ElastiCache-Role 2>/dev/null || true
echo "✅ 완료"

# 4. ECR 리포지토리 삭제
echo "🗑️  [4/4] ECR 리포지토리 삭제..."
aws ecr delete-repository --repository-name valkey-glide-test --force --region $REGION 2>/dev/null || true
echo "✅ 완료"

# buildx 빌더 정리
docker buildx rm multiarch 2>/dev/null || true

echo ""
echo "✅ 전체 정리 완료"
