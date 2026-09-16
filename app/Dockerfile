FROM golang:1.26-trixie AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app/producer ./main.go

FROM gcr.io/distroless/static-debian13
COPY --from=builder /app/producer /app/producer
ENTRYPOINT ["/app/producer"]
