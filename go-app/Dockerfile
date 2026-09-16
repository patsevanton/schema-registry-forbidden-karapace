FROM golang:1.24 AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/producer .

FROM scratch
COPY --from=build /out/producer /producer
ENTRYPOINT ["/producer"]
