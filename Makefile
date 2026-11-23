
.PHONY: migrate api ui ui-mock test-safety chat-eval chat-eval-mock chat-eval-test chat-eval-set test-chat chat-kb up-ec2 down-ec2 embeddings-ec2 smoke-ec2 chat-kb-ec2 logs-ec2 ps-ec2
.PHONY: setup ground-truth policies synthetic ingest corpus eval-set grade retrieval-baseline prompt-baseline prompt-baseline-mock index chunking-experiments retrieval-eval test schemas up down

setup:            ## create venv and install dependencies
	python -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt

ground-truth:     ## step 1.3: rebuild 35 vendors + expected outcomes (fails on any inconsistency)
	python -m scripts.build_vendors

policies:         ## step 1.4a: render internal policy documents from rubric.yaml
	python -m scripts.generate_policies

synthetic:        ## step 1.4b: render synthetic vendor documents and validate their facts
	python -m scripts.generate_synthetic_docs

ingest:           ## step 1.4c: extract real sources per the source register + merge synthetic -> corpus_v1
	python -m scripts.ingest

corpus: ground-truth policies synthetic ingest   ## full rebuild of corpus v1

eval-set:         ## step 1.5: rebuild eval_v1 (DON'T run after the freeze; create eval_v2 instead)
	python -m scripts.build_eval_set

grade:            ## grade predictions: make grade PRED=runs/dev.jsonl SPLIT=dev
	python -m scripts.grade $(PRED) --split $(or $(SPLIT),dev)

retrieval-baseline: ## step 1.8: BM25 (+ dense with RETRIEVERS=bm25,dense) on eval_v1 gold docs + ACORD
	python -m scripts.retrieval_baseline --retrievers $(or $(RETRIEVERS),bm25)

prompt-baseline:  ## steps 1.6-1.7: 3 prompting strategies on the dev split via the course endpoint (uses token quota)
	python -m scripts.prompt_baseline --split dev

prompt-baseline-mock: ## offline pipeline check with a stand-in model (numbers meaningless; reports/mock/ only)
	LLM_BACKEND=mock python -m scripts.prompt_baseline --split dev

STRATEGIES ?= fixed512,fixed512_ctx,structure,small2big
index:            ## step 2.1: load corpus v1 into the store + embeddings (make index STRATEGIES=structure); idempotent, resumable
	python -m scripts.index_corpus --strategies $(STRATEGIES) --embed

chunking-experiments: ## step 2.2: compare chunking strategies (RETRIEVERS=bm25 offline; bm25,dense,hybrid with embeddings)
	python -m scripts.chunking_experiments --retrievers $(or $(RETRIEVERS),bm25,dense,hybrid) --strategies $(STRATEGIES)

retrieval-eval:   ## step 2.4: BM25 vs dense vs hybrid vs hybrid+reranker (+ vendor filter) -> docs/experiments/retrieval.md
	python -m scripts.retrieval_eval

schemas:
	python -m scripts.export_json_schemas

test:
	python -m pytest -q

migrate:          ## step 2.6: apply Alembic migrations (SQLite store file, or Postgres with STORE_BACKEND=postgres)
	python -m app.db.migrate

api:              ## step 2.6: run the API locally (http://localhost:8000/docs)
	uvicorn app.api.main:app --reload

ui:               ## step 3.7: Streamlit UI (live API with API_KEY, or the mock JSON)
	streamlit run app/ui/streamlit_app.py

test-safety:      ## step 2.7: safety suite (threats T1-T8 in docs/threat_model.md)
	python -m pytest -q tests/test_safety.py

rerank-experiment: ## decision 9: no reranker vs MiniLM@12/@20 vs bge-base@12 on dev -> docs/experiments/reranker.md
	python -m scripts.rerank_experiment

ui-mock:          ## regenerate app/ui/mock_review.json through the API (stand-in model; add ARGS=--live for real text)
	python -m scripts.make_ui_mock $(ARGS)

check-constrained: ## step 3.3 day 1: does the endpoint support json_schema / guided_json constrained decoding?
	python -m scripts.check_constrained

agent-smoke:      ## step 3.8: 10 spread dev queries through the agent -> reports/smoke/ (LLM_CACHE=1 makes reruns free)
	LLM_CACHE=1 python -m scripts.agent_eval --split dev --limit 10

