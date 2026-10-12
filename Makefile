REPO ?= derekbit
TAG  ?= latest
IMAGE := $(REPO)/longhorn-perf-bench:$(TAG)

.PHONY: build
build:
	docker build -t $(IMAGE) .
