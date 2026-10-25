# Dovel test runs

Runs the Dovel flow on test mirrors of open-source repositories, each on its own GitHub-hosted Ubuntu 24.04
runner, and scores the results with Dovel's own acceptance evaluator (`.github/workflows/run.yml`).

- `sets/*.json`: the repositories of a run (mirror, branch).
- `products/*.tar.gz.enc`: the product snapshot under test, encrypted; the key is a repository secret.
- Results and the evaluation are each run's artifacts.