agent-eval:       ## steps 3.8-3.9: full dev split through the agent -> reports/agent_eval_v1.json + docs/agent_eval.md
	LLM_CACHE=1 python -m scripts.agent_eval --split dev

agent-eval-test:  ## Week 3 GATE ONLY (D12): the test split, once
	python -m scripts.agent_eval --split test

agent-eval-mock:  ## offline pipeline check with the stand-in model (numbers meaningless; reports/mock/)
	LLM_BACKEND=mock python -m scripts.agent_eval --split dev

test-agent:       ## Week 3: agent graph, guards, critic, checkpoints (scripted fake LLM, offline)
	python -m pytest -q tests/test_agent.py

ablations:        ## Week 4 (4.4): dev run per configuration -> docs/ablations.md (LLM_CACHE=1; ~150k tokens per config at most)
	LLM_CACHE=1 python -m scripts.ablations

benchmark:        ## Week 4 (4.1): 3 dev runs for variance, then the usefulness judge -> docs/benchmark.md
	LLM_CACHE=1 python -m scripts.benchmark run --repeats 3 && python -m scripts.benchmark judge

safety-report:    ## Week 4 (4.3): corpus checks, 20 safety probes through the agent, safety test suites -> docs/safety_report.md
	python -m scripts.safety_report

smoke:            ## Week 4 (4.5): one-command check of the running stack (API, agent, refusal, tool failure, UI)
	python -m scripts.smoke_test

up:               ## Postgres+pgvector, Langfuse (:3000) and the API (:8000) in Docker; rebuilds the API image
	docker compose -f docker/docker-compose.yml --env-file .env up -d --build

down:
	docker compose -f docker/docker-compose.yml --env-file .env down

chat-eval-set:    ## D45: verify the frozen chat eval set (rebuild only before its freeze: python -m scripts.build_chat_eval --force)
	python -m scripts.build_chat_eval --check

chat-eval:        ## D45: Ask the Copilot on chat_eval_v1 dev (course endpoint) -> reports/chat_eval_v1.json + docs/chat_eval.md
	LLM_CACHE=1 python -m scripts.chat_eval --split dev

chat-eval-test:   ## D45: the held-out chat split, ONCE at the end
	python -m scripts.chat_eval --split test

chat-eval-mock:   ## D45: offline pipeline check with the stand-in model (numbers meaningless for LLM text; reports/mock/)
	LLM_BACKEND=mock python -m scripts.chat_eval --split dev

test-chat:        ## D45: chat assistant tests (grounding checks, routing, portfolio vs ground truth, API, UI; fake LLM, offline)
	python -m pytest -q tests/test_chatbot.py tests/test_chat_api.py tests/test_chat_ui.py

chat-kb:          ## D45: what the chat's documentation knowledge base holds (files, chunks, skipped files)
	python -m app.chatbot.knowledge

# ---- AWS EC2 / any cloud host (docs/deploy_aws_ec2.md): same stack as `make up`; Postgres, the API and Langfuse listen on
# the host's loopback only (SSH tunnel), the UI per UI_BIND in .env. Needs docker/docker-compose.ec2.yml and Compose >= 2.24.
EC2_COMPOSE = docker compose -f docker/docker-compose.yml -f docker/docker-compose.ec2.yml --env-file .env

up-ec2:           ## EC2: build and start the stack (rebuild after every git pull)
	$(EC2_COMPOSE) up -d --build

down-ec2:         ## EC2: stop the stack (data and traces stay in the Docker volumes)
	$(EC2_COMPOSE) down

ps-ec2:           ## EC2: container status (wait for api: healthy)
	$(EC2_COMPOSE) ps

embeddings-ec2:   ## EC2, first deploy only: copy the stored bge-small vectors from store.sqlite into Postgres (hybrid search)
	$(EC2_COMPOSE) exec api python -m scripts.copy_embeddings --sqlite /app/data/processed/store.sqlite

smoke-ec2:        ## EC2: the one-command smoke test inside the API container (tool-failure check skipped)
	$(EC2_COMPOSE) exec api python -m scripts.smoke_test --api http://localhost:8000 --ui http://ui:8501 --no-fault

chat-kb-ec2:      ## EC2: what the chat's documentation knowledge base holds inside the API container (should not be empty)
	$(EC2_COMPOSE) exec api python -m app.chatbot.knowledge

logs-ec2:         ## EC2: follow the API logs
	$(EC2_COMPOSE) logs -f --tail=100 api
