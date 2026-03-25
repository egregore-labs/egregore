# Egregore Testing Framework

Testing framework based on **unit economics**: ROI = (V × p × k) - C

Reliability dominates unit economics. If retrieval fails, p → 0 and ROI collapses.

## Quick Start

```bash
cd tests
uv sync
uv run pytest -v --html=reports/report.html
```

## Test Categories

| Category | File | Economics Impact | Description |
|----------|------|------------------|-------------|
| **Capture** | `test_capture.py` | p (items enter system) | Frontmatter validity, required fields, naming |
| **Sync** | `test_sync.py` | p (items findable) | File ↔ Neo4j consistency |
| **Retrieval** | `test_retrieval.py` | p × V (trust) | Query determinism, filter accuracy |
| **Quality** | `test_quality.py` | p × V (usefulness) | Missing fields, name consistency |
| **Security** | `test_security.py` | C (incident cost) | Secret detection in tracked files |

## Thresholds

| Metric | Threshold | Impact |
|--------|-----------|--------|
| Frontmatter Parse Rate | 100% | p = 0 for invalid files |
| Required Fields | 100% | V reduced for incomplete data |
| Sync Accuracy | > 99% | p reduced for unsynced items |
| Retrieval Stability | 100% | Trust collapse if inconsistent |
| Security | 0 secrets | C spike if exposed |

## Running Specific Categories

```bash
# Only capture tests
uv run pytest -v -m capture

# Only sync tests (requires Neo4j)
uv run pytest -v -m sync

# Only security tests
uv run pytest -v -m security
```

## Neo4j Tests

Sync, retrieval, and quality tests require Neo4j connection. Set environment:

```bash
export NEO4J_URI="neo4j+s://..."
export NEO4J_USER="neo4j"
export NEO4J_PASSWORD="..."
```

Or create `.env` in `telegram-bot/` directory (tests load from there).

## Reports

HTML reports are generated at `reports/report.html`. Open in browser:

```bash
open reports/report.html
```

## File Structure

```
tests/
├── conftest.py           # Fixtures: neo4j_driver, filesystem_*, metrics
├── pyproject.toml        # Dependencies and pytest config
│
├── test_capture.py       # Frontmatter, required fields, naming
├── test_sync.py          # File ↔ Neo4j sync accuracy
├── test_retrieval.py     # Query determinism, filters
├── test_quality.py       # Missing data, name consistency
├── test_security.py      # Secret pattern detection
│
├── utils/
│   ├── frontmatter.py    # YAML parsing utilities
│   └── neo4j_helpers.py  # Query helpers
│
├── reports/              # HTML reports (gitignored)
│
├── legacy_test_retrievals.py  # Old standalone test script
└── backfill_neo4j.py          # Sync script (run after failures)
```

## After Failures

1. **Capture failures**: Fix frontmatter in flagged files
2. **Sync failures**: Run `python backfill_neo4j.py` or `/save`
3. **Security failures**: Remove secrets from flagged files, rotate tokens
4. **Quality failures**: Fix data quality issues in Neo4j

## CI Integration

Add to GitHub Actions:

```yaml
- name: Run tests
  working-directory: tests
  run: |
    uv sync
    uv run pytest -v --html=reports/report.html
```
