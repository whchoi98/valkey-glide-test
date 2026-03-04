#!/bin/bash
set -e
REGION=ap-northeast-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== FIS 실험 환경 설정 ==="

# 1. Valkey 클러스터에 FIS 태그 추가
RG_ID=$(aws elasticache describe-replication-groups --region $REGION \
  --query 'ReplicationGroups[0].ReplicationGroupId' --output text)
echo "Replication Group: $RG_ID"

aws elasticache add-tags-to-resource \
  --resource-name "arn:aws:elasticache:${REGION}:${ACCOUNT_ID}:replicationgroup:${RG_ID}" \
  --tags Key=FIS-Target,Value=true \
  --region $REGION >/dev/null 2>&1
echo "✅ FIS-Target 태그 추가 완료"

# 2. FIS IAM Role 생성
ROLE_NAME="FIS-ElastiCache-Role"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

if aws iam get-role --role-name $ROLE_NAME 2>/dev/null; then
  echo "✅ IAM Role이 이미 존재합니다"
else
  cat > /tmp/fis-trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"fis.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
  aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document file:///tmp/fis-trust.json >/dev/null
  echo "✅ IAM Role 생성 완료"
fi

cat > /tmp/fis-policy.json << EOF
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["elasticache:InterruptClusterAzPower","elasticache:DescribeReplicationGroups","elasticache:DescribeCacheClusters","elasticache:ListTagsForResource"],"Resource":["arn:aws:elasticache:${REGION}:${ACCOUNT_ID}:replicationgroup:*","arn:aws:elasticache:${REGION}:${ACCOUNT_ID}:cluster:*"]},
  {"Effect":"Allow","Action":["ec2:DescribeAvailabilityZones","tag:GetResources"],"Resource":"*"}
]}
EOF
aws iam put-role-policy --role-name $ROLE_NAME --policy-name FIS-ElastiCache-Policy \
  --policy-document file:///tmp/fis-policy.json
echo "✅ IAM Policy 적용 완료"

# 3. FIS 실험 템플릿 생성
echo ""
echo "⏳ IAM Role 전파 대기 (15초)..."
sleep 15

for AZ_LABEL in a b; do
  if [ "$AZ_LABEL" = "a" ]; then AZ_ID="apne2-az1"; else AZ_ID="apne2-az2"; fi

  cat > /tmp/fis-az-${AZ_LABEL}.json << EOF
{
  "description":"Valkey AZ-${AZ_LABEL} failure test",
  "targets":{"valkey-cluster":{"resourceType":"aws:elasticache:replicationgroup","resourceTags":{"FIS-Target":"true"},"selectionMode":"ALL","parameters":{"availabilityZoneIdentifier":"${AZ_ID}"}}},
  "actions":{"interrupt-az-${AZ_LABEL}":{"actionId":"aws:elasticache:replicationgroup-interrupt-az-power","parameters":{"duration":"PT5M"},"targets":{"ReplicationGroups":"valkey-cluster"}}},
  "stopConditions":[{"source":"none"}],
  "roleArn":"${ROLE_ARN}",
  "tags":{"Name":"valkey-az-${AZ_LABEL}-failure"}
}
EOF

  TEMPLATE_ID=$(aws fis create-experiment-template \
    --cli-input-json file:///tmp/fis-az-${AZ_LABEL}.json \
    --region $REGION --query 'experimentTemplate.id' --output text 2>&1)

  if [[ "$TEMPLATE_ID" == EXT* ]]; then
    echo "✅ AZ-${AZ_LABEL} 실험 템플릿: $TEMPLATE_ID"
    # 템플릿 ID 저장
    echo "$TEMPLATE_ID" > /tmp/fis-template-az-${AZ_LABEL}.id
  else
    echo "⚠️  AZ-${AZ_LABEL} 템플릿 생성 실패: $TEMPLATE_ID"
  fi
done

echo ""
echo "✅ FIS 설정 완료"
echo ""
echo "💡 다음 단계: ./5-run-fis-test.sh a  (AZ-A 장애 실험)"
