package com.test;

import glide.api.GlideClusterClient;
import glide.api.models.configuration.GlideClusterClientConfiguration;
import glide.api.models.configuration.NodeAddress;
import glide.api.models.configuration.ReadFrom;
import java.net.InetAddress;

public class GlideTest {
    public static void main(String[] args) throws Exception {
        String configEndpoint = System.getenv("VALKEY_ENDPOINT");
        int port = Integer.parseInt(System.getenv().getOrDefault("VALKEY_PORT", "6379"));
        String podName = System.getenv().getOrDefault("POD_NAME", "unknown");
        String nodeName = System.getenv().getOrDefault("NODE_NAME", "unknown");
        String podIp = InetAddress.getLocalHost().getHostAddress();

        System.out.println("=== Valkey Glide AZ Affinity Test ===");
        System.out.println("Pod: " + podName);
        System.out.println("Node: " + nodeName);
        System.out.println("Pod IP: " + podIp);
        System.out.println("Valkey Endpoint: " + configEndpoint + ":" + port);
        System.out.println();

        // AZ_AFFINITY 모드: 같은 AZ의 replica를 우선 읽기
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

            // Write test
            String testKey = "test:" + podName;
            client.set(testKey, "hello-from-" + podName).get();
            System.out.println("SET " + testKey + " = hello-from-" + podName);

            // Read test (should prefer same-AZ replica)
            for (int i = 1; i <= 10; i++) {
                String value = client.get(testKey).get();
                System.out.println("GET [" + i + "] " + testKey + " = " + value);
                Thread.sleep(1000);
            }

            // Cluster info
            System.out.println();
            System.out.println("=== Cluster Info ===");
            System.out.println("Cluster connected - skipping info for cluster mode");

            // Keep running for observation
            System.out.println();
            System.out.println("=== Continuous test (every 5s) ===");
            int count = 0;
            while (true) {
                try {
                    count++;
                    client.set("ping:" + podName, "count-" + count).get();
                    String val = client.get("ping:" + podName).get();
                    System.out.println("[" + java.time.Instant.now() + "] [" + count + "] SET/GET ping:" + podName + " = " + val);
                } catch (Exception inner) {
                    System.out.println("[" + java.time.Instant.now() + "] [" + count + "] ERROR: " + inner.getMessage());
                }
                Thread.sleep(200);
            }
        } catch (Exception e) {
            System.err.println("Error: " + e.getMessage());
            e.printStackTrace();
            Thread.sleep(Long.MAX_VALUE); // keep pod alive for debugging
        }
    }
}
