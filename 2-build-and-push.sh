#!/bin/bash
set -e
REGION=ap-northeast-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/valkey-glide-test:latest"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Docker 이미지 빌드 & ECR 푸시 ==="
echo "ECR URI: $ECR_URI"

# ECR 로그인
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

# QEMU 등록 (arm64 크로스 빌드용)
echo "🔧 QEMU 등록 중..."
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes 2>/dev/null || true

# buildx 빌더 생성
docker buildx rm multiarch 2>/dev/null || true
docker buildx create --name multiarch --driver docker-container --platform linux/arm64,linux/amd64 --use
docker buildx inspect multiarch --bootstrap >/dev/null 2>&1

# arm64 이미지 빌드 & 푸시
echo "🚀 arm64 이미지 빌드 중... (약 2-3분 소요)"
docker buildx build --platform linux/arm64 -t $ECR_URI --push $SCRIPT_DIR

echo "✅ 이미지 빌드 & 푸시 완료: $ECR_URI"
