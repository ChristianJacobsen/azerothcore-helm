CHART := charts/azerothcore

.PHONY: lint template validate images catalogue

## helm lint the chart
lint:
	helm lint $(CHART)

## render the chart to stdout
template:
	helm template ac $(CHART)

## render and validate against a live cluster (needs KUBECONFIG)
validate: template
	@helm template ac $(CHART) | kubectl apply --dry-run=server -f - >/dev/null \
		&& echo "server-side validation OK"

## build server images from build/mods.yaml (REGISTRY, TAG, PUSH, PLATFORMS env)
images:
	build/build-images.sh

## list the most-starred modules from the AzerothCore catalogue
catalogue:
	@curl -s "https://api.github.com/search/repositories?q=topic:azerothcore-module&sort=stars&order=desc&per_page=25" \
		| python3 -c "import json,sys; [print(f\"{r['stargazers_count']:>5}  {r['html_url']}\") for r in json.load(sys.stdin)['items']]"
