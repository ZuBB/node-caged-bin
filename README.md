# node-caged-bin

Node binary for local (mac arm64) usage based on work done in the next initiative
* https://blog.platformatic.dev/we-cut-nodejs-memory-in-half
* https://github.com/platformatic/node-caged

## build

Reproducible local macOS builder for `platformatic/node-caged`.

The build uses the `platformatic/node-caged` repository as the recipe source,
then builds upstream Node.js for `darwin-arm64` with V8 pointer compression:

```sh
./scripts/build-node-caged-macos.sh
```

Outputs are written under `build-node-caged/`:

- `artifacts/` - packaged `node-vX.Y.Z-darwin-arm64.tar.gz` and checksum
- `deps-snapshot/` - host tool and Homebrew state before/after the build
- `logs/` - build logs and manifest
- `node-src/` - cloned Node.js source
- `recipe/` - cloned `platformatic/node-caged` recipe repository

No Homebrew packages are installed by the script. If preflight fails, install
the missing tool explicitly, then rerun the script.

## Resutls

* fs tree snapshot - `fs-tree.txt`
* sha256 checks

```sh
bash-5.3$ ls -l build-node-caged/artifacts/
total 109984
-rw-r--r--@ 1 vasyl  staff  56307652 Jun  4 15:50 node-v26.3.0-darwin-arm64.tar.gz
-rw-r--r--@ 1 vasyl  staff        99 Jun  4 15:50 node-v26.3.0-darwin-arm64.tar.gz.sha256
drwxr-xr-x@ 3 vasyl  staff        96 Jun  4 15:51 validation
bash-5.3$ cd -
/Users/vasyl/work/own/slim-node/build-node-caged/artifacts
bash-5.3$ sha
sha1        sha1sum     sha224      sha224sum   sha256      sha256sum   sha384      sha384sum   sha512      sha512sum   shar        sharing     shasum      shasum5.34  shazam
bash-5.3$ sha256 node-v26.3.0-darwin-arm64.tar.gz
SHA256 (node-v26.3.0-darwin-arm64.tar.gz) = 6dd25f453cf55538ef5768e63d8fccdc17dcb842a893c425650226a1d2117281
bash-5.3$ cat node-v26.3.0-darwin-arm64.tar.gz.sha256
6dd25f453cf55538ef5768e63d8fccdc17dcb842a893c425650226a1d2117281  node-v26.3.0-darwin-arm64.tar.gz
bash-5.3$
```

## Usage

Install via ZuBB's [Homebrew tap](https://github.com/ZuBB/homebrew-tap):

```sh
brew tap ZuBB/tap
brew install node-caged
```

The formula installs the published `darwin-arm64` binary release:

```sh
node --version
npm --version
```
