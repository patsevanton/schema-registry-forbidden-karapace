FROM golang:1.26-trixie AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app/producer ./main.go

# Внутренний корневой сертификат Yandex Cloud (YandexInternalRootCA).
# Managed Schema Registry (Karapace REST) отдаётся по HTTPS на порту 443 с
# сертификатом, выпущенным этим УЦ. В distroless нет своего CA-бандла, поэтому
# без него Go падает с "x509: certificate signed by unknown authority".
# Добавляем сертификат к системному набору (публичные сертификаты сохраняются).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://storage.yandexcloud.net/cloud-certs/CA.pem \
      -o /usr/local/share/ca-certificates/YandexInternalRootCA.crt \
 && update-ca-certificates

FROM gcr.io/distroless/static-debian13
COPY --from=builder /app/producer /app/producer
# Go ищет системные сертификаты в /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENTRYPOINT ["/app/producer"]
