# Contributing to Zeroflow

Thanks for your interest. Read this before opening a pull request.

## License of contributions

Zeroflow is released under the [GNU Affero General Public License v3.0 only](LICENSE) (AGPL-3.0-only).

By submitting a pull request, patch, or any other contribution to this repository, you agree that:

1. Your contribution is licensed under AGPL-3.0-only, and
2. You grant the project copyright holder a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license to relicense your contribution under any other terms, including proprietary or commercial terms, and to distribute it through channels such as the Mac App Store.

This is what lets the project stay AGPL for everyone while the author remains able to ship official builds on other terms. It does not take away your rights to your own contribution — you can still use it however you like.

If you cannot agree to the above, do not submit a pull request. Open an issue with your suggestion instead.

## Code requirements

- **No third-party dependencies.** SwiftUI + AppKit + system frameworks only.
- **`xcodebuild` passing is the only verification standard.** There is no test suite and no linter.
- **Read `AGENTS.md` before touching architecture-sensitive code** — screenshot chain, window management family, notch panel, event taps. Its invariants are not negotiable.
- **Record new pitfalls in `PITFALLS_DEV.md`** with a `DEV-xxx` number.
- **Keep the diff focused.** Unrelated refactors inside a feature PR will be asked to split out.

## Commit / PR

- Describe the user-visible behavior change, not just the code change.
- If the change affects animation timing, memory footprint, or private API usage, state how you verified it.

---

## 中文摘要

本项目采用 AGPL-3.0-only。提交 PR 即表示：你的贡献以 AGPL-3.0-only 授权，同时授予版权人（项目作者）以其他条款（含闭源商业许可、Mac App Store 分发）再许可该贡献的权利。这是为了让开源版本对所有人保持 AGPL 的同时，作者仍能自行发布官方构建。你对自己贡献的权利不受影响。
