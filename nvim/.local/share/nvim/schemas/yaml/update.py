#!/usr/bin/env python3
"""Mirror the yaml-language-server schemas listed below, for offline use.

Every schema is stored under mirror/<host>/<path>, after its original URL, along
with every remote `$ref` it pulls in.  Refs between mirrored files are relative,
so they resolve as is.

schemas.json maps each SchemaStore schema URL to the file globs the SchemaStore
catalog associates it with.  lua/lsps.lua turns those URLs into mirror paths.

KUBERNETES_SCHEMA_URL is mirrored too, but served differently, and applied to
files decided in lua/lsps.lua.

Usage: ./update.py   (needs internet access)
"""

import json
import os
import shutil
import sys
import urllib.parse
import urllib.request

CATALOG_URL = "https://www.schemastore.org/api/json/catalog.json"

# SchemaStore catalog entries, by exact name.
CATALOG_NAMES = [
    "gitlab-ci",
    "GitHub Workflow",
    "docker-compose.yml",
    "prometheus.json",
    "prometheus.rules.json",
    "prometheus-alertmanager.json",
    "Ansible Playbook",
    "Ansible Tasks File",
    ".pre-commit-config.yml",
    "prettierrc.json",
    ".eslintrc",
    "openapi.json",
]

# Catalog entries whose schema yamlls cannot use, by name: the schema to use
# instead, for the same files.
URL_OVERRIDES = {
    # SchemaStore's entry always loads the OpenAPI 3.1 and 3.2 schemas, whose
    # JSON Schema 2020-12 refs yamlls fails to resolve: no schema at all then.
    # 3.0 only, until yamlls supports 2020-12.
    "openapi.json": "https://spec.openapis.org/oas/3.0/schema/2024-10-18",
}

# The Kubernetes schema built into yaml-language-server.  Keep in sync with
# KUBERNETES_SCHEMA_URL in lua/lsps.lua, and with the server's own.
KUBERNETES_SCHEMA_URL = (
    "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.32.1-standalone-strict/all.json"
)

HERE = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.path.join(HERE, "mirror")


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "nvim-schema-mirror"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def mirror_path(url):
    parsed = urllib.parse.urlsplit(url)
    return os.path.join(MIRROR, parsed.netloc, parsed.path.lstrip("/"))


def remote_refs(node, base):
    """Yield the absolute http(s) documents `$ref`s in node point to."""
    if isinstance(node, dict):
        ref = node.get("$ref")
        if isinstance(ref, str):
            document = ref.split("#", 1)[0]
            if document:
                url = urllib.parse.urljoin(base, document)
                if url.startswith(("http://", "https://")):
                    yield url
        for value in node.values():
            yield from remote_refs(value, base)
    elif isinstance(node, list):
        for value in node:
            yield from remote_refs(value, base)


def draft04_bounds_to_draft07(node):
    """Rewrite draft-04 boolean exclusiveMinimum/exclusiveMaximum in place.

    yamlls checks every schema against draft-07, where those are numbers, and
    rejects the whole schema otherwise (e.g. OpenAPI 3.0's).

    Returns whether anything changed.
    """
    changed = False
    if isinstance(node, dict):
        for exclusive, bound in (("exclusiveMinimum", "minimum"), ("exclusiveMaximum", "maximum")):
            if isinstance(node.get(exclusive), bool):
                if node.pop(exclusive) and bound in node:
                    node[exclusive] = node.pop(bound)
                changed = True
        for value in node.values():
            changed |= draft04_bounds_to_draft07(value)
    elif isinstance(node, list):
        for value in node:
            changed |= draft04_bounds_to_draft07(value)
    return changed


def mirror(urls):
    seen = set()
    queue = list(urls)
    while queue:
        url = queue.pop()
        if url in seen:
            continue
        seen.add(url)

        try:
            data = fetch(url)
            schema = json.loads(data)
        except Exception as e:
            print(f"FAILED  {url}: {e}", file=sys.stderr)
            continue

        if draft04_bounds_to_draft07(schema):
            data = json.dumps(schema, indent=2).encode()
        path = mirror_path(url)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        print(f"{len(data) // 1024:6} KB  {url}")

        queue.extend(remote_refs(schema, url))
        # Relative refs may also be resolved against the schema's own $id.
        if isinstance(schema.get("$id"), str):
            queue.extend(remote_refs(schema, schema["$id"]))


def main():
    catalog = json.loads(fetch(CATALOG_URL))["schemas"]
    by_name = {entry["name"]: entry for entry in catalog}

    missing = [name for name in CATALOG_NAMES if name not in by_name]
    if missing:
        sys.exit(f"Not in the SchemaStore catalog anymore: {missing}")

    associations = {
        URL_OVERRIDES.get(name, by_name[name]["url"]): by_name[name]["fileMatch"] for name in CATALOG_NAMES
    }

    shutil.rmtree(MIRROR, ignore_errors=True)
    mirror(list(associations) + [KUBERNETES_SCHEMA_URL])

    with open(os.path.join(HERE, "schemas.json"), "w") as f:
        json.dump(associations, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
