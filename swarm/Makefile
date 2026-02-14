.PHONY: build test vet lint docker-build clean

build:
	CGO_ENABLED=0 go build -ldflags="-s -w" -o swarm-kube-events ./cmd/swarm-kube-events

test:
	go test -race ./...

vet:
	go vet ./...

lint:
	golangci-lint run ./...

docker-build:
	docker buildx build --platform linux/amd64 -t swarm-kube-events:local .

clean:
	rm -f swarm-kube-events
