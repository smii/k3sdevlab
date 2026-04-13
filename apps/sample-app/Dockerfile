# Stage 1: build
FROM golang:1.22-alpine AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /sample-app .

# Stage 2: runtime
FROM alpine:3.19

RUN addgroup -S app && adduser -S -G app app

COPY --from=builder /sample-app /usr/local/bin/sample-app

USER app

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/sample-app"]
