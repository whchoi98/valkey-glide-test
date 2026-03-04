# Valkey Glide AZ Affinity Failover 테스트 가이드

## 1. 개요

이 가이드는 AWS FIS(Fault Injection Service)를 사용하여 Valkey Cluster Mode의 AZ 장애 시 Glide Java Client의 AZ Affinity Failover 동작을 검증합니다.

### 테스트 아키텍처
```
┌──────────────────────────────────────────────────────────────┐
│                    DMZ VPC (10.11.0.0/16)                     │
│                                                               │
│  ┌───────────────────────┐    ┌───────────────────────┐      │
│  │  Private Subnet A      │    │  Private Subnet B      │      │
│  │  (ap-northeast-2a)     │    │  (ap-northeast-2b)     │      │
│  │                         │    │                         │      │
│  │  ┌───────────────────┐ │    │  ┌───────────────────┐ │      │
│  │  │ glide-test-az-a   │ │    │  │ glide-test-az-b   │ │      │
│  │  │ Glide 2.2.7       │ │    │  │ Glide 2.2.7       │ │      │
│  │  │ ReadFrom:         │ │    │  │ ReadFrom:         │ │      │
│  │  │  AZ_AFFINITY      │ │    │  │  AZ_AFFINITY      │ │      │
│  │  │ ClientAZ: az-a    │ │    │  │ ClientAZ: az-b    │ │      │
│  │  │ Interval: 200ms   │ │    │  │ Interval: 200ms   │ │      │
│  │  └────────┬──────────┘ │    │  └────────┬──────────┘ │      │
│  │           │             │    │           │             │      │
│  │  Valkey Nodes:          │    │  Valkey Nodes:          │      │
│  │   Shard0001 Replica     │    │   Shard0001 Primary     │      │
│  │   Shard0002 Replica     │    │   Shard0002 Primary     │      │
│  └───────────────────────┘    └───────────────────────┘      │
│                                                               │
│  Configuration Endpoint:                                      │
│  clustercfg.xxx.ykersa.apn2.cache.amazonaws.com:6379         │
└──────────────────────────────────────────────────────────────┘
```

### 구성 요소
| 항목 | 값 |
|------|-----|
| Valkey | 8.2 Cluster Mode Enabled (2 Shard x 2 Node) |
| Glide Client | valkey-glide 2.2.7 (Java, linux-aarch_64) |
| ReadFrom | AZ_AFFINITY |
| TLS | 활성화 |
| 폴링 간격 | 200ms (failover 정밀 측정용) |
| EKS 노드 | t4g.xlarge (ARM64, Graviton) |
| FIS Action | aws:elasticache:replicationgroup-interrupt-az-power |

---

## 2. 사전 요구사항

- EKS 클러스터 배포 완료 (eksworkshop)
- Valkey Cluster Mode 배포 완료 (valkey-cluster-stack)
- Docker + buildx 설치
- kubectl 설치 및 kubeconfig 설정

---

## 3. Docker 이미지 빌드 및 푸시

### 3-1. 프로젝트 구조
```
valkey-glide-test/
├── Dockerfile                          # Multi-stage build (x86 빌드 → arm64 런타임)
├── pom.xml                             # Maven 설정 (Glide 2.2.7, aarch_64)
├── src/main/java/com/test/GlideTest.java  # AZ Affinity 테스트 앱
├── k8s-deploy.yaml                     # K8s Pod 매니페스트 (az-a, az-b)
├── 1-setup-ecr.sh                      # ECR 리포지토리 생성
├── 2-build-and-push.sh                 # Docker 빌드 & ECR 푸시
├── 3-deploy-pods.sh                    # K8s Pod 배포
├── 4-setup-fis.sh                      # FIS 실험 템플릿 생성
├── 5-run-fis-test.sh                   # FIS 장애 실험 실행 & 결과 수집
└── 6-cleanup.sh                        # 전체 정리
```

### 3-2. Dockerfile 설명
```dockerfile
# Stage 1: x86 호스트에서 Maven 빌드 (arm64 native lib 포함)
FROM amazoncorretto:17-al2023 AS builder
RUN dnf install -y maven && dnf clean all
WORKDIR /app
COPY pom.xml .
COPY src/ src/
RUN mvn package -q -DskipTests -P linux-arm

# Stage 2: 런타임 (arm64 EKS 노드에서 실행)
FROM amazoncorretto:17-al2023
WORKDIR /app
COPY --from=builder /app/target/glide-test-1.0.jar target/glide-test-1.0.jar
COPY --from=builder /app/target/lib/ target/lib/
ENTRYPOINT ["java", "-jar", "target/glide-test-1.0.jar"]
```

- **빌드 호스트**: x86_64 (Cloud9/EC2)
- **런타임 타겟**: arm64 (EKS t4g 노드)
- **buildx**: QEMU 에뮬레이션으로 arm64 이미지 크로스 빌드

### 3-3. pom.xml 핵심 설정
```xml
<dependency>
    <groupId>io.valkey</groupId>
    <artifactId>valkey-glide</artifactId>
    <version>2.2.7</version>
    <classifier>${glide.classifier}</classifier>  <!-- 프로파일로 x86/arm 전환 -->
</dependency>

<profiles>
    <profile>
        <id>linux-x86</id>
        <activation><activeByDefault>true</activeByDefault></activation>
        <properties><glide.classifier>linux-x86_64</glide.classifier></properties>
    </profile>
    <profile>
        <id>linux-arm</id>
        <properties><glide.classifier>linux-aarch_64</glide.classifier></properties>
    </profile>
</profiles>
```

