CHART := charts/azerothcore
RELEASE ?= azerothcore
NAMESPACE ?= azerothcore
VALUES := $(if $(wildcard build/images.generated.yaml),-f build/images.generated.yaml) $(if $(wildcard values.local.yaml),-f values.local.yaml)
CATALOGUE_SIZE := 25

.PHONY: lint template validate images install upgrade uninstall test catalogue

lint:
	helm lint $(CHART)

template:
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) $(VALUES) --dry-run=server

validate:
	@helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) $(VALUES) --dry-run=server >/dev/null \
		&& echo "server-side validation OK"

images:
	build/build-images.sh

install upgrade:
	helm upgrade --install $(RELEASE) $(CHART) -n $(NAMESPACE) --create-namespace $(VALUES)

uninstall:
	helm uninstall $(RELEASE) -n $(NAMESPACE)

test:
	helm test $(RELEASE) -n $(NAMESPACE) --logs

catalogue:
	@curl -s "https://api.github.com/search/repositories?q=topic:azerothcore-module&sort=stars&order=desc&per_page=$(CATALOGUE_SIZE)" \
		| python3 -c "import json,sys; [print(f\"{r['stargazers_count']:>5}  {r['html_url']}\") for r in json.load(sys.stdin)['items']]"
