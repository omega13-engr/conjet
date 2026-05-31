UBUNTU_VERSION ?= 24.04
UBUNTU_CODENAME ?= noble
RUNTIME ?= docker
DOCKER_PACKAGE ?= docker.io
ROOT_DISK_GB ?= 16
CONJET_CORE_VERSION ?= $(shell cat VERSION 2>/dev/null || echo 0.1.0)

OS_ARCH ?= $(shell uname -m)
ifeq ($(strip $(OS_ARCH)),arm64)
OS_ARCH = aarch64
endif

ARCH_x86_64 = amd64
ARCH_aarch64 = arm64
ARCH = $(shell echo "$(ARCH_$(OS_ARCH))")

.PHONY: all clean cloud-image image

all: image

clean:
	rm -rf dist

cloud-image:
	ARCH=$(ARCH) UBUNTU_VERSION=$(UBUNTU_VERSION) UBUNTU_CODENAME=$(UBUNTU_CODENAME) scripts/cloud-image.sh

image: cloud-image
	ARCH=$(ARCH) OS_ARCH=$(OS_ARCH) UBUNTU_VERSION=$(UBUNTU_VERSION) ROOT_DISK_GB=$(ROOT_DISK_GB) RUNTIME=$(RUNTIME) DOCKER_PACKAGE=$(DOCKER_PACKAGE) CONJET_CORE_VERSION=$(CONJET_CORE_VERSION) scripts/image.docker.sh