### 3-4. Java 테스트 앱 (GlideTest.java) 핵심 로직
```java
// AZ_AFFINITY: 같은 AZ의 replica를 우선 읽기
GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
    .address(NodeAddress.builder().host(configEndpoint).port(port).build())
    .useTLS(true)
    .readFrom(ReadFrom.AZ_AFFINITY)
    .clientAZ(System.getenv().getOrDefault("AZ", "ap-northeast-2a"))
    .build();

// 200ms 간격으로 SET/GET 반복 (failover 정밀 측정)
while (true) {
    try {
        client.set("ping:" + podName, "count-" + count).get();
        String val = client.get("ping:" + podName).get();
        System.out.println("[" + Instant.now() + "] [" + count + "] SET/GET ...");
    } catch (Exception inner) {
        System.out.println("[" + Instant.now() + "] [" + count + "] ERROR: " + inner.getMessage());
    }
    Thread.sleep(200);
}
```

---

## 4. K8s Pod 배포

### 4-1. Pod 매니페스트 (k8s-deploy.yaml) 핵심
```yaml
# AZ-A Pod: nodeSelector로 az-a 노드에 고정
spec:
  nodeSelector:
    topology.kubernetes.io/zone: ap-northeast-2a
  containers:
    - name: glide-test
      env:
        - name: AZ
          value: "ap-northeast-2a"        # Glide clientAZ 설정
        - name: VALKEY_ENDPOINT
          value: "clustercfg.xxx.apn2.cache.amazonaws.com"
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName     # 배치된 노드 이름 주입
```

### 4-2. 환경변수 설명
| 환경변수 | 설명 |
|----------|------|
| VALKEY_ENDPOINT | Valkey Configuration Endpoint |
| VALKEY_PORT | 포트 (기본 6379) |
| AZ | Glide clientAZ 설정 (Pod가 배치된 AZ와 동일) |
| POD_NAME | Pod 이름 (Downward API) |
| NODE_NAME | 배치된 노드 이름 (Downward API) |

---

## 5. FIS 실험 설정

### 5-1. IAM Role
```json
{
  "Effect": "Allow",
  "Action": [
    "elasticache:InterruptClusterAzPower",
    "elasticache:DescribeReplicationGroups",
    "elasticache:DescribeCacheClusters",
    "elasticache:ListTagsForResource"
  ],
  "Resource": "arn:aws:elasticache:ap-northeast-2:ACCOUNT_ID:replicationgroup:*"
}
```

### 5-2. 실험 템플릿 구조
```json
{
  "targets": {
    "valkey-cluster": {
      "resourceType": "aws:elasticache:replicationgroup",
      "resourceTags": {"FIS-Target": "true"},
      "selectionMode": "ALL",
      "parameters": {
        "availabilityZoneIdentifier": "apne2-az1"   // az-a = apne2-az1, az-b = apne2-az2
      }
    }
  },
  "actions": {
    "interrupt-az": {
      "actionId": "aws:elasticache:replicationgroup-interrupt-az-power",
      "parameters": {"duration": "PT5M"}
    }
  }
}
```

### 5-3. AZ ID 매핑
| AZ Name | AZ ID |
|---------|-------|
| ap-northeast-2a | apne2-az1 |
| ap-northeast-2b | apne2-az2 |

---

## 6. 테스트 실행 방법

### 자동화 스크립트 순서
```bash
cd ~/amazonqcli_lab/LabSetup/valkey-glide-test

# Step 1: ECR 리포지토리 생성
./1-setup-ecr.sh

# Step 2: Docker 이미지 빌드 & 푸시
./2-build-and-push.sh

# Step 3: K8s Pod 배포
./3-deploy-pods.sh

# Step 4: FIS 실험 템플릿 생성
./4-setup-fis.sh

# Step 5: FIS 장애 실험 실행 (AZ-A 또는 AZ-B 선택)
./5-run-fis-test.sh a    # AZ-A 장애 실험
./5-run-fis-test.sh b    # AZ-B 장애 실험

# Step 6: 정리
./6-cleanup.sh
```

### 수동 모니터링 (터미널 3개)
```bash
# 터미널 1: AZ-A Pod 실시간 로그
kubectl logs -f glide-test-az-a -n valkey-test

# 터미널 2: AZ-B Pod 실시간 로그
kubectl logs -f glide-test-az-b -n valkey-test

# 터미널 3: FIS 실험 시작
./5-run-fis-test.sh a
```

---

## 7. 결과 분석

### 로그 형식
```
# 정상
[2026-03-04T16:55:07.635Z] [70] SET/GET ping:glide-test-az-a = count-70

# 에러 (failover 중)
[2026-03-04T16:55:08.242Z] [73] ERROR: glide.api.models.exceptions.TimeoutException: timed out
```

### Failover 시간 계산
```
Failover 시간 = 첫 번째 ERROR 타임스탬프 - 마지막 정상 SET/GET 타임스탬프
복구 시간     = 에러 후 첫 정상 SET/GET 타임스탬프 - 첫 번째 ERROR 타임스탬프
```

### 결과 정리 템플릿
| 측정 항목 | AZ-A 장애 | AZ-B 장애 |
|-----------|-----------|-----------|
| 실험 시작 시간 | | |
| 첫 번째 에러 시간 | | |
| 마지막 에러 시간 | | |
| 에러 발생 횟수 | | |
| Failover 소요 시간 | | |
| AZ-A Pod 영향 | | |
| AZ-B Pod 영향 | | |
| 에러 유형 | | |

---

## 8. 주의사항

- AZ-A 실험 후 AZ-B 실험까지 **최소 10분 대기** 필요 (클러스터 내부 복구 대기)
- FIS 실험 전 Valkey 클러스터 상태가 반드시 `available`인지 확인
- 200ms 폴링이므로 로그 양이 많음 (5분 = ~1,500 라인)
- `5-run-fis-test.sh`가 자동으로 결과를 수집하고 failover 시간을 계산함
