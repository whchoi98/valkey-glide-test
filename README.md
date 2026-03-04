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

### 3-5. Read/Write 동작 흐름 (AZ_AFFINITY)

Java Glide 클라이언트는 실제로 Valkey 클러스터에 Read와 Write를 모두 수행합니다.

```java
// Write (SET) → Primary 노드로 전송 (AZ 무관, Primary는 쓰기 전용)
client.set("ping:" + podName, "count-" + count).get();

// Read (GET) → AZ_AFFINITY에 의해 같은 AZ의 Replica 우선 읽기
String val = client.get("ping:" + podName).get();
```

#### AZ-A Pod (glide-test-az-a) 기준 동작 예시
```
┌─────────────────────────────────────────────────────────────┐
│                                                              │
│  AZ-A (ap-northeast-2a)          AZ-B (ap-northeast-2b)     │
│                                                              │
│  ┌──────────────────┐            ┌──────────────────┐       │
│  │ glide-test-az-a  │            │ Shard0001 Primary │       │
│  │ (Glide Client)   │──SET──────▶│ Shard0002 Primary │       │
│  │                   │  (Write)   └──────────────────┘       │
│  │                   │                                        │
│  │                   │            ┌──────────────────┐       │
│  │                   │◀──GET─────│ Shard0001 Replica │       │
│  │                   │  (Read)    │ Shard0002 Replica │       │
│  └──────────────────┘  same-AZ   └──────────────────┘       │
│                        우선 읽기    (AZ-A에 위치)              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

| 동작 | 대상 노드 | 네트워크 경로 | 설명 |
|------|-----------|--------------|------|
| `client.set()` (Write) | Primary 노드 | Cross-AZ (AZ-A → AZ-B) | 쓰기는 항상 해당 키 슬롯의 Primary로 전송 |
| `client.get()` (Read) | Replica 노드 | Same-AZ (AZ-A → AZ-A) | AZ_AFFINITY에 의해 같은 AZ의 Replica 우선 선택 |

#### AZ_AFFINITY의 핵심 동작
- **정상 시**: Read 트래픽을 같은 AZ의 Replica로 라우팅하여 cross-AZ 네트워크 비용 절감 및 지연시간 최소화
- **AZ 장애 시**: Glide 클라이언트가 클러스터 토폴로지 변경을 자동 감지하고, 다른 AZ의 노드로 failover하여 Read/Write를 계속 처리
- **Failover 감지**: 200ms 간격 연속 SET/GET 루프에서 에러 발생 구간의 타임스탬프로 failover 소요 시간을 정밀 측정

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

### 로그 모니터링 상세 설명

`kubectl logs -f` 명령으로 확인되는 로그는 GlideTest.java가 실제로 Valkey 클러스터에 Read/Write를 수행한 결과입니다.

#### 정상 동작 시 로그
```
[2026-03-04T16:55:07.635Z] [70] SET/GET ping:glide-test-az-a = count-70
```
- `client.set()` → Primary 노드에 Write 성공
- `client.get()` → 같은 AZ의 Replica에서 Read 성공
- 200ms 간격으로 연속 출력

#### AZ 장애 발생 시 로그
```
[2026-03-04T16:55:07.635Z] [70] SET/GET ping:glide-test-az-a = count-70   ← 마지막 정상
[2026-03-04T16:55:08.242Z] [71] ERROR: TimeoutException: timed out         ← 장애 감지
[2026-03-04T16:55:08.450Z] [72] ERROR: TimeoutException: timed out         ← failover 진행 중
...
[2026-03-04T16:55:15.123Z] [105] SET/GET ping:glide-test-az-a = count-105  ← 복구 완료
```
- ERROR 구간: Glide가 클러스터 토폴로지 변경을 감지하고 다른 AZ의 노드로 failover하는 중
- 복구 후: 새로운 Primary/Replica 구성으로 Read/Write 재개

#### 로그 수동 분석 명령
```bash
# ERROR만 필터링
kubectl logs glide-test-az-a -n valkey-test | grep ERROR

# 에러 건수 확인
kubectl logs glide-test-az-a -n valkey-test | grep -c ERROR

# 에러 전후 구간 확인 (첫 에러 시점 기준 앞뒤 5줄)
kubectl logs glide-test-az-a -n valkey-test | grep -B5 -A5 "ERROR" | head -30
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

### FIS AZ-A 장애 실험 결과

| 항목 | 값 |
|------|-----|
| 실험 ID | EXPScrQjcMEF3RT2Jv |
| 실험 상태 | completed ✅ |
| 실험 시간 | 17:21:01 ~ 17:26:14 (약 5분) |

#### Failover 영향

| 측정 항목 | AZ-A Pod | AZ-B Pod |
|-----------|----------|----------|
| 에러 횟수 | 84건 | 85건 |
| 첫 에러 | 17:21:27.889 | 17:21:27.298 |
| 마지막 에러 | 17:22:05.439 | 17:22:05.268 |
| 에러 유형 | TimeoutException | TimeoutException |
| Failover 소요 | 약 37초 | 약 38초 |

