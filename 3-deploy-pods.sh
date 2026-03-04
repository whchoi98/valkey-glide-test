#!/bin/bash
set -e
REGION=ap-northeast-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Valkey Glide 테스트 Pod 배포 ==="

# Valkey 엔드포인트 자동 조회
VALKEY_ENDPOINT=$(aws elasticache describe-replication-groups --region $REGION \
  --query 'ReplicationGroups[0].ConfigurationEndpoint.Address' --output text 2>/dev/null)

if [ -z "$VALKEY_ENDPOINT" ] || [ "$VALKEY_ENDPOINT" = "None" ]; then
  echo "❌ Valkey Cluster Mode 엔드포인트를 찾을 수 없습니다"
  exit 1
fi
echo "Valkey Endpoint: $VALKEY_ENDPOINT"

# k8s-deploy.yaml의 엔드포인트를 동적으로 치환하여 적용
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/valkey-glide-test:latest"

cat > /tmp/valkey-test-deploy.yaml << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: valkey-test
---
apiVersion: v1
kind: Pod
metadata:
  name: glide-test-az-a
  namespace: valkey-test
  labels:
    app: glide-test
    az: ap-northeast-2a
spec:
  nodeSelector:
    topology.kubernetes.io/zone: ap-northeast-2a
  containers:
    - name: glide-test
      image: ${ECR_URI}
      env:
        - name: VALKEY_ENDPOINT
          value: "${VALKEY_ENDPOINT}"
        - name: VALKEY_PORT
          value: "6379"
        - name: AZ
          value: "ap-northeast-2a"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
  restartPolicy: Never
---
apiVersion: v1
kind: Pod
metadata:
  name: glide-test-az-b
  namespace: valkey-test
  labels:
    app: glide-test
    az: ap-northeast-2b
spec:
  nodeSelector:
    topology.kubernetes.io/zone: ap-northeast-2b
  containers:
    - name: glide-test
      image: ${ECR_URI}
      env:
        - name: VALKEY_ENDPOINT
          value: "${VALKEY_ENDPOINT}"
        - name: VALKEY_PORT
          value: "6379"
        - name: AZ
          value: "ap-northeast-2b"
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
  restartPolicy: Never
EOF

# 기존 Pod 삭제 후 재배포
kubectl delete namespace valkey-test --ignore-not-found 2>/dev/null || true
sleep 3
kubectl apply -f /tmp/valkey-test-deploy.yaml

echo ""
echo "⏳ Pod 시작 대기 중..."
sleep 20

echo ""
echo "=== Pod 상태 ==="
kubectl get pods -n valkey-test -o wide

echo ""
echo "=== AZ-A Pod 로그 (최근 3줄) ==="
kubectl logs glide-test-az-a -n valkey-test --tail=3 2>&1 || echo "(아직 시작 중)"

echo ""
echo "=== AZ-B Pod 로그 (최근 3줄) ==="
kubectl logs glide-test-az-b -n valkey-test --tail=3 2>&1 || echo "(아직 시작 중)"

echo ""
echo "✅ Pod 배포 완료"
echo ""
echo "💡 실시간 로그 확인:"
echo "   kubectl logs -f glide-test-az-a -n valkey-test"
echo "   kubectl logs -f glide-test-az-b -n valkey-test"
