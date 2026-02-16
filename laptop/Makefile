.PHONY: docker-build docker-push clean

REGISTRY ?= oci.killinit.cc
IMAGE ?= $(REGISTRY)/laptop/laptop
TAG ?= latest

docker-build:
	docker buildx build --platform linux/amd64 -t $(IMAGE):$(TAG) --load .

docker-push: docker-build
	docker push $(IMAGE):$(TAG)

clean:
	docker rmi $(IMAGE):$(TAG) 2>/dev/null || true
