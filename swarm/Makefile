.PHONY: build test vet lint docker-build docker-push clean

REGISTRY ?= oci.killinit.cc
IMAGE ?= $(REGISTRY)/swarm/swarm
TAG ?= latest

build:
	CGO_ENABLED=0 go build -ldflags="-s -w" -o swarm ./cmd/swarm

test:
	go test -race ./...

vet:
	go vet ./...

lint:
	golangci-lint run ./...

docker-build:
	docker buildx build --platform linux/amd64 -t $(IMAGE):$(TAG) --load .

docker-push: docker-build
	docker push $(IMAGE):$(TAG)

clean:
	rm -f swarm
