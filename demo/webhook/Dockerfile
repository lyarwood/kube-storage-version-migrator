FROM golang:1.22 AS builder
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 go build -o /webhook-server main.go

FROM gcr.io/distroless/static:latest
COPY --from=builder /webhook-server /webhook-server
ENTRYPOINT ["/webhook-server"]
