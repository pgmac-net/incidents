#!/bin/bash
set -e

echo "🔨 Building MkDocs site..."
uv run mkdocs build

echo "📦 Deploying to macro.int.pgmac.net..."
scp -r site/* macro.int.pgmac.net:/var/www/html/incidents/

echo "✅ Deployment complete!"
echo "🌐 Site available at: https://macro.int.pgmac.net/incidents/"
