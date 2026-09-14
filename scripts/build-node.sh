#!/usr/bin/env bash
# Builds jaas-ui's Next.js standalone artifact. Runs inside the caller
# repo's checkout (jaas-ui), on an ubuntu-latest (x86_64) runner — matching
# VM.Standard.E2.1.Micro's architecture, so no cross-arch native-module
# concerns (e.g. sharp) between build and deploy target.
set -euo pipefail

npm ci
npm run build

# next.config.ts sets output: "standalone", which traces only the files
# each page needs into .next/standalone — but per Next's own docs that
# folder excludes public/ and .next/static, so both must be copied in by
# hand (same as this repo's Dockerfile does for the Docker path).
rm -rf .artifact
cp -r .next/standalone .artifact
mkdir -p .artifact/.next
cp -r .next/static .artifact/.next/static
mkdir -p .artifact/public
if [ -d public ]; then
  cp -r public/. .artifact/public/
fi

tar -czf artifact.tar.gz -C .artifact .
