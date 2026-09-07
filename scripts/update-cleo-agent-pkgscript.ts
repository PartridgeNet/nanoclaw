import path from 'path';
import { initDb } from '../src/db/connection.js';
import { updateContainerConfigScalars, updateContainerConfigJson } from '../src/db/container-configs.js';
import { DATA_DIR } from '../src/config.js';

initDb(path.join(DATA_DIR, 'v2.db'));

const AGENT_GROUP_ID = 'ag-1783416603246-3ml950';

// imagemagick    — binaries + libraries (libmagickwand-dev alone is a dummy package on bookworm)
// libmagickwand-dev — dev headers for the rmagick/mini_magick native extension
// libsnappy-dev  — snappy gem
// cmake          — cmake-based native extensions
updateContainerConfigJson(AGENT_GROUP_ID, 'packages_apt', [
  'jq', 'python3', 'python3-pip', 'python-is-python3', 'rsync', 'file',
  'build-essential', 'pkg-config', 'libpq-dev', 'libssl-dev', 'libreadline-dev',
  'zlib1g-dev', 'libyaml-dev', 'libffi-dev', 'libgmp-dev', 'autoconf', 'bison',
  'imagemagick', 'libmagickwand-dev', 'libsnappy-dev', 'cmake',
]);

// Template literal: $(nproc) / $ARCH are NOT JS interpolations (JS uses ${}).
// \${NODEARCH} is explicitly escaped → becomes ${NODEARCH} in the shell script.
const script = `set -e

# Ruby 3.4.5p51 + Bundler 4.0.13
curl -fsSL https://cache.ruby-lang.org/pub/ruby/3.4/ruby-3.4.5.tar.gz -o /tmp/ruby-3.4.5.tar.gz
tar -xzf /tmp/ruby-3.4.5.tar.gz -C /tmp
cd /tmp/ruby-3.4.5
./configure --prefix=/usr/local --disable-install-doc
make -j$(nproc)
make install
cd /
rm -rf /tmp/ruby-3.4.5 /tmp/ruby-3.4.5.tar.gz
gem install bundler -v 4.0.13 --no-document

# Bundler 4.0 dropped --system config; write directly to the node user's bundle
# config so bundle install writes to the node-owned /usr/local/bundle path.
mkdir -p /usr/local/bundle
chown node:node /usr/local/bundle
mkdir -p /home/node/.bundle
printf 'BUNDLE_PATH: "/usr/local/bundle"\\n' > /home/node/.bundle/config
chown -R node:node /home/node/.bundle

# Node 24.6.0 (repo pins this version; base image ships 22)
ARCH=$(uname -m)
case "$ARCH" in x86_64) NODEARCH=x64 ;; aarch64) NODEARCH=arm64 ;; *) echo "Unknown arch: $ARCH" >&2; exit 1 ;; esac
curl -fsSL "https://nodejs.org/dist/v24.6.0/node-v24.6.0-linux-\${NODEARCH}.tar.gz" -o /tmp/node.tar.gz
tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 --no-same-owner
rm /tmp/node.tar.gz`;

updateContainerConfigScalars(AGENT_GROUP_ID, { packages_script: script });

console.log('Done.');
