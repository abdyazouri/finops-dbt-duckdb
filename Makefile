.PHONY: setup data build eval extend docs clean

setup:            ## install dependencies into the current environment
	pip install -r requirements.txt

data:             ## generate 90 days of SYNTHETIC billing data
	python scripts/generate_billing_data.py --days 90

build:            ## seeds + models + tests
	dbt build --profiles-dir .

eval:             ## precision/recall of the anomaly detector vs injected ground truth
	python scripts/evaluate_anomalies.py

extend:           ## simulate 7 new billing days arriving, then run the incremental load
	python scripts/generate_billing_data.py --days 97
	dbt build --profiles-dir .

docs:             ## generate and serve dbt docs (lineage graph)
	dbt docs generate --profiles-dir . && dbt docs serve --profiles-dir .

clean:
	rm -rf target logs finops.duckdb data/raw/*.csv
