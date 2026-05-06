# Contributing

Thanks for considering a contribution. The platform tries to remain small
and opinionated — the bar for adding a new module or significantly changing
a default is "we considered the alternative and rejected it for these
reasons", which gets recorded in [`docs/architecture.md`](docs/architecture.md).

## Local development loop

You will need:

* `terraform` >= 1.6
* `tflint` >= 0.50 (with the AWS plugin: `tflint --init`)
* `checkov` >= 3
* `trivy` >= 0.50 (for IaC scanning)
* `kubeconform` >= 0.6 (for manifest validation)
* `shellcheck` (for any script edits)
* `pre-commit` (optional, but every CI check is also a pre-commit hook)

The full lint loop is wrapped in the `Makefile`:

```sh
make fmt          # terraform fmt -recursive
make validate     # terraform init -backend=false && terraform validate
make lint         # tflint, checkov, trivy, kubeconform, shellcheck
make test         # any unit tests we add (currently none)
make all          # everything above
```

`make all` is what CI runs. If it passes locally, your PR will pass CI.

## Branching and commits

* Branch off `main`. Branch names: `feat/<scope>`, `fix/<scope>`,
  `docs/<scope>`, etc. Keep them short.
* Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):

  ```
  <type>(<scope>): <subject>
  ```

  with the same `<type>` set the existing log uses: `feat`, `fix`, `docs`,
  `test`, `ci`, `refactor`, `chore`.

* One logical change per commit. The git log is meant to be readable by
  someone bisecting in five years.

* **Do not add `Co-Authored-By` lines** unless the co-author actually
  wrote part of the change. The repo is single-author by design.

## Pull request expectations

A PR is ready to merge when:

* CI is green.
* The change is described in the PR body — what + why, not just what.
* If you changed a default, you updated `docs/architecture.md` with the
  decision.
* If you added a module, you added a section to `docs/addon-reference.md`.
* If you bumped a chart version, you ran the upgrade procedure end-to-end
  on a real cluster and noted what you saw.
* If you touched anything security-relevant (IAM policies, security
  groups, network policies, public endpoints), you flagged it in the
  PR description so review can focus there.

Reviews are first-pass on `main`; we don't gate on multiple reviewers,
but we do gate on CI.

## Adding a new module

1. Copy an existing simple module (e.g. `metrics-server`) as the starting
   point. Modules average ~150 LOC; if yours grows past 300, consider
   whether it should be two modules.
2. Add `variables.tf` with validation blocks on every typed input.
3. Add `outputs.tf` for anything other modules will need.
4. Add `versions.tf` with the `required_providers` block — including
   `helm` and `kubernetes` if the module uses them.
5. Wire the module into `terraform/environments/dev/main.tf`.
6. Add a section to [`docs/addon-reference.md`](docs/addon-reference.md).
7. If the module is operationally interesting (Karpenter-tier), write a
   dedicated `docs/<module>-guide.md`.

## Filing issues

Please include:

* The cluster version (`kubectl version --short`).
* The Terraform version (`terraform version`).
* The output of `terraform plan` if relevant — minus secrets.
* What you expected vs. what happened.

The issue template will prompt you for these.

## Security

Anything that looks like a vulnerability — even a low-severity one —
goes via private channel rather than a public issue. See
`SECURITY.md` (when present) or open a private security advisory in
GitHub.

## Code of conduct

Be kind. Disagree on the merits, not the people. The platform is
collaborative; the trade-offs are public for a reason.
