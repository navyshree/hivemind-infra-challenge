# syntax=docker/dockerfile:1

# ---- build ------------------------------------------------------------------
FROM golang:1.27-alpine AS build

WORKDIR /src

# Dependencies resolve in their own layer so application edits do not invalidate
# the module cache. The greeter currently has no third-party dependencies, but
# keeping the split means that stays true as it grows.
COPY go.mod ./
RUN go mod download

COPY . .

RUN go vet ./... && go test ./...

# CGO_ENABLED=0 produces a static binary, which is what allows the final stage
# to be scratch. -trimpath keeps build-host paths out of the binary, and
# -w -s drop DWARF and the symbol table.
ARG TARGETOS=linux
ARG TARGETARCH=amd64
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-w -s" -o /out/greeter .

# ---- runtime ----------------------------------------------------------------
FROM scratch

# The binary is static and the service makes no outbound TLS calls, so no CA
# bundle is needed. Add ca-certificates here the moment that changes.
COPY --from=build /out/greeter /greeter

# Numeric UID: there is no /etc/passwd in scratch for a name to resolve against,
# and Kubernetes runAsNonRoot can only verify a numeric user.
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/greeter"]
