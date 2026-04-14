# ---------- Build Stage ----------
FROM maven:3.9.9-eclipse-temurin-21 AS build-env

VOLUME /tmp
WORKDIR /build

COPY .mvn .mvn
COPY mvnw .
COPY pom.xml .

# Download dependencies (cache them)
RUN ./mvnw dependency:go-offline -B -q

COPY ./src ./src

# Compile the project
RUN ./mvnw -DskipTests package -q && \
    mv /target/ui-0.0.1-SNAPSHOT.jar app.jar

# ------------------Runtime Stage ----------------
FROM eclipse-temurin:21-jre-jammy

ENV APPUSER=appuser
ENV APPUID=1000
ENV APPGID=1000

# Add user
RUN useradd \
    --home "/app" \
    --create-home \
    --user-group \
    --uid "$APPUID" \
    "$APPUSER"

ENV JAVA_TOOL_OPTIONS=
ENV SPRING_PROFILES_ACTIVE=prod

WORKDIR /app
USER appuser

COPY ./ATTRIBUTION.md ./
COPY --chown=appuser:appuser --from=build-env /build/app.jar .

EXPOSE 8080

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar /app/app.jar"]