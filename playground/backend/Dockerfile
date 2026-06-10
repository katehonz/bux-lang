FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY main.go .
RUN go mod init bux-playground 2>/dev/null || true
RUN go build -o playground-server main.go

FROM alpine:latest

RUN apk add --no-cache ca-certificates docker-cli

WORKDIR /app
COPY --from=builder /app/playground-server .
COPY frontend ./frontend

EXPOSE 8080

CMD ["./playground-server"]
