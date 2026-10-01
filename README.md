# ColimaUI

A native macOS app for [Colima](https://github.com/abiosoft/colima), laid out like Docker Desktop. Built with Swift and SwiftUI; it needs no Xcode, only the Command Line Tools.

## Features

- **Dashboard** (opens first): CPU and memory sparklines, VM disk, Docker disk breakdown with prune, top containers, stack cards, and a "needs attention" list.
- **Containers**, grouped by Compose stack (or by image, or flat). Stack rows show how many services are running and the combined CPU and memory. Start, stop, restart or delete a single container or a whole stack.
- **Detail pane** with live logs (filter, follow, timestamps), merged logs for a whole stack, `docker inspect`, and a shell button that opens Terminal.
- **Images, Volumes, Networks** with usage hints, prune, and pull.
- **Profiles** as cards: start, stop, edit CPU, memory, disk and Kubernetes, create or delete profiles, switch the Docker context, SSH in.
- **Menu bar item** to control the VM, stacks and individual containers without opening the window.

## Build and run

```bash
./scripts/bundle.sh        # builds build/ColimaUI.app (ad-hoc signed)
open build/ColimaUI.app
```

Requires macOS 14+, and `colima` and `docker` installed with Homebrew.

## Tests

```bash
./scripts/test.sh                      # unit tests, no Colima needed
COLIMAUI_E2E=1 ./scripts/test.sh      # also runs live tests against your running Colima
./scripts/e2e-app.sh                   # builds the .app, launches it, checks it against `docker ps`
```

The live tests only create and remove containers named `colimaui-e2e-*`. They never stop the VM.
`test.sh` passes the Command Line Tools' Swift Testing framework path to SwiftPM, which doesn't add it on its own.

## Layout

- `Sources/ColimaKit`: models, CLI parsing, `colima`/`docker` clients, grouping, and the observable `ColimaStore`. No UI, fully tested.
- `Sources/ColimaUI`: SwiftUI app (main window, menu bar, settings).
- `scripts/`: bundling, icon generation, tests.

## How it talks to Colima

It runs the `colima` and `docker` CLIs, pointing `DOCKER_HOST` at `~/.colima/<profile>/docker.sock`, so it never changes your active Docker context unless you press "Use context". The app isn't sandboxed because it has to run those tools.
