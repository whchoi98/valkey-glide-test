package com.test;

import glide.api.GlideClusterClient;
import glide.api.models.configuration.GlideClusterClientConfiguration;
import glide.api.models.configuration.NodeAddress;
import glide.api.models.configuration.ReadFrom;
import java.net.InetAddress;

/**
 * Valkey Glide AZ Affinity Failover 테스트 애플리케이션.
 *
 * 목적: AWS FIS(Fault Injection Service)로 특정 AZ 장애를 주입했을 때,
 *       Glide 클라이언트의 AZ_AFFINITY 모드가 자동으로 failover하는 동작을 검증한다.
 *
 * 동작 방식:
 *   1) 환경변수로 Valkey 엔드포인트, AZ 정보를 주입받음 (K8s Pod 환경)
 *   2) AZ_AFFINITY 모드로 Glide 클러스터 클라이언트를 생성
 *   3) 초기 연결 검증 (SET/GET 10회)
 *   4) 200ms 간격 연속 SET/GET 루프로 failover 발생 시점과 복구 시점을 정밀 측정
 *
 * 환경변수:
 *   - VALKEY_ENDPOINT : Valkey Configuration Endpoint (필수)
 *   - VALKEY_PORT     : 포트 번호 (기본값: 6379)
 *   - AZ             : 클라이언트가 위치한 AZ (예: ap-northeast-2a)
 *   - POD_NAME       : K8s Pod 이름 (Downward API로 주입)
 *   - NODE_NAME      : K8s 노드 이름 (Downward API로 주입)
 */
public class GlideTest {
    public static void main(String[] args) throws Exception {

        // ============================================================
        // 1단계: 환경변수에서 설정값 로드
        // ============================================================
        String configEndpoint = System.getenv("VALKEY_ENDPOINT");
        int port = Integer.parseInt(System.getenv().getOrDefault("VALKEY_PORT", "6379"));
        String podName = System.getenv().getOrDefault("POD_NAME", "unknown");
        String nodeName = System.getenv().getOrDefault("NODE_NAME", "unknown");
        String podIp = InetAddress.getLocalHost().getHostAddress();

        // Pod 식별 정보 출력 (로그 분석 시 어느 Pod에서 발생한 로그인지 구분용)
        System.out.println("=== Valkey Glide AZ Affinity Test ===");
        System.out.println("Pod: " + podName);
        System.out.println("Node: " + nodeName);
        System.out.println("Pod IP: " + podIp);
        System.out.println("Valkey Endpoint: " + configEndpoint + ":" + port);
        System.out.println();

        // ============================================================
        // 2단계: Glide 클러스터 클라이언트 설정
        // ============================================================
        // - AZ_AFFINITY: 읽기 요청 시 같은 AZ에 있는 replica를 우선 선택하여
        //   cross-AZ 네트워크 비용을 줄이고 지연시간을 최소화함.
        //   장애 발생 시 Glide가 자동으로 다른 AZ의 노드로 failover 처리.
        // - clientAZ: Glide에게 이 클라이언트의 AZ 위치를 알려줌.
        //   K8s nodeSelector로 Pod가 특정 AZ에 고정되므로 환경변수 AZ와 일치해야 함.
        // - useTLS: ElastiCache/Valkey의 전송 중 암호화(TLS) 활성화 시 필수.
        GlideClusterClientConfiguration config = GlideClusterClientConfiguration.builder()
                .address(NodeAddress.builder().host(configEndpoint).port(port).build())
                .useTLS(true)
                .readFrom(ReadFrom.AZ_AFFINITY)
                .clientAZ(System.getenv().getOrDefault("AZ", "ap-northeast-2a"))
                .build();

        try (GlideClusterClient client = GlideClusterClient.createClient(config).get()) {
            System.out.println("Connected to Valkey cluster successfully!");
            System.out.println("ReadFrom: AZ_AFFINITY");
            System.out.println("Client AZ: " + System.getenv().getOrDefault("AZ", "ap-northeast-2a"));
            System.out.println();

            // ============================================================
            // 3단계: 초기 연결 검증 (SET 1회 + GET 10회)
            // ============================================================
            // FIS 실험 시작 전에 클러스터 연결이 정상인지 확인.
            // AZ_AFFINITY 모드에서 GET은 같은 AZ의 replica로 라우팅됨.
            String testKey = "test:" + podName;
            client.set(testKey, "hello-from-" + podName).get();
            System.out.println("SET " + testKey + " = hello-from-" + podName);

            for (int i = 1; i <= 10; i++) {
                String value = client.get(testKey).get();
                System.out.println("GET [" + i + "] " + testKey + " = " + value);
                Thread.sleep(1000);
            }

            System.out.println();
            System.out.println("=== Cluster Info ===");
            System.out.println("Cluster connected - skipping info for cluster mode");

            // ============================================================
            // 4단계: 연속 SET/GET 루프 (Failover 감지 및 측정)
            // ============================================================
            // - 200ms 간격으로 SET + GET을 반복 수행
            // - 정상 시: 타임스탬프와 함께 성공 로그 출력
            // - 장애 시: catch 블록에서 에러 로그 출력 (TimeoutException 등)
            //
            // Failover 시간 계산 방법:
            //   Failover 시작 = 마지막 정상 로그 → 첫 번째 ERROR 로그 사이
            //   복구 완료     = 마지막 ERROR 로그 → 첫 번째 정상 로그 사이
            //   200ms 폴링이므로 최대 ±200ms 오차 발생 가능
            System.out.println();
            System.out.println("=== Continuous test (every 5s) ===");
            int count = 0;
            while (true) {
                try {
                    count++;
                    // SET: Primary 노드로 전송 (AZ 무관, Primary는 쓰기 전용)
                    client.set("ping:" + podName, "count-" + count).get();
                    // GET: AZ_AFFINITY에 의해 같은 AZ의 replica 우선 읽기
                    String val = client.get("ping:" + podName).get();
                    System.out.println("[" + java.time.Instant.now() + "] [" + count + "] SET/GET ping:" + podName + " = " + val);
                } catch (Exception inner) {
                    // Failover 중 발생하는 에러 기록
                    // 주요 에러 유형: TimeoutException, ConnectionException, RequestException
                    System.out.println("[" + java.time.Instant.now() + "] [" + count + "] ERROR: " + inner.getMessage());
                }
                Thread.sleep(200);
            }
        } catch (Exception e) {
            // 클라이언트 생성 실패 또는 초기 연결 실패 시
            // Pod를 종료하지 않고 유지하여 kubectl exec로 디버깅 가능하게 함
            System.err.println("Error: " + e.getMessage());
            e.printStackTrace();
            Thread.sleep(Long.MAX_VALUE);
        }
    }
}
