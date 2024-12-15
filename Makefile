.PHONY: build clean lint lint-fix docker push

# Get golangci-lint binary path
GOPATH=$(shell go env GOPATH)
GOBIN=$(shell go env GOBIN)
ifeq ($(GOBIN),)
	LINT_BINARY_PATH=$(GOPATH)/bin/golangci-lint
else
	LINT_BINARY_PATH=$(GOBIN)/bin/golangci-lint
endif

# Get all function binaries for this code base
TARGETS=$(sort $(dir $(wildcard services/public/func/*/*.go)))
HANDLERS=$(addsuffix bootstrap,$(TARGETS))
ARTIFACT=bin/

# Docker variables
IMAGE_NAME=calendar-bot
ACCOUNT_ID=$(shell aws sts get-caller-identity --query Account --output text)
REGION=$(shell aws configure get region)
ECR_REPO_URI=$(ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com/barney/playground-images

build: setup test $(ARTIFACT) $(HANDLERS)

%/bootstrap: %/*.go
	env GOARCH=amd64 GOOS=linux go build -tags lambda.norpc -o $@ ./$*
	cp $@ $(ARTIFACT)

$(ARTIFACT):
	@mkdir -p $(dir $(ARTIFACT))

tidy: | node_modules/go.mod
	go mod tidy

test:
	go test -tags "testtools" -v ./... -coverprofile=coverage.out

coverage:
	go tool cover -html=coverage.out

# node_modules/go.mod used to ignore possible go modules in node_modules.
node_modules/go.mod:
	-@touch $@

vars:
	@echo TARGETS: $(TARGETS)
	@echo HANDLERS: $(HANDLERS)

setup:
	@echo "Checking golangci-lint for building..."
	@if [ ! -e "$(LINT_BINARY_PATH)" ]; then \
		echo "golangci-lint is not installed. Installing..."; \
		go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest; \
	else \
			echo "golangci-lint is already installed."; \
	fi

lint: setup
	@echo "Running golangci-lint..."
	$(LINT_BINARY_PATH) run -v ./... --config ./.golangci.yml

lint-fix: setup ## Run golangci-lint and prettier formatting fixers and go mod tidy
	@echo "Running golangci-lint auto-fix..."
	$(LINT_BINARY_PATH) run -v ./... --fix --config ./.golangci.yml
	go mod tidy

clean:
	$(RM) $(HANDLERS)
	$(RM) -r $(ARTIFACT)

docker: build
	@echo "Building Docker image..."
	docker buildx build \
        --platform linux/arm64 \
        -t $(IMAGE_NAME):latest \
        --provenance=false \
        .

push: docker
	@echo "Pushing Docker image to ECR..."
	aws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $(ECR_REPO_URI)
	docker tag $(IMAGE_NAME) $(ECR_REPO_URI):latest
	docker push $(ECR_REPO_URI):latest