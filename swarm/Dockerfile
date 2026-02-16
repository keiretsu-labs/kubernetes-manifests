FROM --platform=$BUILDPLATFORM golang:1.26-bookworm AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o /out/swarm ./cmd/swarm

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/swarm /usr/local/bin/swarm

USER nonroot:nonroot
