# Contributing

- `sh test/test.sh` before a change is done: every module's configuration, then the whole stack
  with a test VPN. The CI runs the same, plus shellcheck and actionlint.
- A new module comes with its line in the README, its variables in `.env.example`, and a check in
  `test/test.sh` that the service starts and that the others accept it.
- Settings are chosen in advance only where a service reads them from a file or the environment
  on its first start; the rest is a step of "Connecting the services" in the README.
- Changes go through a pull request to `main`, squashed; the title, in English and in the
  imperative, starts with a [gitmoji](https://gitmoji.dev). Rules: `.github/rulesets/`.
