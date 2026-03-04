FROM amazoncorretto:17-al2023 AS builder

RUN dnf install -y maven && dnf clean all

WORKDIR /app
COPY pom.xml .
COPY src/ src/
RUN mvn package -q -DskipTests -P linux-arm

FROM amazoncorretto:17-al2023

WORKDIR /app
COPY --from=builder /app/target/glide-test-1.0.jar target/glide-test-1.0.jar
COPY --from=builder /app/target/lib/ target/lib/

ENTRYPOINT ["java", "-jar", "target/glide-test-1.0.jar"]