#### 분석
- 양쪽 Pod 모두 거의 동시에 에러 발생/복구 (AZ-A에 Primary가 없어도 양쪽 영향)
- 에러 구간은 약 37~38초 (에러 건수 × 200ms보다 실제 구간이 더 김 - 일부 요청은 timeout 대기 포함)
- 에러 유형은 모두 TimeoutException (AZ 장애로 인한 연결 타임아웃)

#### 테스트 시나리오
AZ-A 장애 발생 (FIS가 ap-northeast-2a의 전원을 차단)

장애 전 토폴로지:
- AZ-A: Shard0001 Replica, Shard0002 Replica
- AZ-B: Shard0001 Primary, Shard0002 Primary

→ AZ-A의 Replica 노드 2개가 다운됨

#### 왜 양쪽 Pod 모두 에러가 발생했나?

AZ-A에는 Replica만 있었는데도 AZ-B Pod까지 에러가 난 이유:

1. AZ_AFFINITY 모드에서 AZ-A Pod는 AZ-A의 Replica를 우선 읽기 → 해당 Replica가 죽으면서 직접적 영향
2. AZ-B Pod도 에러가 난 이유는 클러스터 토폴로지 재구성 때문입니다. AZ-A 노드가 다운되면 Valkey 클러스터 전체가 슬롯 재배치와 failover 프로세스를 진행하는데, 이 과정에서 일시적으로 양쪽 모두 연결이 불안정해집니다.

#### 약 37~38초의 의미

- 첫 에러 ~ 마지막 에러: 약 37초
- 이것은 Valkey 클러스터가 AZ 장애를 감지하고 → failover를 완료하고 → 클라이언트가 새 토폴로지를 인식하기까지 걸린 총 시간
- 구성: 장애 감지(~10초) + failover 실행(~10초) + 클라이언트 재연결 & 토폴로지 갱신(~17초)

#### 핵심 인사이트

| 관찰 | 의미 |
|------|------|
| 양쪽 Pod 에러 시작 시간이 거의 동일 (~0.6초 차이) | 클러스터 레벨 이벤트이므로 클라이언트 위치와 무관하게 동시 영향 |
| 에러 유형이 모두 TimeoutException | 노드가 갑자기 사라져서 응답 없음 (connection refused가 아닌 timeout) |
| 약 37초 후 자동 복구 | Glide 클라이언트가 별도 조치 없이 자동으로 새 토폴로지에 재연결 |
| AZ_AFFINITY가 failover 시간에 큰 영향 없음 | AZ Affinity는 정상 상태에서의 읽기 최적화이지, failover 속도를 개선하는 기능은 아님 |

즉, AZ 장애 시 약 37초간 서비스 중단이 발생하지만, 클라이언트가 자동으로 복구된다는 것이 핵심 결과입니다. 프로덕션에서는 이 37초를 애플리케이션 레벨에서 재시도 로직으로 커버해야 합니다.

#### AWS 공식 기준

AWS 문서에서 ElastiCache Multi-AZ failover는 다음 단계를 거칩니다:

1. 장애 감지 (~10-15초) - 클러스터 내부 heartbeat로 노드 다운 감지
2. Replica → Primary 승격 (~수초) - replication lag이 가장 적은 replica 승격
3. DNS 전파 (~수초) - 새 primary endpoint 반영
4. 클라이언트 재연결 (~수초) - 토폴로지 갱신 및 연결 재수립

AWS 블로그에서도 "the entire failover process typically completing within seconds for Multi-AZ configurations"라고 하지만, 이건 단일 노드 failover 기준입니다.

#### 이번 테스트가 다른 점

이번에 사용한 FIS 액션은 `replicationgroup-interrupt-az-power`로, 단일 노드가 아닌 AZ 전체 전원 차단입니다.

| 시나리오 | 예상 시간 |
|----------|-----------|
| 단일 노드 failover (test_failover API) | 10~20초 |
| AZ 레벨 장애 (FIS interrupt-az-power) | 30~40초 |

AZ 레벨 장애가 더 오래 걸리는 이유:
- 2개 Shard의 노드가 동시에 다운 → 클러스터가 여러 슬롯 그룹을 동시에 재구성
- 클러스터 버스(gossip protocol)로 모든 노드가 장애를 합의하는 데 추가 시간 소요
- Glide 클라이언트가 여러 연결을 동시에 재수립

#### 결론

35~37초는 AZ 레벨 장애 시나리오에서 정상적이고 예상 가능한 범위입니다. 프로덕션에서 이 시간을 줄이려면:
- Shard 수를 3개 이상으로 늘리면 (AWS 권장) failover가 더 빨라질 수 있음
- 애플리케이션에서 재시도 + circuit breaker 패턴으로 이 구간을 처리하는 것이 권장됨

---

## 8. 주의사항

- AZ-A 실험 후 AZ-B 실험까지 **최소 10분 대기** 필요 (클러스터 내부 복구 대기)
- FIS 실험 전 Valkey 클러스터 상태가 반드시 `available`인지 확인
- 200ms 폴링이므로 로그 양이 많음 (5분 = ~1,500 라인)
- `5-run-fis-test.sh`가 자동으로 결과를 수집하고 failover 시간을 계산함
