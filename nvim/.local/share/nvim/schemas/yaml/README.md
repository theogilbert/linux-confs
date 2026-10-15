# Validation files for the yaml-language-server LSP

Offline copies of the schemas yamlls uses, so that completion and validation work without internet access.
`lua/lsps.lua` maps them to files through yamlls' `yaml.schemas` setting.

- `mirror/<host>/<path>`: each schema, stored after its original URL, plus every remote `$ref` it pulls in.
- `schemas.json`: schema URL -> file globs, taken from the [SchemaStore](https://www.schemastore.org) catalog.
- The Kubernetes schema is mirrored too, but nvim serves it to yamlls under its original URL: yamlls only enables its
  Kubernetes mode for that URL. Which files it applies to is decided in `lua/lsps.lua`.
- Custom resources (e.g. `ExternalSecret`) get their schema from the [CRDs catalog](https://github.com/datreeio/CRDs-catalog),
  also served under its original URL. Only the API groups in `CRD_GROUPS` are mirrored: add one when yamlls reports
  "Schema not mirrored offline" for it.
- `update.py`: regenerates all of the above. Needs internet access. Edit `CATALOG_NAMES` and `CRD_GROUPS` to add or remove a schema.
