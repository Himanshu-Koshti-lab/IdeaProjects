# syntax=docker/dockerfile:1

# ---- Build: compile the Spring Boot fat jar ----
FROM eclipse-temurin:26-jdk AS build
WORKDIR /workspace

# Gradle wrapper + build scripts first, so the dependency layer is cached between source changes.
COPY gradlew settings.gradle build.gradle ./
COPY gradle gradle
RUN chmod +x gradlew
RUN --mount=type=cache,target=/root/.gradle ./gradlew dependencies --no-daemon -q > /dev/null

COPY src src
# Tests use Testcontainers (needs Docker) so they run in CI, not inside the image build.
RUN --mount=type=cache,target=/root/.gradle ./gradlew bootJar --no-daemon -x test \
    && cp build/libs/*-SNAPSHOT.jar app.jar

# ---- Runtime: JRE only, non-root ----
FROM eclipse-temurin:26-jre
WORKDIR /app

# Numeric UID so Kubernetes `runAsNonRoot` can verify it.
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home app
COPY --from=build /workspace/app.jar app.jar
USER 10001

EXPOSE 8080
# Respect the container's memory limit; override or extend via JAVA_OPTS.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75"
# Set SPRING_PROFILES_ACTIVE=json for one-JSON-object-per-line logs.
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
