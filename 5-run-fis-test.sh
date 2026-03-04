#!/bin/bash
set -e
REGION=ap-northeast-2

# 사용법 확인
if [ -z "$1" ] || [[ ! "$1" =~ ^[aAbB]$ ]]; then
  echo "사용법: $0 <a|b>"
  echo "  a: AZ-A (ap-northeast-2a) 장애 실험"
  echo "  b: AZ-B (ap-northeast-2b) 장애 실험"
  exit 1
fi

AZ_LABEL=$(echo "$1" | tr 'A-Z' 'a-z')
AZ_NAME="ap-northeast-2${AZ_LABEL}"

# 템플릿 ID 로드
TEMPLATE_FILE="/tmp/fis-template-az-${AZ_LABEL}.id"
if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "❌ FIS 템플릿 ID 파일이 없습니다. 먼저 ./4-setup-fis.sh 를 실행하세요"
  exit 1
fi
TEMPLATE_ID=$(cat $TEMPLATE_FILE)

echo "=============================================="
echo "  Valkey AZ-${AZ_LABEL} Failover 테스트"
echo "=============================================="
echo "대상 AZ: $AZ_NAME"
echo "FIS 템플릿: $TEMPLATE_ID"
echo ""

# 1. Valkey 클러스터 상태 확인
echo "🔍 [1/5] Valkey 클러스터 상태 확인..."
STATUS=$(aws elasticache describe-replication-groups --region $REGION \
  --query 'ReplicationGroups[0].Status' --output text)
if [ "$STATUS" != "available" ]; then
  echo "❌ 클러스터 상태: $STATUS (available이어야 합니다)"
  echo "   이전 실험 복구 대기 후 다시 시도하세요"
  exit 1
fi
echo "✅ 클러스터 상태: $STATUS"

# 2. Pod 상태 확인
echo ""
echo "🔍 [2/5] Pod 상태 확인..."
kubectl get pods -n valkey-test -o wide 2>&1
echo ""

# 3. FIS 실험 시작
echo "🚀 [3/5] FIS 실험 시작..."
START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')
echo "실험 시작 시간: $START_TIME"

EXP_ID=$(aws fis start-experiment \
  --experiment-template-id $TEMPLATE_ID \
  --region $REGION \
  --query 'experiment.id' --output text)
echo "실험 ID: $EXP_ID"

# 4. 실험 진행 모니터링
echo ""
echo "⏳ [4/5] 실험 진행 모니터링 (30초 간격)..."
while true; do
  sleep 30
  EXP_STATUS=$(aws fis get-experiment --id $EXP_ID --region $REGION \
    --query 'experiment.state.status' --output text)
  echo "  $(date -u '+%H:%M:%S') - 실험 상태: $EXP_STATUS"

  if [ "$EXP_STATUS" = "completed" ] || [ "$EXP_STATUS" = "failed" ] || [ "$EXP_STATUS" = "stopped" ]; then
    break
  fi
done

# 5. 결과 수집
echo ""
echo "📊 [5/5] 결과 수집..."
END_TIME=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')

echo ""
echo "=============================================="
echo "  실험 결과"
echo "=============================================="

# FIS 실험 결과
echo ""
echo "--- FIS 실험 ---"
aws fis get-experiment --id $EXP_ID --region $REGION \
  --query 'experiment.{Status:state.status,Reason:state.reason,Start:startTime,End:endTime}' 2>&1

# Pod 에러 로그 수집
echo ""
echo "--- AZ-A Pod 에러 ---"
AZA_ERRORS=$(kubectl logs glide-test-az-a -n valkey-test 2>&1 | grep "ERROR" || true)
AZA_ERROR_COUNT=$(echo "$AZA_ERRORS" | grep -c "ERROR" 2>/dev/null || echo "0")
if [ "$AZA_ERROR_COUNT" -gt 0 ]; then
  FIRST_ERROR=$(echo "$AZA_ERRORS" | head -1)
  LAST_ERROR=$(echo "$AZA_ERRORS" | tail -1)
  echo "에러 횟수: $AZA_ERROR_COUNT"
  echo "첫 에러: $FIRST_ERROR"
  echo "끝 에러: $LAST_ERROR"
else
  echo "에러 없음 (failover가 200ms 이내에 완료됨)"
fi

echo ""
echo "--- AZ-B Pod 에러 ---"
AZB_ERRORS=$(kubectl logs glide-test-az-b -n valkey-test 2>&1 | grep "ERROR" || true)
AZB_ERROR_COUNT=$(echo "$AZB_ERRORS" | grep -c "ERROR" 2>/dev/null || echo "0")
if [ "$AZB_ERROR_COUNT" -gt 0 ]; then
  FIRST_ERROR=$(echo "$AZB_ERRORS" | head -1)
  LAST_ERROR=$(echo "$AZB_ERRORS" | tail -1)
  echo "에러 횟수: $AZB_ERROR_COUNT"
  echo "첫 에러: $FIRST_ERROR"
  echo "끝 에러: $LAST_ERROR"
else
  echo "에러 없음 (failover가 200ms 이내에 완료됨)"
fi

# Failover 시간 계산
echo ""
echo "--- Failover 시간 분석 ---"
for POD in glide-test-az-a glide-test-az-b; do
  ERRORS=$(kubectl logs $POD -n valkey-test 2>&1 | grep "ERROR" || true)
  ERR_COUNT=$(echo "$ERRORS" | grep -c "ERROR" 2>/dev/null || echo "0")

  if [ "$ERR_COUNT" -gt 0 ]; then
    FIRST_ERR_TS=$(echo "$ERRORS" | head -1 | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z')
    LAST_ERR_TS=$(echo "$ERRORS" | tail -1 | grep -oP '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z')

    # 에러 전 마지막 정상 로그
    LAST_OK=$(kubectl logs $POD -n valkey-test 2>&1 | grep "SET/GET" | \
      awk -v err="$FIRST_ERR_TS" '$0 < err' | tail -1)
    # 에러 후 첫 정상 로그
    FIRST_RECOVER=$(kubectl logs $POD -n valkey-test 2>&1 | grep "SET/GET" | \
      awk -v err="$LAST_ERR_TS" '$0 > err' | head -1)

    echo "$POD:"
    echo "  에러 횟수: $ERR_COUNT"
    echo "  에러 구간: $FIRST_ERR_TS ~ $LAST_ERR_TS"
    echo "  마지막 정상: $LAST_OK"
    echo "  첫 복구:     $FIRST_RECOVER"
    echo "  예상 failover 시간: 약 $((ERR_COUNT / 5))초 (에러 $ERR_COUNT 건 x 200ms 간격)"
  else
    echo "$POD: 에러 없음"
  fi
done

echo ""
echo "=============================================="
echo "✅ 테스트 완료"
echo ""
echo "⚠️  다른 AZ 실험 전 최소 10분 대기 필요"
echo "   클러스터 상태 확인: aws elasticache describe-replication-groups --region $REGION --query 'ReplicationGroups[0].Status'"
