# Repository Guidelines

## Project Structure & Module Organization
Keep the repository predictable and sparse:
- `src/` holds runtime code; tuck shared orchestration into `src/core/`, agent behaviors into `src/agents/<agent_name>/`, and reusable integrations into `src/tools/`.
- `tests/` mirrors the `src/` tree (`tests/agents/test_router.py` covers `src/agents/router.py`) so coverage is easy to locate.
- `scripts/` stores bootstrap or maintenance helpers, while `docs/` captures architecture notes and runbooks. Co-locate configuration templates beside the code that consumes them.

## Build, Test, and Development Commands
Drive local workflows through a tiny `Makefile` (or `justfile`) and keep targets honest:
- `make setup` — refresh `.venv` and install dependencies (`uv pip sync` or `pip install -r requirements.txt`).
- `make lint` — run static checks (`ruff check src tests`) and fail on warnings.
- `make fmt` — apply auto-formatting (`ruff format` or `black`).
- `make test` — execute the pytest suite with coverage (`--cov=src --cov-report=term-missing`).
- `make dev` — launch the agent entry point (`python -m src.cli`); update as the interface evolves.

## Coding Style & Naming Conventions
Target Python 3.11+. Use four-space indentation, cap lines at 100 characters, and type-hint every public function. Prefer `snake_case` for modules and functions, `PascalCase` for classes, and `SCREAMING_SNAKE_CASE` for constants. Generate configuration keys in lowercase with dashes (e.g., `conversation-window`). Run `ruff` (lint + format) and `mypy` locally; centralize tool settings in `pyproject.toml`.

## Testing Guidelines
Author tests with `pytest`, mirroring the module hierarchy and prefixing files with `test_`. Favor deterministic fixtures, isolate network calls with fakes or VCR cassettes, and aim for ≥85% statement coverage. Tag slow suites with `@pytest.mark.integration` and gate them behind `make test-integration` so `make test` stays fast.

## Commit & Pull Request Guidelines
Follow Conventional Commits (`feat(core): add planner router`) so changelog tooling works out of the box. Keep commits focused with tests and docs updated alongside code. Pull requests need a concise summary, linked issue or RFC, validation steps (`make lint && make test` output), and screenshots or logs when behavior changes; request review only after CI is green.

## Security & Configuration Tips
Never commit secrets. Keep sensitive values (e.g., `OPENAI_API_KEY`) in `.env` and mirror requirements in `.env.example`. Audit each agent tool for outbound calls and guard them with explicit allow-lists; redact user data in shared logs and rotate credentials after any accidental exposure.
