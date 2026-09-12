# Тонкая обёртка над scripts/*.sh — чтобы работали привычные make-команды.
# Windows без make: используйте scripts\build.ps1 и scripts\run_analysis.ps1.

USERS ?= 12000
export USERS

.PHONY: all build data analysis test report dashboard clean help

all: build analysis

help:
	@echo "make build     — собрать всё с нуля (данные, схема, витрины, проверки)"
	@echo "make data      — только сгенерировать CSV"
	@echo "make analysis  — прогнать аналитические запросы"
	@echo "make report    — записать вывод в report/analysis_output.txt"
	@echo "make dashboard — пересобрать report/dashboard.html из базы"
	@echo "make test      — только проверки качества данных"
	@echo "make clean     — удалить сгенерированные CSV"
	@echo ""
	@echo "Размер набора: make build USERS=4000"

build:
	./scripts/build.sh

data:
	python etl/generate_data.py --users $(USERS)

analysis:
	./scripts/run_analysis.sh

report:
	./scripts/run_analysis.sh report/analysis_output.txt

dashboard:
	python scripts/build_dashboard.py

test:
	psql -d $${PGDATABASE:-timeline_analytics} --quiet -v ON_ERROR_STOP=1 -f tests/data_quality.sql

clean:
	rm -f data/*.csv
