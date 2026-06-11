# ---------- Build Stage ----------
FROM golang:1.25-bookworm as build-env

WORKDIR /usr/src/app

ENV GOPROXY=https://goproxy.io,direct

COPY go.mod go.sum ./

RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o main main.go

# ------------------Runtime Stage ----------------
FROM gcr.io/distroless/static-debian12:nonroot
LABEL org.opencontainers.image.source=https://github.com/Iam-Karan-Suresh/retail-cloud-native-platform

WORKDIR /app
# The distroless:nonroot image already runs as user 'nonroot' (uid 65532)

COPY --chown=nonroot:nonroot --from=build-env /usr/src/app/main ./
COPY --chown=nonroot:nonroot ./ATTRIBUTION.md ./

ENV GIN_MODE=release

ENTRYPOINT ["/app/main"]